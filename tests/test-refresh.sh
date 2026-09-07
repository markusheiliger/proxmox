#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
PASS=0
FAIL=0

pass() { echo "ok - $1"; PASS=$((PASS + 1)); }
fail() { echo "not ok - $1" >&2; FAIL=$((FAIL + 1)); }

assert_contains() {
  local name="$1" file="$2" expected="$3"
  if grep -Fq "$expected" "$file"; then pass "$name"; else cat "$file" >&2; fail "$name"; fi
}

assert_not_contains() {
  local name="$1" file="$2" unexpected="$3"
  if grep -Fq "$unexpected" "$file"; then cat "$file" >&2; fail "$name"; else pass "$name"; fi
}

source "${SCRIPT_DIR}/refreshCT.sh"
trap 'rm -rf "$TEST_ROOT"' EXIT

sleep() { :; }

CTID=2200
CT_HOSTNAME="app.thesaints.home"
permission_commands="${TEST_ROOT}/permission-commands"
ct_exec() {
  local command="${*: -1}"
  case "$command" in
    *"docker compose config --format json"*)
      printf '%s\n' '{"services":{"caddy":{"image":"caddy:test","volumes":[{"type":"bind","source":"/mnt/docker/caddy/data","target":"/data"}]},"webtop":{"image":"webtop:test","environment":{"PUID":"1000","PGID":"1001"},"volumes":[{"type":"bind","source":"/mnt/docker-data/webtop","target":"/config"}]}},"secrets":{"admin":{"file":"/mnt/docker/_secrets/admin"}}}'
      ;;
    *"docker image inspect"*) printf '\n' ;;
    *"candidate='/mnt/docker/caddy/data'"*|*"candidate='/mnt/docker-data/webtop'"*|*"test -e '/mnt/docker/caddy/data'"*|*"test -e '/mnt/docker-data/webtop'"*|*"test -f '/mnt/docker/_secrets/admin'"*)
      printf '%s\n' "$command" >> "$permission_commands"
      ;;
    *"chown"*) printf '%s\n' "$command" >> "$permission_commands" ;;
    *) return 1 ;;
  esac
}
pvesm() { fail "permission reconciliation does not call pvesm"; return 1; }
if reconcile_compose_permissions 2200 > "${TEST_ROOT}/permission-output"; then
  pass "Compose permission preflight completes"
else
  cat "${TEST_ROOT}/permission-output" >&2
  fail "Compose permission preflight completes"
fi
assert_contains "root service uses CT-visible root" "$permission_commands" "chown -R 0:0 '/mnt/docker/caddy/data'"
assert_contains "PUID and PGID determine bind owner" "$permission_commands" "chown -R 1000:1001 '/mnt/docker-data/webtop'"
assert_contains "secret parent remains private" "$permission_commands" "chmod 700 '/mnt/docker/_secrets'"
assert_contains "secret is readable after Compose mount" "$permission_commands" "chmod 444 '/mnt/docker/_secrets/admin'"
if [[ "$(grep -n "test -e" "$permission_commands" | tail -1 | cut -d: -f1)" -lt \
  "$(grep -n "chown" "$permission_commands" | head -1 | cut -d: -f1)" ]]; then
  pass "all writable binds validate before mutation"
else
  fail "all writable binds validate before mutation"
fi
if ! grep -Eq '/mnt/docker/(app\.thesaints\.home|[^[:space:]]*/caddy/data)' "$permission_commands"; then
  pass "permission commands contain no hostname-derived host path"
else
  fail "permission commands contain no hostname-derived host path"
fi

run_initializer_case() {
  local expected_exit_code="$1" output="$2"
  local state_file="${TEST_ROOT}/state"
  echo 0 > "$state_file"

  ct_exec() {
    local command="${*: -1}"
    case "$command" in
      *"docker compose config --format json"*)
        printf '%s\n' '{"services":{"setup":{"restart":"no"}}}'
        ;;
      *"docker compose ps -a -q"*)
        echo abc123
        ;;
      *"{{.Name}}"*)
        echo /setup
        ;;
      *"{{.State.Status}}"*)
        local count
        count=$(cat "$state_file")
        if [[ "$count" -eq 0 ]]; then
          echo running
          echo 1 > "$state_file"
        else
          echo exited
        fi
        ;;
      *"{{.State.ExitCode}}"*)
        echo "$expected_exit_code"
        ;;
      *"docker logs --tail 20"*)
        echo "[setup] applying configuration"
        ;;
      *)
        return 1
        ;;
    esac
  }

  wait_for_initialization_services > "$output" 2>&1
}

