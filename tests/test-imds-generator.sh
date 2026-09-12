#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GENERATOR="${SCRIPT_DIR}/imds/lib/pve-imds-generate"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
PASS=0
FAIL=0

pass() { echo "ok - $1"; PASS=$((PASS + 1)); }
fail() { echo "not ok - $1" >&2; FAIL=$((FAIL + 1)); }

cat >"${TEST_ROOT}/pvesh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == "get /nodes/localhost/lxc/2100/config --output-format json" ]]
cat <<'JSON'
{
  "arch": "amd64",
  "cores": 4,
  "dev0": "/dev/dri/renderD128",
  "digest": "abc123",
  "hookscript": "local:snippets/hook.pl",
  "hostname": "example.thesaints.home",
  "lxc": ["lxc.apparmor.profile=unconfined"],
  "lock": "backup",
  "memory": 4096,
  "mp0": "/host/private,mp=/private",
  "net0": "name=eth0,bridge=vmbr0,ip=dhcp",
  "rootfs": "local-lvm:vm-2100-disk-0,size=8G",
  "ssh-public-keys": "ssh-ed25519 secret",
  "tags": "managed;profile-gpu-drm_intel;profile-runtime-cpu"
}
JSON
MOCK
chmod +x "${TEST_ROOT}/pvesh"

run_generator() {
  PVE_IMDS_PVESH="${TEST_ROOT}/pvesh" \
    "$GENERATOR" "$@"
}

metadata="$(run_generator metadata 2100)"
if jq -e '
    .arch == "amd64"
    and .cores == 4
    and .digest == "abc123"
    and .lock == "backup"
    and .net0 == "name=eth0,bridge=vmbr0,ip=dhcp"
    and .tags == "managed;profile-gpu-drm_intel;profile-runtime-cpu"
    and (has("rootfs") | not)
    and (has("hookscript") | not)
    and (has("ssh-public-keys") | not)
    and (has("lxc") | not)
    and (has("mp0") | not)
    and (has("dev0") | not)
  ' <<<"$metadata" >/dev/null; then
  pass "metadata preserves API fields and removes host-bound fields"
else
  fail "metadata preserves API fields and removes host-bound fields"
fi

profiles="$(run_generator profiles 2100)"
if [[ "$profiles" == '["gpu-drm_intel","runtime-cpu"]' ]]; then
  pass "profile tags are sanitized and sorted"
else
  fail "profile tags are sanitized and sorted"
fi

if [[ "$(jq -c -f "${SCRIPT_DIR}/imds/filters/profiles.jq" <<<'{"tags":null}')" == '[]' ]]; then
  pass "missing profile tags produce an empty array"
else
  fail "missing profile tags produce an empty array"
fi

if jq -e -f "${SCRIPT_DIR}/imds/filters/profiles.jq" \
  <<<'{"tags":"profile-gpu-"}' >/dev/null 2>&1; then
  fail "malformed profile tags are rejected"
else
  pass "malformed profile tags are rejected"
fi

if jq -e -f "${SCRIPT_DIR}/imds/filters/profiles.jq" \
  <<<'{"tags":"profile-gpu-none;profile-gpu-drm_nvidia"}' >/dev/null 2>&1; then
  fail "multiple winners for one group are rejected"
else
  pass "multiple winners for one group are rejected"
fi

if [[ "$(jq -c -f "${SCRIPT_DIR}/imds/filters/profiles.jq" <<<'{"tags":"compose-profile.vulkan"}')" == '[]' ]]; then
  pass "legacy Compose profile tags are not activated"
else
  fail "legacy Compose profile tags are not activated"
fi

if run_generator metadata 02100 >/dev/null 2>&1; then
  fail "non-canonical CTID is rejected"
else
  pass "non-canonical CTID is rejected"
fi

if run_generator metadata 1000000000 >/dev/null 2>&1; then
  fail "out-of-range CTID is rejected"
else
  pass "out-of-range CTID is rejected"
fi

if run_generator metadata 2200 >/dev/null 2>&1; then
  fail "non-local CT is rejected by the local-node API"
else
  pass "non-local CT is rejected by the local-node API"
fi

echo "${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]