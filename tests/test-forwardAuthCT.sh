#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORWARD_AUTH_SCRIPT="${SCRIPT_DIR}/forwardAuthCT.sh"

python3 - "$FORWARD_AUTH_SCRIPT" <<'PY'
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    script = handle.read()

assert "'caddy.route.0_reverse_proxy.header_up: \"Host {http.reverse_proxy.upstream.host}\"'" in script
assert "'caddy.route.50_forward_auth.header_up: \"Host {http.reverse_proxy.upstream.host}\"'" in script
assert "'caddy.route.0_reverse_proxy.header_up: \"Host {http.request.host}\"'" not in script
assert "'caddy.route.50_forward_auth.header_up: \"Host {http.request.host}\"'" not in script
assert "caddy.route.50_forward_auth.trusted_proxies" not in script
PY

source "${SCRIPT_DIR}/commonCT.sh"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
PASS=1
FAIL=0
CALLS="${TEST_ROOT}/calls"
API_CALLS="${TEST_ROOT}/api-calls"
REMOTE_COMPOSE="${TEST_ROOT}/remote-compose.yaml"
OWNER_AVAILABLE=true
FILE_EXISTS=true

pass() { echo "ok - $1"; PASS=$((PASS + 1)); }
fail() { echo "not ok - $1" >&2; FAIL=$((FAIL + 1)); }

config_authentik_configured() { return 0; }
config_get_authentik_host() { echo auth.example.test; }
config_get_authentik_token() { echo test-token; }
config_get_authentik_outpost() { echo embedded; }
config_get_authentik_authorization_flow() { echo authorization; }
config_get_authentik_invalidation_flow() { echo invalidation; }
hostname() { echo pve01; }
get_ct_owner_node() {
  if [[ "$OWNER_AVAILABLE" == true ]]; then
    echo pve02
  else
    echo "ERROR: CT owner unavailable" >&2
    return 1
  fi
}
node_path_is_file() {
  printf 'file %s %s\n' "$1" "$2" >> "$CALLS"
  [[ "$1" == pve02 && "$2" == /mnt/docker/app.thesaints.home/docker-compose.yaml && "$FILE_EXISTS" == true ]]
}
run_on_node() {
  local node="$1"
  shift
  printf 'run %s %s\n' "$node" "$*" >> "$CALLS"
  [[ "$node" == pve02 && "$1" == grep ]] || return 1
  grep "$2" "$3" "$REMOTE_COMPOSE"
}
curl() {
  local arg previous="" method=GET path=""
  for arg in "$@"; do
    [[ "$previous" != -X ]] || method="$arg"
    if [[ "$arg" == https://auth.example.test/api/v3/* ]]; then
      path="${arg#https://auth.example.test/api/v3}"
    fi
    previous="$arg"
  done
  printf '%s %s\n' "$method" "$path" >> "$API_CALLS"
  case "$method $path" in
    'GET /core/applications/?slug=app-thesaints-home') echo '{"results":[]}' ;;
    'GET /flows/instances/?slug=authorization') echo '{"results":[{"pk":"authorization-id"}]}' ;;
    'GET /flows/instances/?slug=invalidation') echo '{"results":[{"pk":"invalidation-id"}]}' ;;
    'POST /providers/proxy/') echo '{"pk":15}' ;;
    'POST /core/applications/') echo '{"pk":"application-id"}' ;;
    'GET /outposts/instances/?name__iexact=embedded') echo '{"results":[{"pk":"outpost-id","providers":[11]}]}' ;;
    'PATCH /outposts/instances/outpost-id/') echo '{"pk":"outpost-id"}' ;;
    *) echo "Unexpected API call: $method $path" >&2; return 1 ;;
  esac
}

cat > "$REMOTE_COMPOSE" <<'YAML'
services:
  app:
    labels:
      caddy: ${HOSTFQDN}
      caddy.reverse_proxy: "{{upstreams 3000}}"
YAML

CTID=2200
CT_HOSTNAME=app.thesaints.home
if configure_authentik_forward_auth "$CT_HOSTNAME" >"${TEST_ROOT}/output" 2>&1 \
  && [[ -f "$API_CALLS" ]] \
  && grep -Fq 'POST /providers/proxy/' "$API_CALLS" \
  && grep -Fq 'POST /core/applications/' "$API_CALLS" \
  && grep -Fq 'PATCH /outposts/instances/outpost-id/' "$API_CALLS"; then
  pass "first enable provisions application and outpost before forward-auth labels exist"
else
  cat "${TEST_ROOT}/output" >&2
  fail "first enable provisions application and outpost before forward-auth labels exist"
fi
if [[ -f "$CALLS" ]] \
  && grep -Fq 'file pve02 /mnt/docker/app.thesaints.home/docker-compose.yaml' "$CALLS" \
  && grep -Fq 'run pve02 grep' "$CALLS"; then
  pass "eligibility reads the authoritative remote-owner Compose file"
else
  fail "eligibility reads the authoritative remote-owner Compose file"
fi

: > "$API_CALLS"
FILE_EXISTS=false
if configure_authentik_forward_auth "$CT_HOSTNAME" >"${TEST_ROOT}/output" 2>&1; then
  fail "missing owner-node Compose file fails before provisioning"
elif [[ ! -s "$API_CALLS" ]]; then
  pass "missing owner-node Compose file fails before provisioning"
else
  fail "missing owner-node Compose file fails before provisioning"
fi

FILE_EXISTS=true
printf 'services: {}\n' > "$REMOTE_COMPOSE"
if configure_authentik_forward_auth "$CT_HOSTNAME" >"${TEST_ROOT}/output" 2>&1; then
  fail "missing Caddy site fails before provisioning"
elif [[ ! -s "$API_CALLS" ]]; then
  pass "missing Caddy site fails before provisioning"
else
  fail "missing Caddy site fails before provisioning"
fi

OWNER_AVAILABLE=false
if configure_authentik_forward_auth "$CT_HOSTNAME" >"${TEST_ROOT}/output" 2>&1; then
  fail "unresolved CT owner fails closed"
elif [[ ! -s "$API_CALLS" ]]; then
  pass "unresolved CT owner fails closed"
else
  fail "unresolved CT owner fails closed"
fi

echo "${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]