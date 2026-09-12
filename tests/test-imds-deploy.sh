#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY="${SCRIPT_DIR}/imds/deploy.sh"
INSTALLER="${SCRIPT_DIR}/imds/scripts/install-release.sh"
UNIT="${SCRIPT_DIR}/imds/systemd/pve-imds.service"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
PASS=0
FAIL=0

pass() { echo "ok - $1"; PASS=$((PASS + 1)); }
fail() { echo "not ok - $1" >&2; FAIL=$((FAIL + 1)); }

if grep -Eq '^(PrivateTmp|ProtectHome|ProtectSystem|ReadOnlyPaths|ReadWritePaths)=' "$UNIT"; then
  fail "service keeps the FUSE mount in the host mount namespace"
else
  pass "service keeps the FUSE mount in the host mount namespace"
fi

if grep -Fq 'install -d -o root -g root -m 0755 "$MOUNTPOINT"' "$INSTALLER"; then
  fail "systemd exclusively owns IMDS mountpoint creation"
elif grep -Fxq 'ExecStartPre=/usr/bin/install -d -o root -g root -m 0755 /run/pve-imds' "$UNIT"; then
  pass "systemd exclusively owns IMDS mountpoint creation"
else
  fail "systemd exclusively owns IMDS mountpoint creation"
fi

cat >"${TEST_ROOT}/pvesh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == "get /nodes --output-format json" ]]
if [[ -n "${PVE_IMDS_TEST_NODES:-}" ]]; then
  printf '%s\n' "$PVE_IMDS_TEST_NODES"
else
  printf '%s\n' '[{"node":"pve01","status":"online"},{"node":"pve02","status":"online"}]'
fi
MOCK

cat >"${TEST_ROOT}/build" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
install -m 0755 /bin/true "$1"
MOCK

cat >"${TEST_ROOT}/installer" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
bundle="$1"
release_id="$2"
[[ "$release_id" =~ ^[a-f0-9]{16}$ ]]
(
  cd "$bundle/release"
  sha256sum -c checksums.sha256 >/dev/null
)
(
  cd "$bundle"
  sha256sum -c bundle-checksums.sha256 >/dev/null
)
test -x "$bundle/release/execfuse"
test -x "$bundle/release/hooks/read_file"
test -x "$bundle/release/lib/pve-imds-generate"
test -f "$bundle/release/filters/profiles.jq"
test -f "$bundle/pve-imds.service"
test -x "$bundle/pve-imds-health"
printf '%s\n' "$release_id" >"${PVE_IMDS_TEST_ROOT}/local-release"
exit "${PVE_IMDS_TEST_INSTALL_STATUS:-0}"
MOCK

cat >"${TEST_ROOT}/ssh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${PVE_IMDS_TEST_ROOT}/ssh.log"
if [[ "$*" == *"bash -s"* ]]; then
  cat >/dev/null
  [[ "${PVE_IMDS_TEST_REMOTE_STATUS:-0}" == 0 ]] || exit "$PVE_IMDS_TEST_REMOTE_STATUS"
  printf '%b\n' "${PVE_IMDS_TEST_REMOTE_RESULT:-HEALTHY\\t0123456789abcdef\\t0123456789abcdef\\tservice and metadata are healthy}"
elif [[ "$*" == *"dpkg --print-architecture"* ]]; then
  printf 'amd64\n'
else
  tar -tf - >"${PVE_IMDS_TEST_ROOT}/remote-bundle"
fi
MOCK

chmod +x "${TEST_ROOT}/pvesh" "${TEST_ROOT}/build" \
  "${TEST_ROOT}/installer" "${TEST_ROOT}/ssh"

if PVE_IMDS_PVESH="${TEST_ROOT}/pvesh" \
  PVE_IMDS_BUILD_SCRIPT="${TEST_ROOT}/build" \
  PVE_IMDS_INSTALLER="${TEST_ROOT}/installer" \
  PVE_IMDS_SSH="${TEST_ROOT}/ssh" \
  PVE_IMDS_LOCAL_NODE=pve01 \
  PVE_IMDS_TEST_ROOT="$TEST_ROOT" \
  "$DEPLOY" >"${TEST_ROOT}/deploy.out" 2>"${TEST_ROOT}/deploy.err"; then
  pass "deployment succeeds across local and remote online nodes"
else
  cat "${TEST_ROOT}/deploy.err" >&2
  fail "deployment succeeds across local and remote online nodes"
fi

if [[ -s "${TEST_ROOT}/local-release" ]] \
  && grep -Fq 'pve02' "${TEST_ROOT}/ssh.log"; then
  pass "deployment routes each node through the correct boundary"
