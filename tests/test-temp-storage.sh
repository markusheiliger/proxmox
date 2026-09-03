#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
PASS=0
FAIL=0

pass() { echo "ok - $1"; PASS=$((PASS + 1)); }
test_fail() { echo "not ok - $1" >&2; FAIL=$((FAIL + 1)); }

mkdir -p "${TEST_ROOT}/bin"
cat >"${TEST_ROOT}/bin/lvs" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"-o lv_attr pve/data"*) echo "twi-a-tz--" ;;
  *"--units b --nosuffix -o lv_size pve/data"*) echo "858993459200" ;;
  *"--nosuffix -o data_percent pve/data"*) echo "0.00" ;;
  *"-o pool_lv pve/temp"*) echo "data" ;;
  *"-o lv_tags pve/temp"*) echo "backup_temp_storage" ;;
  *"--units b --nosuffix -o lv_size pve/temp"*) echo "${TEMP_CURRENT_BYTES:-34359738368}" ;;
  *"pve/temp"*) [[ "${TEMP_EXISTING:-false}" == true ]] ;;
  *) exit 1 ;;
esac
EOF
cat >"${TEST_ROOT}/bin/blkid" <<'EOF'
#!/usr/bin/env bash
if [[ "${TEMP_EXISTING:-false}" == true && "$*" == *"-s TYPE"* ]]; then
  echo ext4
else
  exit 1
fi
EOF
cat >"${TEST_ROOT}/bin/findmnt" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod 0755 "${TEST_ROOT}/bin/lvs" "${TEST_ROOT}/bin/blkid" "${TEST_ROOT}/bin/findmnt"

output=$(PATH="${TEST_ROOT}/bin:${PATH}" \
  TEMP_TARGET_GIB=64 TEMP_DRY_RUN=true TEMP_MOUNTPOINT="${TEST_ROOT}/TEMP" \
  "${SCRIPT_DIR}/backup/provision-temp-storage")
if grep -Fq 'lvcreate --type thin --thinpool pve/data --virtualsize 64G --name temp --addtag backup_temp_storage' <<<"$output" && \
  grep -Fq 'mkfs.ext4 -F -L TEMP /dev/pve/temp' <<<"$output" && \
  grep -Fq 'Would persist /dev/pve/temp by UUID' <<<"$output"; then
  pass "dry run plans a tagged 64 GiB thin ext4 TEMP volume"
else
  printf '%s\n' "$output" >&2
  test_fail "dry run plans a tagged 64 GiB thin ext4 TEMP volume"
fi

if [[ ! -e "${TEST_ROOT}/TEMP" ]]; then
  pass "dry run does not create the TEMP mountpoint"
else
  test_fail "dry run does not create the TEMP mountpoint"
fi

growth_output=$(PATH="${TEST_ROOT}/bin:${PATH}" TEMP_EXISTING=true TEMP_CURRENT_BYTES=34359738368 \
  TEMP_TARGET_GIB=64 TEMP_DRY_RUN=true TEMP_MOUNTPOINT="${TEST_ROOT}/TEMP" \
  "${SCRIPT_DIR}/backup/provision-temp-storage")
if grep -Fq 'lvextend -L 64G pve/temp' <<<"$growth_output"; then
  pass "rerun grows an undersized managed TEMP thin LV"
else
  printf '%s\n' "$growth_output" >&2
  test_fail "rerun grows an undersized managed TEMP thin LV"
fi

larger_output=$(PATH="${TEST_ROOT}/bin:${PATH}" TEMP_EXISTING=true TEMP_CURRENT_BYTES=137438953472 \
  TEMP_TARGET_GIB=64 TEMP_DRY_RUN=true TEMP_MOUNTPOINT="${TEST_ROOT}/TEMP" \
  "${SCRIPT_DIR}/backup/provision-temp-storage")
if grep -Fq 'automatic shrinking is disabled' <<<"$larger_output" && ! grep -Fq 'lvreduce' <<<"$larger_output"; then
  pass "rerun never shrinks a larger managed TEMP thin LV"
else
  printf '%s\n' "$larger_output" >&2
  test_fail "rerun never shrinks a larger managed TEMP thin LV"
fi

source "${SCRIPT_DIR}/backupCT.sh"
DRY_RUN=true
pvesh() { return 1; }
registration_output=$(reconcile_temp_pve_storage TEMP /TEMP pve01,pve02)
unset -f pvesh
if grep -Fq 'Would register PVE directory storage TEMP at /TEMP: nodes=pve01,pve02, content=snippets, is_mountpoint=1.' <<<"$registration_output"; then
  pass "dry run exposes TEMP in Proxmox without disk or backup content"
else
  printf '%s\n' "$registration_output" >&2
  test_fail "dry run exposes TEMP in Proxmox without disk or backup content"
fi

echo "${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]