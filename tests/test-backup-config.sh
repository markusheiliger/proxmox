#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
PASS=0
FAIL=0

pass() { echo "ok - $1"; PASS=$((PASS + 1)); }
fail() { echo "not ok - $1" >&2; FAIL=$((FAIL + 1)); }

assert_failure_contains() {
  local name="$1" expected="$2"
  shift 2
  if "$@" >"${TEST_ROOT}/output" 2>&1; then
    fail "$name"
  elif grep -Fq "$expected" "${TEST_ROOT}/output"; then
    pass "$name"
  else
    cat "${TEST_ROOT}/output" >&2
    fail "$name"
  fi
}

export SCRIPT_DIR
export CONFIG_FILE="${TEST_ROOT}/commonCT.json"
cp "${SCRIPT_DIR}/commonCT.json" "$CONFIG_FILE"
source "${SCRIPT_DIR}/commonCT.sh"

if validate_backup_config; then pass "repository backup policy is valid"; else fail "repository backup policy is valid"; fi

if [[ "$(config_get_backup_storage)" == "SYNOLOGY" && \
  "$(config_get_backup_tmpdir)" == "/TEMP/vzdump-tmp" && \
  "$(config_get_backup_temp_storage_id)" == "TEMP" && \
  "$(config_get_backup_temp_vg)" == "pve" && \
  "$(config_get_backup_temp_thin_pool)" == "data" && \
  "$(config_get_backup_temp_lv)" == "temp" && \
  "$(config_get_backup_temp_filesystem)" == "ext4" && \
  "$(config_get_backup_temp_size_multiplier)" == "2" && \
      "$(config_get_backup_mode)" == "suspend" && \
      "$(config_get_backup_compress)" == "zstd" && \
      "$(config_get_backup_keep_daily)" == "7" && \
      "$(config_get_backup_vm_job_id)" == "vm-backup" && \
      "$(config_get_backup_vm_mode)" == "snapshot" && \
      "$(config_get_backup_vm_schedule)" == "*-*-* 00:00:00" && \
      "$(config_get_backup_vm_restore_storage)" == "DATA" ]]; then
  pass "typed backup accessors return policy values"
else
  fail "typed backup accessors return policy values"
fi

jq '.backup.mode = "snapshot"' "$CONFIG_FILE" >"${TEST_ROOT}/invalid.json"
CONFIG_FILE="${TEST_ROOT}/invalid.json"
assert_failure_contains "non-suspend mode is rejected" "backup.mode must be suspend" validate_backup_config

jq '.backup.snapshot_headroom_percent = 0' "$CONFIG_FILE" >"${TEST_ROOT}/headroom.json"
CONFIG_FILE="${TEST_ROOT}/headroom.json"
assert_failure_contains "invalid snapshot headroom is rejected" "must be an integer from 1 to 90" validate_backup_config

jq '.backup.temp_storage.filesystem = "xfs"' "$CONFIG_FILE" >"${TEST_ROOT}/temp-filesystem.json"
CONFIG_FILE="${TEST_ROOT}/temp-filesystem.json"
assert_failure_contains "unsupported TEMP filesystem is rejected" "backup.temp_storage.filesystem must be ext4" validate_backup_config

jq '.backup.vm.mode = "suspend"' "$CONFIG_FILE" >"${TEST_ROOT}/vm-mode.json"
CONFIG_FILE="${TEST_ROOT}/vm-mode.json"
assert_failure_contains "non-snapshot VM mode is rejected" "backup.vm.mode must be snapshot" validate_backup_config

jq '.backup.vm.job_id = .backup.job_id' "$CONFIG_FILE" >"${TEST_ROOT}/duplicate-job.json"
CONFIG_FILE="${TEST_ROOT}/duplicate-job.json"
assert_failure_contains "duplicate CT and VM job IDs are rejected" "backup.vm.job_id must differ" validate_backup_config

jq '.backup.exclude_tags = []' "$CONFIG_FILE" >"${TEST_ROOT}/empty-tags.json"
CONFIG_FILE="${TEST_ROOT}/empty-tags.json"
assert_failure_contains "empty backup exclusion tags are rejected" "backup.exclude_tags must be a non-empty array" validate_backup_config

CONFIG_FILE="${TEST_ROOT}/commonCT.json"
resources='[
  {"type":"lxc","vmid":2200},
  {"type":"lxc","vmid":2201,"tags":"no-backup"},
  {"type":"lxc","vmid":92200,"tags":"backup-restore-test"},
  {"type":"qemu","vmid":1000},
  {"type":"qemu","vmid":1001,"tags":"other;no-backup"},
  {"type":"qemu","vmid":91000,"tags":"backup-restore-test"}
]'
if [[ "$(backup_resource_ids lxc "$resources")" == 2200 && "$(backup_resource_ids qemu "$resources")" == 1000 ]]; then
  pass "type-specific selectors honor shared exclusion tags"
else
  fail "type-specific selectors honor shared exclusion tags"
fi

echo "${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]