else
  fail "deployment routes each node through the correct boundary"
fi

if grep -Fxq './release/checksums.sha256' "${TEST_ROOT}/remote-bundle" \
  && grep -Fxq './release/hooks/read_file' "${TEST_ROOT}/remote-bundle" \
  && grep -Fxq './bundle-checksums.sha256' "${TEST_ROOT}/remote-bundle" \
  && grep -Fxq './install-release.sh' "${TEST_ROOT}/remote-bundle"; then
  pass "remote bundle contains the verified release and installer"
else
  cat "${TEST_ROOT}/remote-bundle" >&2
  fail "remote bundle contains the verified release and installer"
fi

if "$DEPLOY" --unknown >/dev/null 2>&1; then
  fail "unknown arguments are rejected"
elif [[ $? -eq 64 ]]; then
  pass "unknown arguments are rejected"
else
  fail "unknown arguments are rejected"
fi

mkdir -p "${TEST_ROOT}/cluster/pve-offline/lxc"
cat >"${TEST_ROOT}/cluster/pve-offline/lxc/2100.conf" <<'CONF'
mp2: /run/pve-imds/2100,mp=/mnt/pve-imds,ro=1,shared=1,backup=0
CONF
rm -f "${TEST_ROOT}/remove-called"
cat >"${TEST_ROOT}/remove-installer" <<'MOCK'
#!/usr/bin/env bash
touch "${PVE_IMDS_TEST_ROOT}/remove-called"
MOCK
chmod +x "${TEST_ROOT}/remove-installer"
if PVE_IMDS_PVESH="${TEST_ROOT}/pvesh" \
  PVE_IMDS_INSTALLER="${TEST_ROOT}/remove-installer" \
  PVE_IMDS_SSH="${TEST_ROOT}/ssh" \
  PVE_IMDS_LOCAL_NODE=pve01 \
  PVE_IMDS_CLUSTER_CONFIG_ROOT="${TEST_ROOT}/cluster" \
  PVE_IMDS_TEST_ROOT="$TEST_ROOT" \
  "$DEPLOY" --remove >"${TEST_ROOT}/remove.out" 2>"${TEST_ROOT}/remove.err"; then
  fail "configured consumer blocks removal"
elif [[ $? -eq 73 && ! -e "${TEST_ROOT}/remove-called" ]] \
  && grep -Fq '/pve-offline/lxc/2100.conf' "${TEST_ROOT}/remove.err"; then
  pass "configured offline-owner consumer blocks all removal mutations"
else
  cat "${TEST_ROOT}/remove.err" >&2
  fail "configured consumer blocks removal"
fi

single_node='[{"node":"pve01","status":"online"}]'
if PVE_IMDS_PVESH="${TEST_ROOT}/pvesh" \
  PVE_IMDS_BUILD_SCRIPT="${TEST_ROOT}/build" \
  PVE_IMDS_INSTALLER="${TEST_ROOT}/installer" \
  PVE_IMDS_SSH="${TEST_ROOT}/ssh" \
  PVE_IMDS_LOCAL_NODE=pve01 \
  PVE_IMDS_TEST_ROOT="$TEST_ROOT" \
  PVE_IMDS_TEST_NODES="$single_node" \
  PVE_IMDS_TEST_INSTALL_STATUS=10 \
  "$DEPLOY" >"${TEST_ROOT}/staged.out" 2>"${TEST_ROOT}/staged.err"; then
  fail "staged activation returns partial convergence"
elif grep -Fq 'PENDING: pve01 staged' "${TEST_ROOT}/staged.err"; then
  pass "staged activation returns partial convergence"
else
  cat "${TEST_ROOT}/staged.err" >&2
  fail "staged activation returns partial convergence"
fi

VERIFY_ROOT="${TEST_ROOT}/verify"
VERIFY_RUNTIME="${VERIFY_ROOT}/runtime"
VERIFY_HEALTH="${VERIFY_ROOT}/pve-imds-health"
VERIFY_UNIT="${VERIFY_ROOT}/pve-imds.service"
VERIFY_PROC="${VERIFY_ROOT}/proc"
VERIFY_SYSTEMCTL="${VERIFY_ROOT}/systemctl"
CURRENT_RELEASE=0123456789abcdef
ACTIVE_RELEASE=fedcba9876543210

mkdir -p "$VERIFY_ROOT"
cat >"$VERIFY_SYSTEMCTL" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == "show pve-imds.service -p MainPID --value" ]]
printf '123\n'
MOCK
chmod +x "$VERIFY_SYSTEMCTL"

