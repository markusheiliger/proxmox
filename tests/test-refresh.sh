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

upload_source="${TEST_ROOT}/upload.env"
upload_log="${TEST_ROOT}/upload.log"
printf 'KEY=value\n' > "$upload_source"
SCRIPT_DIR="$SCRIPT_DIR" UPLOAD_LOG="$upload_log" UPLOAD_SOURCE="$upload_source" bash -c '
  source "$SCRIPT_DIR/commonCT.sh"
  get_ct_owner_node() { printf "pve02\n"; }
  hostname() { printf "pve01\n"; }
  node_upload_file() { printf "node_upload_file %s\n" "$*" >>"$UPLOAD_LOG"; }
  run_on_node() { printf "run_on_node %s\n" "$*" >>"$UPLOAD_LOG"; }
  ct_upload_file 2700 "$UPLOAD_SOURCE" /mnt/docker/.env 0600
'
assert_contains "CT upload stages remote source privately" "$upload_log" "node_upload_file pve02 $upload_source /tmp/ct-upload-2700-"
assert_contains "CT upload creates mapped root-owned file" "$upload_log" "pct push 2700 /tmp/ct-upload-2700-"
assert_contains "CT upload atomically replaces destination" "$upload_log" "pct exec 2700 -- mv -f -- /mnt/docker/.env.tmp."

restore_guard_line=$(grep -n 'if ct_has_tag "$CTID" backup-restore-test' "${SCRIPT_DIR}/refreshCT.sh" | cut -d: -f1)
storage_check_line=$(grep -n 'check_ct_storage_health "${CTID}" warn' "${SCRIPT_DIR}/refreshCT.sh" | cut -d: -f1)
if [[ -n "$restore_guard_line" && -n "$storage_check_line" && "$restore_guard_line" -lt "$storage_check_line" ]]; then
  pass "restore-test CTs are rejected before refresh mutations"
else
  fail "restore-test CTs are rejected before refresh mutations"
fi

sleep() { :; }

CTID=2200
CT_HOSTNAME="app.thesaints.home"
permission_commands="${TEST_ROOT}/permission-commands"
ct_exec() {
  local command="${*: -1}"
  case "$command" in
    *"docker compose config --format json --no-env-resolution"*)
      printf '%s\n' '{"services":{"webtop":{"env_file":[{"path":"./_secrets/webtop.env","format":"raw"},"/mnt/docker/_secrets/shared.env"]},"worker":{"env_file":["/mnt/docker/_secrets/shared.env"]}}}'
      ;;
    *"docker compose config --format json"*)
      printf '%s\n' '{"services":{"caddy":{"image":"caddy:test","volumes":[{"type":"bind","source":"/mnt/docker/caddy/data","target":"/data"}]},"webtop":{"image":"webtop:test","environment":{"PUID":"1000","PGID":"1001"},"volumes":[{"type":"bind","source":"/mnt/docker-data/webtop","target":"/config"}]}},"secrets":{"admin":{"file":"/mnt/docker/_secrets/admin"}}}'
      ;;
    *"docker image inspect"*) printf '\n' ;;
    *"candidate='/mnt/docker/caddy/data'"*|*"candidate='/mnt/docker-data/webtop'"*|*"test -e '/mnt/docker/caddy/data'"*|*"test -e '/mnt/docker-data/webtop'"*|*"test -f '/mnt/docker/_secrets/admin'"*|*"test -f '/mnt/docker/_secrets/webtop.env'"*|*"test -f '/mnt/docker/_secrets/shared.env'"*)
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
assert_contains "raw env file is CT-root-owned" "$permission_commands" "chown 0:0 '/mnt/docker/_secrets' '/mnt/docker/_secrets/webtop.env'"
assert_contains "raw env file is CT-root-only" "$permission_commands" "chmod 400 '/mnt/docker/_secrets/webtop.env'"
if [[ $(grep -Fc "chmod 400 '/mnt/docker/_secrets/shared.env'" "$permission_commands") -eq 1 ]]; then
  pass "shared raw env file is reconciled once"
else
  fail "shared raw env file is reconciled once"
fi
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

run_raw_env_rejection_case() {
  local case_name="$1" compose_fixture="$2" expected="$3"
  local output="${TEST_ROOT}/${case_name}-output"
  permission_fixture="$compose_fixture"
  ct_exec() {
    local command="${*: -1}"
    if [[ "$command" == *"docker compose config --format json"* ]]; then
      printf '%s\n' "$permission_fixture"
      return 0
    fi
    return 1
  }
  if reconcile_compose_permissions 2200 > "$output" 2>&1; then
    cat "$output" >&2
    fail "$case_name"
  elif grep -Fq "$expected" "$output"; then
    pass "$case_name"
  else
    cat "$output" >&2
    fail "$case_name"
  fi
}

run_raw_env_rejection_case \
  "raw env file outside managed secret path is rejected" \
  '{"services":{"app":{"env_file":["/tmp/secret.env"]}}}' \
  "Refusing Compose env_file outside /mnt/docker/_secrets"
run_raw_env_rejection_case \
  "conflicting raw and mounted secret delivery is rejected" \
  '{"services":{"app":{"env_file":["/mnt/docker/_secrets/shared.env"]}},"secrets":{"shared":{"file":"/mnt/docker/_secrets/shared.env"}}}' \
  "Secret file uses conflicting env_file and mounted-secret modes"
