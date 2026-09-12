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

if [[ "$(config_get_backup_temp_storage)" == "TEMP" && \
  "$(config_get_backup_temp_directory)" == "vzdump-tmp" && \
  "$(config_get_backup_ct_storage)" == "SYNOLOGY" && \
  "$(config_get_backup_ct_schedule)" == "*-*-* 02:00:00" && \
  "$(config_get_backup_vm_storage)" == "SYNOLOGY" && \
  "$(config_get_backup_vm_schedule)" == "*-*-* 00:00:00" && \
  "$(config_get_backup_exclude_tags)" == '["no-backup"]' && \
  "$(backup_effective_exclude_tags)" == '["backup-restore-test","no-backup"]' ]]; then
  pass "typed backup accessors return policy values"
else
  fail "typed backup accessors return policy values"
fi

jq '.backup.temp.directory = "/vzdump-tmp"' "$CONFIG_FILE" >"${TEST_ROOT}/absolute-temp.json"
CONFIG_FILE="${TEST_ROOT}/absolute-temp.json"
assert_failure_contains "absolute TEMP directory is rejected" "backup.temp.directory must be a safe relative directory" validate_backup_config

jq '.backup.temp.directory = "../vzdump-tmp"' "${TEST_ROOT}/commonCT.json" >"${TEST_ROOT}/traversal-temp.json"
CONFIG_FILE="${TEST_ROOT}/traversal-temp.json"
assert_failure_contains "TEMP directory traversal is rejected" "backup.temp.directory must be a safe relative directory" validate_backup_config

jq '.backup.ct.storage = "bad storage"' "${TEST_ROOT}/commonCT.json" >"${TEST_ROOT}/invalid-storage.json"
CONFIG_FILE="${TEST_ROOT}/invalid-storage.json"
assert_failure_contains "invalid storage ID is rejected" "backup.ct.storage contains unsupported characters" validate_backup_config

jq '.backup.ct.schedule = ""' "${TEST_ROOT}/commonCT.json" >"${TEST_ROOT}/empty-schedule.json"
CONFIG_FILE="${TEST_ROOT}/empty-schedule.json"
assert_failure_contains "empty CT schedule is rejected" "backup.ct.schedule must be a non-empty string" validate_backup_config

jq '.backup.exclude = ["bad tag"]' "${TEST_ROOT}/commonCT.json" >"${TEST_ROOT}/invalid-exclude.json"
CONFIG_FILE="${TEST_ROOT}/invalid-exclude.json"
assert_failure_contains "invalid exclusion tag is rejected" "backup.exclude must be an array of valid tags" validate_backup_config

jq '.backup.legacy = true' "${TEST_ROOT}/commonCT.json" >"${TEST_ROOT}/extra-key.json"
CONFIG_FILE="${TEST_ROOT}/extra-key.json"
assert_failure_contains "legacy backup keys are rejected" "backup must contain exactly" validate_backup_config

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

jq '.backup.exclude = ["maintenance"]' "${TEST_ROOT}/commonCT.json" >"${TEST_ROOT}/custom-exclude.json"
CONFIG_FILE="${TEST_ROOT}/custom-exclude.json"
if [[ "$(backup_resource_ids qemu "$resources")" == "1000,1001" ]]; then
  pass "configured exclusion tags replace the default policy"
else
  fail "configured exclusion tags replace the default policy"
fi

echo "${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]