reset_verify_fixture() {
  rm -rf "$VERIFY_RUNTIME" "$VERIFY_PROC"
  rm -f "$VERIFY_HEALTH" "$VERIFY_UNIT"
  mkdir -p "$VERIFY_RUNTIME" "$VERIFY_PROC/123"
}

complete_verify_fixture() {
  local current_release="$1" active_release="$2" health_status="${3:-0}"
  mkdir -p "$VERIFY_RUNTIME/releases/$current_release" \
    "$VERIFY_RUNTIME/releases/$active_release" "$VERIFY_PROC/123"
  printf 'pve-imds\n' >"$VERIFY_RUNTIME/.pve-imds-managed"
  touch "$VERIFY_RUNTIME/releases/$current_release/execfuse" \
    "$VERIFY_RUNTIME/releases/$active_release/execfuse" "$VERIFY_UNIT"
  chmod +x "$VERIFY_RUNTIME/releases/$current_release/execfuse" \
    "$VERIFY_RUNTIME/releases/$active_release/execfuse"
  ln -s "releases/$current_release" "$VERIFY_RUNTIME/current"
  ln -s "$VERIFY_RUNTIME/releases/$active_release/execfuse" "$VERIFY_PROC/123/exe"
  cat >"$VERIFY_HEALTH" <<MOCK
#!/usr/bin/env bash
echo '${health_status}' | grep -qx 0 || { echo 'ERROR: fixture health check failed' >&2; exit 1; }
MOCK
  chmod +x "$VERIFY_HEALTH"
}

verify_fixture() {
  PVE_IMDS_PVESH="${TEST_ROOT}/pvesh" \
    PVE_IMDS_SSH="${TEST_ROOT}/ssh" \
    PVE_IMDS_LOCAL_NODE=pve01 \
    PVE_IMDS_TEST_ROOT="$TEST_ROOT" \
    PVE_IMDS_TEST_NODES="${PVE_IMDS_TEST_NODES:-$single_node}" \
    PVE_IMDS_VERIFY_RUNTIME_ROOT="$VERIFY_RUNTIME" \
    PVE_IMDS_VERIFY_HEALTH_PATH="$VERIFY_HEALTH" \
    PVE_IMDS_VERIFY_UNIT_PATH="$VERIFY_UNIT" \
    PVE_IMDS_VERIFY_PROC_ROOT="$VERIFY_PROC" \
    PVE_IMDS_VERIFY_SYSTEMCTL="$VERIFY_SYSTEMCTL" \
    PVE_IMDS_BUILD_SCRIPT=/does/not-exist \
    PVE_IMDS_INSTALLER=/does/not-exist \
    "$DEPLOY" --verify
}

reset_verify_fixture
if verify_fixture >"${TEST_ROOT}/verify-absent.out" 2>&1; then
  fail "verification reports an absent installation"
elif grep -Fq 'pve01: NOT INSTALLED - managed artifacts are absent' \
  "${TEST_ROOT}/verify-absent.out"; then
  pass "verification reports an absent installation"
else
  cat "${TEST_ROOT}/verify-absent.out" >&2
  fail "verification reports an absent installation"
fi

reset_verify_fixture
printf 'pve-imds\n' >"$VERIFY_RUNTIME/.pve-imds-managed"
if verify_fixture >"${TEST_ROOT}/verify-broken.out" 2>&1; then
  fail "verification reports an incomplete managed installation"
elif grep -Fq 'pve01: BROKEN - managed installation is incomplete' \
  "${TEST_ROOT}/verify-broken.out"; then
  pass "verification reports an incomplete managed installation"
else
  cat "${TEST_ROOT}/verify-broken.out" >&2
  fail "verification reports an incomplete managed installation"
fi

reset_verify_fixture
complete_verify_fixture "$CURRENT_RELEASE" "$CURRENT_RELEASE" 1
if verify_fixture >"${TEST_ROOT}/verify-unhealthy.out" 2>&1; then
  fail "verification reports a failing health check"
elif grep -Fq 'pve01: UNHEALTHY - ERROR: fixture health check failed' \
  "${TEST_ROOT}/verify-unhealthy.out"; then
  pass "verification reports a failing health check"
else
  cat "${TEST_ROOT}/verify-unhealthy.out" >&2
  fail "verification reports a failing health check"
fi