run_raw_env_rejection_case \
  "unsafe raw env file is rejected before mutation" \
  '{"services":{"app":{"env_file":["/mnt/docker/_secrets/unsafe.env"]}}}' \
  "Missing or unsafe Compose env_file"

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
managed_gpu_marker=false
node_path_is_file() {
  [[ "$managed_gpu_marker" == true \
    && "$1" == pve02 \
    && "$2" == /mnt/docker/mqtt.thesaints.home/_config/disable-managed-gpu ]]
}
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

: > "$gpu_commands"
CT_HOSTNAME=mqtt.thesaints.home
managed_gpu_marker=true
if reconcile_stopped_ct_gpu_config 2400 > /dev/null; then
  assert_contains "marker GPU reconciliation removes managed DRM" "$gpu_commands" "run_on_node pve02 sed -i"
  assert_not_contains "marker GPU reconciliation does not append DRM" "$gpu_commands" "run_node_shell"
else
  fail "marker GPU reconciliation removes managed DRM"
fi
gpu_probe_called=false
detect_node_gpu_capability() { gpu_probe_called=true; return 1; }
if resolve_ct_gpu_capability 2400 pve02 \
   && [[ "$NODE_GPU_STATE" == "absent" && "$gpu_probe_called" == false ]]; then
  pass "marker GPU capability skips node probing"
else
  fail "marker GPU capability skips node probing"
fi

: > "$gpu_commands"
CT_HOSTNAME=ca.thesaints.home
managed_gpu_marker=false
if reconcile_stopped_ct_gpu_config 2700 > /dev/null; then
  assert_contains "CA GPU reconciliation removes managed DRM" "$gpu_commands" "run_on_node pve02 sed -i"
  assert_not_contains "CA GPU reconciliation does not append DRM" "$gpu_commands" "run_node_shell"
else
  fail "CA GPU reconciliation removes managed DRM"
fi
gpu_finalize_output=$(finalize_ct_gpu_capability 2700 pve02)
if [[ "$gpu_finalize_output" == *"managed GPU passthrough is disabled"* ]]; then
  pass "CA GPU finalization is skipped"
else
  fail "CA GPU finalization is skipped"
fi
gpu_probe_called=false
detect_node_gpu_capability() { gpu_probe_called=true; return 1; }
if resolve_ct_gpu_capability 2700 pve02 \
   && [[ "$NODE_GPU_STATE" == "absent" && "$gpu_probe_called" == false ]]; then
  pass "CA GPU capability skips node probing"
else
  fail "CA GPU capability skips node probing"
fi
CT_HOSTNAME=""

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

run_optional_env_case() {
  local case_name="$1" compose_content="$2"
  local case_dir="${TEST_ROOT}/${case_name}"
  mkdir -p "${case_dir}/_config"
  printf '%s\n' "$compose_content" > "${case_dir}/docker-compose.yaml"
  cat > "${case_dir}/.env" <<'EOF'
CADDY_EMAIL=stale@example.test
NEWT_ID=existing-id
NEWT_SECRET=existing-secret
NEWT_ENDPOINT=https://existing.example.test
EOF
  update_env_file "${case_dir}/.env" "${case_dir}/_config"
  printf '%s\n' "${case_dir}/.env"
}

optional_env=$(run_optional_env_case optional 'environment: ["CADDY_EMAIL=${CADDY_EMAIL}", "NEWT_ID=${NEWT_ID}", "NEWT_SECRET=${NEWT_SECRET}", "NEWT_ENDPOINT=${NEWT_ENDPOINT}"]')
assert_contains "referenced Caddy email is retained" "$optional_env" "CADDY_EMAIL=admin@example.test"
assert_contains "referenced Newt ID is retained" "$optional_env" "NEWT_ID=existing-id"
assert_contains "referenced Newt secret is retained" "$optional_env" "NEWT_SECRET=existing-secret"
assert_contains "referenced Newt endpoint is retained" "$optional_env" "NEWT_ENDPOINT=https://existing.example.test"

config_get_newt_id() { echo configured-id; }
config_get_newt_secret() { echo configured-secret; }
config_get_newt_endpoint() { echo https://configured.example.test; }
configured_optional_env=$(run_optional_env_case configured-optional 'environment: ["NEWT_ID=${NEWT_ID}", "NEWT_SECRET=${NEWT_SECRET}", "NEWT_ENDPOINT=${NEWT_ENDPOINT}"]')
assert_contains "configured Newt ID replaces the existing value" "$configured_optional_env" "NEWT_ID=configured-id"
assert_contains "configured Newt secret replaces the existing value" "$configured_optional_env" "NEWT_SECRET=configured-secret"
assert_contains "configured Newt endpoint replaces the existing value" "$configured_optional_env" "NEWT_ENDPOINT=https://configured.example.test"

unused_optional_env=$(run_optional_env_case unused-optional 'services: {}')
assert_not_contains "unreferenced Caddy email is removed" "$unused_optional_env" "CADDY_EMAIL="
assert_not_contains "unreferenced Newt ID is removed" "$unused_optional_env" "NEWT_ID="
assert_not_contains "unreferenced Newt secret is removed" "$unused_optional_env" "NEWT_SECRET="
assert_not_contains "unreferenced Newt endpoint is removed" "$unused_optional_env" "NEWT_ENDPOINT="
assert_not_contains "unreferenced Newt comment is removed" "$unused_optional_env" "Newt/Pangolin tunnel configuration"

compose_up_source=$(declare -f compose_up)
if [[ "$compose_up_source" == *'update_env_file "$stage_env"'* ]] \
   && [[ "$compose_up_source" != *'set_or_add_env "NEWT_ID"'* ]]; then
  pass "Compose startup reuses centralized environment reconciliation"
else
  fail "Compose startup reuses centralized environment reconciliation"
fi

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