success_output="${TEST_ROOT}/success-output"
if ! run_initializer_case 0 "$success_output"; then
  cat "$success_output" >&2
  fail "initializer success case completes"
else
  pass "initializer success case completes"
fi
assert_contains "initializer reports progress" "$success_output" "setup still running (30s): [setup] applying configuration"
assert_contains "initializer reports completion" "$success_output" "Initialization service setup completed"

failure_output="${TEST_ROOT}/failure-output"
if run_initializer_case 7 "$failure_output"; then
  fail "initializer propagates non-zero exit"
else
  pass "initializer propagates non-zero exit"
fi
assert_contains "initializer reports exit code" "$failure_output" "exited with code 7"
assert_contains "initializer prints recent logs" "$failure_output" "Recent logs:"
assert_contains "initializer includes failure log tail" "$failure_output" "[setup] applying configuration"

inspection_output="${TEST_ROOT}/inspection-output"
ct_exec() {
  local command="${*: -1}"
  case "$command" in
    *"docker compose config --format json"*)
      printf '%s\n' '{"services":{"setup":{"restart":"no"}}}'
      ;;
    *"docker compose ps -a -q"*)
      echo abc123
      ;;
    *"{{.Name}}"*)
      echo /setup
      ;;
    *"{{.State.Status}}"*)
      return 1
      ;;
    *)
      return 1
      ;;
  esac
}
if wait_for_initialization_services > "$inspection_output" 2>&1; then
  fail "initializer propagates inspection failure"
else
  pass "initializer propagates inspection failure"
fi
assert_contains "initializer explains inspection failure" "$inspection_output" "Could not inspect initialization service 'setup'"

multiple_output="${TEST_ROOT}/multiple-output"
ct_exec() {
  local command="${*: -1}"
  case "$command" in
    *"docker compose config --format json"*)
      printf '%s\n' '{"services":{"setup-a":{"restart":"no"},"setup-b":{"restart":"no"}}}'
      ;;
    *"ps -a -q setup-a"*|*"ps -a -q 'setup-a'"*)
      echo aaa111
      ;;
    *"ps -a -q setup-b"*|*"ps -a -q 'setup-b'"*)
      echo bbb222
      ;;
    *"aaa111"*"{{.Name}}"*)
      echo /setup-a
      ;;
    *"bbb222"*"{{.Name}}"*)
      echo /setup-b
      ;;
    *"{{.State.Status}}"*)
      echo exited
      ;;
    *"{{.State.ExitCode}}"*)
      echo 0
      ;;
    *)
      return 1
      ;;
  esac
}
if ! wait_for_initialization_services > "$multiple_output" 2>&1; then
  cat "$multiple_output" >&2
  fail "multiple initializers complete"
else
  pass "multiple initializers complete"
fi
assert_contains "first initializer completes" "$multiple_output" "Initialization service setup-a completed"
assert_contains "second initializer completes" "$multiple_output" "Initialization service setup-b completed"

gpu_commands="${TEST_ROOT}/gpu-commands"
get_ct_owner_node() { echo pve02; }
get_ct_status() { echo stopped; }
run_on_node() { printf 'run_on_node' >> "$gpu_commands"; printf ' %q' "$@" >> "$gpu_commands"; printf '\n' >> "$gpu_commands"; }
run_node_shell() { printf 'run_node_shell' >> "$gpu_commands"; printf ' %q' "$@" >> "$gpu_commands"; printf '\n' >> "$gpu_commands"; }
NODE_GPU_STATE=available
NODE_GPU_RENDER_DEVICES=(/dev/dri/renderD128)
if reconcile_stopped_ct_gpu_config 3500 > /dev/null; then
  assert_contains "GPU config removal runs on owner node" "$gpu_commands" "run_on_node pve02 sed -i"
  assert_contains "GPU config append runs on owner node" "$gpu_commands" "run_node_shell pve02"
  assert_contains "GPU config targets owner-local LXC path" "$gpu_commands" "/etc/pve/lxc/3500.conf"
else
  fail "GPU config mutation is owner-routed"
fi

