#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOKS="${SCRIPT_DIR}/imds/hooks"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
PASS=0
FAIL=0

pass() { echo "ok - $1"; PASS=$((PASS + 1)); }
fail() { echo "not ok - $1" >&2; FAIL=$((FAIL + 1)); }

cat >"${TEST_ROOT}/pvesh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == "get /nodes/localhost/lxc --output-format json" ]]
printf '%s\n' '[{"vmid":2100},{"vmid":42}]'
MOCK

cat >"${TEST_ROOT}/generator" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  metadata) printf '{"tags":"profile-gpu-none"}\n' ;;
  profiles) printf '["gpu-none"]\n' ;;
  *) exit 64 ;;
esac
MOCK
chmod +x "${TEST_ROOT}/generator" "${TEST_ROOT}/pvesh"
mkdir -p "${TEST_ROOT}/lxc"
: > "${TEST_ROOT}/lxc/2100.conf"
: > "${TEST_ROOT}/lxc/42.conf"

run_hook() {
  PVE_IMDS_PVESH="${TEST_ROOT}/pvesh" \
    PVE_IMDS_GENERATOR="${TEST_ROOT}/generator" \
    PVE_IMDS_LOCAL_LXC_CONFIG_DIR="${TEST_ROOT}/lxc" \
    "${HOOKS}/$1" "${@:2}"
}

metadata_size="$(printf '{"tags":"profile-gpu-none"}\n' | wc -c)"
metadata_stat="$(run_hook getattr /2100/metadata.json)"
if [[ "$metadata_stat" == *"mode=-r--r--r--"* && "$metadata_stat" == *"size=${metadata_size} "* ]]; then
  pass "getattr reports exact generated metadata size"
else
  fail "getattr reports exact generated metadata size"
fi

if run_hook getattr /021/metadata.json >/dev/null 2>&1; then
  fail "getattr rejects non-canonical CTID paths"
else
  pass "getattr rejects non-canonical CTID paths"
fi

if run_hook open /2100/metadata.json | grep -q .; then
  fail "open emits no physical backing path"
else
  pass "open emits no physical backing path"
fi

root_entries="$(run_hook readdir / | tr '\0' '\n' | sed -n 's/.* //p' | paste -sd, -)"
if [[ "$root_entries" == '.,..,42,2100' ]]; then
  pass "root listing is numeric, sorted, and filters malformed names"
else
  echo "root entries: ${root_entries}" >&2
  fail "root listing is numeric, sorted, and filters malformed names"
fi

ct_entries="$(run_hook readdir /2100 | tr '\0' '\n' | sed -n 's/.* //p' | paste -sd, -)"
if [[ "$ct_entries" == '.,..,metadata.json,profiles.json' ]]; then
  pass "CT listing exposes exactly the two metadata files"
else
  fail "CT listing exposes exactly the two metadata files"
fi

if [[ "$(run_hook read_file /2100/profiles.json)" == '["gpu-none"]' ]]; then
  pass "read_file dispatches to the shared generator"
else
  fail "read_file dispatches to the shared generator"
fi

cat >"${TEST_ROOT}/pvesh-unavailable" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
chmod +x "${TEST_ROOT}/pvesh-unavailable"
if PVE_IMDS_PVESH="${TEST_ROOT}/pvesh-unavailable" \
  PVE_IMDS_GENERATOR="${TEST_ROOT}/generator" \
  PVE_IMDS_LOCAL_LXC_CONFIG_DIR="${TEST_ROOT}/lxc" \
  "${HOOKS}/getattr" /2100 >/dev/null; then
  pass "CT directory remains visible when the API is unavailable during pre-start"
else
  fail "CT directory remains visible when the API is unavailable during pre-start"
fi

if "${HOOKS}/check_args" 0 && ! "${HOOKS}/check_args" 1 >/dev/null 2>&1; then
  pass "check_args accepts only execfuse API version 0"
else
  fail "check_args accepts only execfuse API version 0"
fi

echo "${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]