reset_verify_fixture
complete_verify_fixture "$CURRENT_RELEASE" "$CURRENT_RELEASE"
if verify_fixture >"${TEST_ROOT}/verify-healthy.out" 2>&1 \
  && grep -Fq "pve01: HEALTHY current=$CURRENT_RELEASE active=$CURRENT_RELEASE" \
    "${TEST_ROOT}/verify-healthy.out" \
  && grep -Fq 'Summary: HEALTHY=1' "${TEST_ROOT}/verify-healthy.out"; then
  pass "verification succeeds for a healthy converged node without deployment sources"
else
  cat "${TEST_ROOT}/verify-healthy.out" >&2
  fail "verification succeeds for a healthy converged node without deployment sources"
fi

reset_verify_fixture
complete_verify_fixture "$CURRENT_RELEASE" "$ACTIVE_RELEASE"
if verify_fixture >"${TEST_ROOT}/verify-staged.out" 2>&1; then
  fail "verification reports a staged release as non-converged"
elif grep -Fq "pve01: STAGED current=$CURRENT_RELEASE active=$ACTIVE_RELEASE" \
  "${TEST_ROOT}/verify-staged.out"; then
  pass "verification reports a staged release as non-converged"
else
  cat "${TEST_ROOT}/verify-staged.out" >&2
  fail "verification reports a staged release as non-converged"
fi

reset_verify_fixture
complete_verify_fixture "$CURRENT_RELEASE" "$CURRENT_RELEASE"
two_online='[{"node":"pve02","status":"online"},{"node":"pve01","status":"online"}]'
remote_healthy="HEALTHY\t${CURRENT_RELEASE}\t${CURRENT_RELEASE}\tservice and metadata are healthy"
if PVE_IMDS_TEST_NODES="$two_online" PVE_IMDS_TEST_REMOTE_RESULT="$remote_healthy" \
  verify_fixture >"${TEST_ROOT}/verify-cluster.out" 2>&1 \
  && [[ "$(sed -n '1p' "${TEST_ROOT}/verify-cluster.out")" == pve01:* ]] \
  && [[ "$(sed -n '2p' "${TEST_ROOT}/verify-cluster.out")" == pve02:* ]] \
  && grep -Fq 'Summary: HEALTHY=2' "${TEST_ROOT}/verify-cluster.out"; then
  pass "verification routes and sorts healthy local and remote nodes"
else
  cat "${TEST_ROOT}/verify-cluster.out" >&2
  fail "verification routes and sorts healthy local and remote nodes"
fi

rm -f "${TEST_ROOT}/ssh.log"
online_offline='[{"node":"pve01","status":"online"},{"node":"pve02","status":"offline"}]'
if PVE_IMDS_TEST_NODES="$online_offline" verify_fixture >"${TEST_ROOT}/verify-offline.out" 2>&1; then
  fail "verification reports offline nodes without contacting them"
elif grep -Fq 'pve02: UNVERIFIED - node is offline' "${TEST_ROOT}/verify-offline.out" \
  && ! grep -Fq 'pve02' "${TEST_ROOT}/ssh.log" 2>/dev/null; then
  pass "verification reports offline nodes without contacting them"
else
  cat "${TEST_ROOT}/verify-offline.out" >&2
  fail "verification reports offline nodes without contacting them"
fi

if PVE_IMDS_TEST_NODES="$two_online" PVE_IMDS_TEST_REMOTE_STATUS=255 \
  verify_fixture >"${TEST_ROOT}/verify-unreachable.out" 2>&1; then
  fail "verification reports an unreachable online node"
elif grep -Fq 'pve02: UNREACHABLE - verification command failed' \
  "${TEST_ROOT}/verify-unreachable.out"; then
  pass "verification reports an unreachable online node"
else
  cat "${TEST_ROOT}/verify-unreachable.out" >&2
  fail "verification reports an unreachable online node"
fi

all_offline='[{"node":"pve02","status":"offline"},{"node":"pve01","status":"offline"}]'
rm -f "${TEST_ROOT}/ssh.log"
if PVE_IMDS_TEST_NODES="$all_offline" verify_fixture >"${TEST_ROOT}/verify-all-offline.out" 2>&1; then
  fail "verification inventories an entirely offline cluster"
elif grep -Fq 'pve01: UNVERIFIED - node is offline' "${TEST_ROOT}/verify-all-offline.out" \
  && grep -Fq 'pve02: UNVERIFIED - node is offline' "${TEST_ROOT}/verify-all-offline.out" \
  && ! test -e "${TEST_ROOT}/ssh.log"; then
  pass "verification inventories an entirely offline cluster"
else
  cat "${TEST_ROOT}/verify-all-offline.out" >&2
  fail "verification inventories an entirely offline cluster"
fi

echo "${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]