remote_env="${TEST_ROOT}/remote.env"
: > "$remote_env"
CT_HOSTNAME=ai.thesaints.home
config_get_ssl_type() { echo none; }
config_get_dns_provider() { :; }
config_get_dns_api_token() { :; }
config_get_dns_account_id() { :; }
config_get_email() { echo admin@example.test; }
config_get_authentik_host() { echo auth.example.test; }
config_get_authentik_token() { echo test-api-token; }
config_get_authentik_authorization_flow() { echo authorization-flow; }
config_get_authentik_invalidation_flow() { echo invalidation-flow; }
config_get_telemetry_hostname() { :; }
config_get_telemetry_otlp_http_port() { :; }
config_get_telemetry_otlp_grpc_port() { :; }
node_path_is_file() { [[ "$2" == /mnt/docker/ai.thesaints.home/_config/configure.sh ]]; }
run_on_node() { [[ "$1" == pve02 && "$2" == grep && "$*" == *lib-authentik* ]]; }
update_env_file "$remote_env" /mnt/docker/ai.thesaints.home/_config pve02
assert_contains "remote configure script retains Authentik API token" "$remote_env" "AUTH_API_TOKEN=test-api-token"
assert_contains "remote configure script retains authorization flow" "$remote_env" "AUTH_AUTHORIZATION_FLOW=authorization-flow"
assert_contains "remote configure script retains invalidation flow" "$remote_env" "AUTH_INVALIDATION_FLOW=invalidation-flow"

config_get_telemetry_hostname() { echo telemetry.example.test; }
config_get_telemetry_otlp_http_port() { echo 4318; }
config_get_telemetry_otlp_grpc_port() { echo 4317; }

run_otlp_env_case() {
  local case_name="$1" compose_content="$2"
  local case_dir="${TEST_ROOT}/${case_name}"
  mkdir -p "${case_dir}/_config"
  printf '%s\n' "$compose_content" > "${case_dir}/docker-compose.yaml"
  cat > "${case_dir}/.env" <<'EOF'
OTEL_EXPORTER_OTLP_ENDPOINT=stale-http
OTEL_EXPORTER_OTLP_PROTOCOL=stale-protocol
OTEL_EXPORTER_OTLP_GRPC_ENDPOINT=stale-grpc
OTEL_EXPORTER_OTLP_INSECURE=stale-insecure
EOF
  update_env_file "${case_dir}/.env" "${case_dir}/_config"
  printf '%s\n' "${case_dir}/.env"
}

http_env=$(run_otlp_env_case http 'environment: ["OTEL_EXPORTER_OTLP_ENDPOINT=${OTEL_EXPORTER_OTLP_ENDPOINT}", "OTEL_EXPORTER_OTLP_PROTOCOL=${OTEL_EXPORTER_OTLP_PROTOCOL}"]')
assert_contains "HTTP OTLP endpoint is retained when referenced" "$http_env" "OTEL_EXPORTER_OTLP_ENDPOINT=http://telemetry.example.test:4318"
assert_contains "HTTP OTLP protocol is retained when referenced" "$http_env" "OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf"
assert_not_contains "unused gRPC OTLP endpoint is removed" "$http_env" "OTEL_EXPORTER_OTLP_GRPC_ENDPOINT="
assert_not_contains "unused gRPC insecure flag is removed" "$http_env" "OTEL_EXPORTER_OTLP_INSECURE="

grpc_env=$(run_otlp_env_case grpc 'environment: ["OTEL_EXPORTER_OTLP_ENDPOINT=${OTEL_EXPORTER_OTLP_GRPC_ENDPOINT}", "OTEL_EXPORTER_OTLP_INSECURE=${OTEL_EXPORTER_OTLP_INSECURE}"]')
assert_contains "gRPC OTLP endpoint is retained when referenced" "$grpc_env" "OTEL_EXPORTER_OTLP_GRPC_ENDPOINT=http://telemetry.example.test:4317"
assert_contains "gRPC OTLP insecure flag is retained when referenced" "$grpc_env" "OTEL_EXPORTER_OTLP_INSECURE=true"
assert_not_contains "unused HTTP OTLP endpoint is removed" "$grpc_env" "OTEL_EXPORTER_OTLP_ENDPOINT="
assert_not_contains "unused HTTP OTLP protocol is removed" "$grpc_env" "OTEL_EXPORTER_OTLP_PROTOCOL="

none_env=$(run_otlp_env_case none 'services: {}')
assert_not_contains "unreferenced HTTP OTLP endpoint is removed" "$none_env" "OTEL_EXPORTER_OTLP_ENDPOINT="
assert_not_contains "unreferenced HTTP OTLP protocol is removed" "$none_env" "OTEL_EXPORTER_OTLP_PROTOCOL="
assert_not_contains "unreferenced gRPC OTLP endpoint is removed" "$none_env" "OTEL_EXPORTER_OTLP_GRPC_ENDPOINT="
assert_not_contains "unreferenced gRPC insecure flag is removed" "$none_env" "OTEL_EXPORTER_OTLP_INSECURE="

echo "${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]