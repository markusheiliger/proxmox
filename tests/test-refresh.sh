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
  if grep -Fq -- "$expected" "$file"; then pass "$name"; else cat "$file" >&2; fail "$name"; fi
}

assert_not_contains() {
  local name="$1" file="$2" unexpected="$3"
  if grep -Fq "$unexpected" "$file"; then cat "$file" >&2; fail "$name"; else pass "$name"; fi
}

source "${SCRIPT_DIR}/refreshCT.sh"
trap 'rm -rf "$TEST_ROOT"' EXIT

if parse_refresh_args --all \
  && [[ "$REFRESH_ALL" == true && -z "$REFRESH_CT_ARG" && "$REFRESH_HAS_OPTIONS" == false ]]; then
  pass "--all selects non-interactive fleet refresh"
else
  fail "--all selects non-interactive fleet refresh"
fi
if parse_refresh_args --all app.thesaints.home >"${TEST_ROOT}/args.out" 2>&1; then
  fail "--all rejects an explicit CT target"
elif grep -Fq -- '--all cannot be combined' "${TEST_ROOT}/args.out"; then
  pass "--all rejects an explicit CT target"
else
  cat "${TEST_ROOT}/args.out" >&2
  fail "--all rejects an explicit CT target"
fi
if parse_refresh_args --all --reset >"${TEST_ROOT}/args.out" 2>&1; then
  fail "--all rejects destructive single-CT options"
elif grep -Fq -- '--all cannot be combined' "${TEST_ROOT}/args.out"; then
  pass "--all rejects destructive single-CT options"
else
  cat "${TEST_ROOT}/args.out" >&2
  fail "--all rejects destructive single-CT options"
fi
if parse_refresh_args --memory >"${TEST_ROOT}/args.out" 2>&1; then
  fail "missing option value is rejected"
elif grep -Fq 'requires a value' "${TEST_ROOT}/args.out"; then
  pass "missing option value is rejected"
else
  cat "${TEST_ROOT}/args.out" >&2
  fail "missing option value is rejected"
fi
MONITOR_AFTER=false
RESET=false

if declare -f run_on_node | grep -Fq 'ssh -n -o BatchMode=yes'; then
  pass "remote owner-node execution cannot consume caller stdin"
else
  fail "remote owner-node execution cannot consume caller stdin"
fi

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

pct_config() { printf '%s\n' 'unprivileged: 1'; }
if [[ "$(get_ct_host_root_ids 2200)" == "100000 100000" ]]; then
  pass "default unprivileged root IDs map to 100000"
else
  fail "default unprivileged root IDs map to 100000"
fi
pct_config() { printf '%s\n' $'unprivileged: 1\nlxc.idmap: u 0 200000 65536\nlxc.idmap: g 0 300000 65536'; }
if [[ "$(get_ct_host_root_ids 2200)" == "200000 300000" ]]; then
  pass "custom unprivileged root IDs are parsed from lxc.idmap"
else
  fail "custom unprivileged root IDs are parsed from lxc.idmap"
fi
pct_config() { printf '%s\n' 'unprivileged: 0'; }
if [[ "$(get_ct_host_root_ids 2200)" == "0 0" ]]; then
  pass "privileged CT root IDs remain host root"
else
  fail "privileged CT root IDs remain host root"
fi
unset -f pct_config

setup_log="${TEST_ROOT}/setup-mountpoints.log"
SCRIPT_DIR="$SCRIPT_DIR" SETUP_LOG="$setup_log" bash -c '
  source "$SCRIPT_DIR/commonCT.sh"
  CTID=2200
  CT_HOSTNAME=app.thesaints.home
  get_ct_owner_node() { printf "pve02\n"; }
  node_mkdir() { :; }
  node_path_is_file() { [[ "$2" == */docker-compose.yaml ]]; }
  update_env_file() { printf "KEY=value\n" > "$1"; }
  get_ct_host_root_ids() { printf "100000 100000\n"; }
  node_upload_file() { printf "node_upload_file %s\n" "$*" >> "$SETUP_LOG"; }
  reconcile_ct_mountpoints() { printf "reconcile %s\n" "$*" >> "$SETUP_LOG"; }
  reconcile_ddns_updater_secret_env() { printf "ddns %s\n" "$*" >> "$SETUP_LOG"; }
  setup_mountpoints >/dev/null
'
assert_contains "mount setup reconciles mounts" "$setup_log" \
  "reconcile 2200 app.thesaints.home"
assert_contains "mount setup publishes env with mapped CT ownership" "$setup_log" \
  "node_upload_file pve02"
assert_contains "mount setup targets the host Docker tree with mapped IDs" "$setup_log" \
  "/mnt/docker/app.thesaints.home/.env 0600 100000 100000"
if [[ "$(grep -nE '^(reconcile|ddns|node_upload_file)' "$setup_log" | cut -d: -f2- | paste -sd, -)" \
  == reconcile\ 2200\ app.thesaints.home,ddns\ 2200\ app.thesaints.home\ /mnt/docker/app.thesaints.home,node_upload_file\ pve02* ]]; then
  pass "mount setup publishes DDNS secrets before the Compose environment"
else
  cat "$setup_log" >&2
  fail "mount setup publishes DDNS secrets before the Compose environment"
fi

ddns_config="${TEST_ROOT}/ddns-config.json"
cat > "$ddns_config" <<'EOF'
{"ddns_updaters":{"worker.thesaints.home":{"zone":"thesaints.de"}}}
EOF
ddns_zone=$(SCRIPT_DIR="$SCRIPT_DIR" CONFIG_FILE="$ddns_config" bash -c '
  source "$SCRIPT_DIR/commonCT.sh"
  config_get_ddns_updater_zone worker.thesaints.home
')
if [[ "$ddns_zone" == thesaints.de ]]; then
  pass "DDNS updater opt-in resolves by hostname"
else
  fail "DDNS updater opt-in resolves by hostname"
fi

ddns_noop_log="${TEST_ROOT}/ddns-noop.log"
SCRIPT_DIR="$SCRIPT_DIR" DDNS_LOG="$ddns_noop_log" bash -c '
  source "$SCRIPT_DIR/commonCT.sh"
  config_get_ddns_updater_zone() { :; }
  get_ct_owner_node() { printf "unexpected owner lookup\n" >> "$DDNS_LOG"; return 1; }
  reconcile_ddns_updater_secret_env 2200 app.thesaints.home /mnt/docker/app.thesaints.home
'
if [[ ! -s "$ddns_noop_log" ]]; then
  pass "DDNS secret reconciliation is a no-op without opt-in"
else
  cat "$ddns_noop_log" >&2
  fail "DDNS secret reconciliation is a no-op without opt-in"
fi

ddns_publish_log="${TEST_ROOT}/ddns-publish.log"
ddns_published="${TEST_ROOT}/ddns-published.env"
SCRIPT_DIR="$SCRIPT_DIR" DDNS_LOG="$ddns_publish_log" DDNS_PUBLISHED="$ddns_published" bash -c '
  source "$SCRIPT_DIR/commonCT.sh"
  config_get_ddns_updater_zone() { printf "thesaints.de\n"; }
  config_get_dns_provider() { printf "dnsimple\n"; }
  config_get_udmpro_apikey() { printf "test-udm-key\n"; }
  config_get_dns_api_token() { printf "test-dns-token\n"; }
  config_get_dns_account_id() { printf "12345\n"; }
  get_ct_owner_node() { printf "pve02\n"; }
  get_ct_host_root_ids() { printf "200000 300000\n"; }
  node_path_is_file() { return 1; }
  node_mkdir() { printf "node_mkdir %s\n" "$*" >> "$DDNS_LOG"; }
  run_on_node() { printf "run_on_node %s\n" "$*" >> "$DDNS_LOG"; }
  node_upload_file() {
    cp "$2" "$DDNS_PUBLISHED"
    printf "node_upload_file %s %s %s %s %s\n" "$1" "$3" "$4" "$5" "$6" >> "$DDNS_LOG"
  }
  reconcile_ddns_updater_secret_env 3100 worker.thesaints.home /mnt/docker/worker.thesaints.home
'
assert_contains "DDNS secret is routed to the remote CT owner" "$ddns_publish_log" \
  "node_upload_file pve02 /mnt/docker/worker.thesaints.home/_secrets/ddns-updater.env 0400 200000 300000"
assert_contains "DDNS secret directory uses mapped root ownership" "$ddns_publish_log" \
  "run_on_node pve02 chown 200000:300000 /mnt/docker/worker.thesaints.home/_secrets"
assert_contains "DDNS secret contains the UDM API key" "$ddns_published" "UDM_API_KEY=test-udm-key"
assert_contains "DDNS secret contains the DNSimple token" "$ddns_published" "DNSIMPLE_API_ACCESS_TOKEN=test-dns-token"
assert_contains "DDNS secret contains the optional account ID" "$ddns_published" "DNSIMPLE_ACCOUNT_ID=12345"
assert_not_contains "DDNS lifecycle logs do not expose the UDM API key" "$ddns_publish_log" "test-udm-key"
assert_not_contains "DDNS lifecycle logs do not expose the DNSimple token" "$ddns_publish_log" "test-dns-token"

ddns_without_account="${TEST_ROOT}/ddns-without-account.env"
SCRIPT_DIR="$SCRIPT_DIR" DDNS_PUBLISHED="$ddns_without_account" bash -c '
  source "$SCRIPT_DIR/commonCT.sh"
  config_get_ddns_updater_zone() { printf "thesaints.de\n"; }
  config_get_dns_provider() { printf "dnsimple\n"; }
  config_get_udmpro_apikey() { printf "test-udm-key\n"; }
  config_get_dns_api_token() { printf "test-dns-token\n"; }
  config_get_dns_account_id() { :; }
  get_ct_owner_node() { printf "pve02\n"; }
  get_ct_host_root_ids() { printf "100000 100000\n"; }
  node_path_is_file() { return 1; }
  node_mkdir() { :; }
  run_on_node() { :; }
  node_upload_file() { cp "$2" "$DDNS_PUBLISHED"; }
  reconcile_ddns_updater_secret_env 3100 worker.thesaints.home /mnt/docker/worker.thesaints.home
'
assert_not_contains "DDNS account ID remains optional" "$ddns_without_account" "DNSIMPLE_ACCOUNT_ID="

ddns_unchanged="${TEST_ROOT}/ddns-unchanged.env"
ddns_unchanged_log="${TEST_ROOT}/ddns-unchanged.log"
cat > "$ddns_unchanged" <<'EOF'
UDM_API_KEY=test-udm-key
DNSIMPLE_API_ACCESS_TOKEN=test-dns-token
EOF
SCRIPT_DIR="$SCRIPT_DIR" DDNS_CURRENT="$ddns_unchanged" DDNS_LOG="$ddns_unchanged_log" bash -c '
  source "$SCRIPT_DIR/commonCT.sh"
  config_get_ddns_updater_zone() { printf "thesaints.de\n"; }
  config_get_dns_provider() { printf "dnsimple\n"; }
  config_get_udmpro_apikey() { printf "test-udm-key\n"; }
  config_get_dns_api_token() { printf "test-dns-token\n"; }
  config_get_dns_account_id() { :; }
  get_ct_owner_node() { printf "pve02\n"; }
  get_ct_host_root_ids() { printf "100000 100000\n"; }
  node_path_is_file() { return 0; }
  node_download_file() { cp "$DDNS_CURRENT" "$3"; }
  node_mkdir() { :; }
  run_on_node() { printf "%s\n" "$*" >> "$DDNS_LOG"; }
  node_upload_file() { printf "unexpected upload\n" >> "$DDNS_LOG"; return 1; }
  reconcile_ddns_updater_secret_env 3100 worker.thesaints.home /mnt/docker/worker.thesaints.home
'
assert_not_contains "unchanged DDNS content is not uploaded" "$ddns_unchanged_log" "unexpected upload"
assert_contains "unchanged DDNS secret permissions are reconciled" "$ddns_unchanged_log" \
  "pve02 chmod 0400 /mnt/docker/worker.thesaints.home/_secrets/ddns-updater.env"

ddns_invalid_log="${TEST_ROOT}/ddns-invalid.log"
if SCRIPT_DIR="$SCRIPT_DIR" DDNS_LOG="$ddns_invalid_log" bash -c '
  source "$SCRIPT_DIR/commonCT.sh"
  config_get_ddns_updater_zone() { printf "thesaints.de\n"; }
  config_get_dns_provider() { printf "dnsimple\n"; }
  config_get_udmpro_apikey() { printf "test-udm-key\n"; }
  config_get_dns_api_token() { :; }
  config_get_dns_account_id() { :; }
  node_upload_file() { printf "unexpected upload\n" >> "$DDNS_LOG"; }
  reconcile_ddns_updater_secret_env 3100 worker.thesaints.home /mnt/docker/worker.thesaints.home
' > "${TEST_ROOT}/ddns-invalid.out" 2>&1; then
  fail "invalid DDNS credentials fail closed"
elif [[ ! -s "$ddns_invalid_log" ]] \
  && grep -Fq "Incomplete or invalid DDNS updater credentials" "${TEST_ROOT}/ddns-invalid.out"; then
  pass "invalid DDNS credentials fail closed without replacing the secret"
else
  cat "${TEST_ROOT}/ddns-invalid.out" "$ddns_invalid_log" >&2
  fail "invalid DDNS credentials fail closed without replacing the secret"
fi

setup_line=$(grep -n 'if ! setup_mountpoints' "${SCRIPT_DIR}/refreshCT.sh" | cut -d: -f1)
reset_docker_line=$(grep -n 'if ! reset_docker' "${SCRIPT_DIR}/refreshCT.sh" | cut -d: -f1)
if [[ -n "$setup_line" && -n "$reset_docker_line" && "$setup_line" -lt "$reset_docker_line" ]]; then
  pass "DDNS secret generation occurs before the first Compose render"
else
  fail "DDNS secret generation occurs before the first Compose render"
fi

compose_image_log="${TEST_ROOT}/compose-images.log"
SCRIPT_DIR="$SCRIPT_DIR" COMPOSE_IMAGE_LOG="$compose_image_log" bash -c '
  source "$SCRIPT_DIR/commonCT.sh"
  CTID=2700
  ct_compose() {
    printf "%s\n" "$*" >> "$COMPOSE_IMAGE_LOG"
    [[ "$*" == *"config --profiles"* ]] && printf "gpu-drm_intel\n"
    return 0
  }
  compose_pull 2700 >/dev/null
  compose_build 2700 >/dev/null
'
assert_contains "Compose pull ignores locally buildable images" "$compose_image_log" \
  "--all-profiles 2700 --profile gpu-drm_intel pull --ignore-buildable"
assert_contains "Compose build routes through the selected CT" "$compose_image_log" \
  "--timeout 1800 2700 build"

pull_line=$(grep -n 'if ! compose_pull "${CTID}"' "${SCRIPT_DIR}/refreshCT.sh" | cut -d: -f1)
build_line=$(grep -n 'if ! compose_build "${CTID}"' "${SCRIPT_DIR}/refreshCT.sh" | cut -d: -f1)
reset_line=$(awk -v build_line="$build_line" \
  'NR > build_line && /if \[\[ "\$\{RESET:-false\}" == "true" \]\]/ { print NR; exit }' \
  "${SCRIPT_DIR}/refreshCT.sh")
permission_line=$(grep -n 'if ! reconcile_compose_permissions "${CTID}"' "${SCRIPT_DIR}/refreshCT.sh" | cut -d: -f1)
if [[ "$pull_line" -lt "$build_line" && "$build_line" -lt "$reset_line" && "$reset_line" -lt "$permission_line" ]]; then
  pass "local images build before reset and permission reconciliation"
else
  fail "local images build before reset and permission reconciliation"
fi

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
run_on_node() { printf 'run_on_node' >> "$gpu_commands"; printf ' %q' "$@" >> "$gpu_commands"; printf '\n' >> "$gpu_commands"; }
run_node_shell() { printf 'run_node_shell' >> "$gpu_commands"; printf ' %q' "$@" >> "$gpu_commands"; printf '\n' >> "$gpu_commands"; }
NODE_GPU_STATE=available
NODE_GPU_RENDER_DEVICES=(/dev/dri/renderD128)
NODE_GPU_NVIDIA_DEVICES=(/dev/nvidia0 /dev/nvidiactl)
NODE_GPU_NVIDIA_MAJORS=(195 195)
NODE_GPU_NVIDIA_MINORS=(0 255)
NODE_GPU_NVIDIA_GIDS=(44 44)
if reconcile_stopped_ct_gpu_config 3500 > /dev/null; then
  assert_contains "GPU config removal runs on owner node" "$gpu_commands" "run_on_node pve02 sed -i"
  assert_contains "GPU config append runs on owner node" "$gpu_commands" "run_node_shell pve02"
  assert_contains "GPU config targets owner-local LXC path" "$gpu_commands" "/etc/pve/lxc/3500.conf"
  assert_contains "NVIDIA cgroup uses discovered major" "$gpu_commands" "c\\ 195:\*\\ rwm"
  assert_contains "NVIDIA device bind uses stable guest path" "$gpu_commands" "/dev/nvidia0\\ dev/nvidia0"
else
  fail "GPU config mutation is owner-routed"
fi

: > "$gpu_commands"
NODE_GPU_STATE=absent
if reconcile_stopped_ct_gpu_config 2400 > /dev/null; then
  assert_contains "irrelevant GPU reconciliation removes managed DRM" "$gpu_commands" "run_on_node pve02 sed -i"
  assert_not_contains "irrelevant GPU reconciliation does not append DRM" "$gpu_commands" "run_node_shell"
else
  fail "irrelevant GPU reconciliation removes managed DRM"
fi
gpu_probe_called=false
detect_node_gpu_capability() { gpu_probe_called=true; return 1; }
if resolve_ct_gpu_capability 2400 pve02 "" \
   && [[ "$NODE_GPU_STATE" == "absent" && "$gpu_probe_called" == false ]]; then
  pass "irrelevant GPU capability skips node probing"
else
  fail "irrelevant GPU capability skips node probing"
fi

gpu_finalize_output=$(finalize_ct_gpu_capability 2700 pve02 "")
if [[ "$gpu_finalize_output" == *"GPU profile group is not used"* ]]; then
  pass "irrelevant GPU finalization is skipped"
else
  fail "irrelevant GPU finalization is skipped"
fi
gpu_probe_called=false
detect_node_gpu_capability() { gpu_probe_called=true; return 1; }
if ! resolve_ct_gpu_capability 2700 pve02 gpu \
   && [[ "$gpu_probe_called" == true ]]; then
  pass "relevant GPU capability probes the owner node"
else
  fail "relevant GPU capability probes the owner node"
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
assert_not_contains "referenced retired Newt ID is removed" "$optional_env" "NEWT_ID="
assert_not_contains "referenced retired Newt secret is removed" "$optional_env" "NEWT_SECRET="
assert_not_contains "referenced retired Newt endpoint is removed" "$optional_env" "NEWT_ENDPOINT="

unused_optional_env=$(run_optional_env_case unused-optional 'services: {}')
assert_not_contains "unreferenced Caddy email is removed" "$unused_optional_env" "CADDY_EMAIL="
assert_not_contains "unreferenced Newt ID is removed" "$unused_optional_env" "NEWT_ID="
assert_not_contains "unreferenced Newt secret is removed" "$unused_optional_env" "NEWT_SECRET="
assert_not_contains "unreferenced Newt endpoint is removed" "$unused_optional_env" "NEWT_ENDPOINT="
assert_not_contains "unreferenced Newt comment is removed" "$unused_optional_env" "Newt/Pangolin tunnel configuration"

compose_up_source=$(declare -f compose_up)
if [[ "$compose_up_source" == *'update_env_file "$stage_env"'* ]] \
   && [[ "$compose_up_source" == *'get_ct_host_root_ids "$ctid"'* ]] \
   && [[ "$compose_up_source" == *'node_upload_file "$node" "$stage_env" "$env_file" 0600 "$root_uid" "$root_gid"'* ]] \
   && [[ "$compose_up_source" != *'ct_upload_file "$ctid" "$stage_env"'* ]] \
   && [[ "$compose_up_source" != *'set_or_add_env "NEWT_ID"'* ]]; then
  pass "Compose startup reuses centralized mapped environment publication"
else
  fail "Compose startup reuses centralized mapped environment publication"
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