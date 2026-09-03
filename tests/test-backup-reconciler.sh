#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
PASS=0
FAIL=0

pass() { echo "ok - $1"; PASS=$((PASS + 1)); }
fail() { echo "not ok - $1" >&2; FAIL=$((FAIL + 1)); }
assert_contains() {
  local name="$1" expected="$2"
  if grep -Fq -- "$expected" "$TEST_ROOT/calls"; then pass "$name"; else cat "$TEST_ROOT/calls" >&2; fail "$name"; fi
}
assert_not_contains() {
  local name="$1" unexpected="$2"
  if ! grep -Fq -- "$unexpected" "$TEST_ROOT/calls"; then pass "$name"; else cat "$TEST_ROOT/calls" >&2; fail "$name"; fi
}

export BACKUP_POLICY_FILE="${TEST_ROOT}/policy"
cat >"$BACKUP_POLICY_FILE" <<'EOF'
BACKUP_CT_JOB_ID=ct-backup
BACKUP_VM_JOB_ID=vm-backup
BACKUP_VM_ENABLED=true
BACKUP_EXCLUDE_TAGS=no-backup,backup-restore-test
BACKUP_PRUNE_POLICY=keep-daily=7,keep-weekly=4,keep-monthly=6
EOF
source "${SCRIPT_DIR}/backup/reconcile-backup-jobs"

TEST_RESOURCES='[
  {"type":"lxc","vmid":200,"tags":"production"},
  {"type":"lxc","vmid":201,"tags":"no-backup;production"},
  {"type":"qemu","vmid":100},
  {"type":"qemu","vmid":101,"tags":"backup-restore-test"}
]'
TEST_NODE=pve01
CT_JOB='{"enabled":1,"vmid":"999","prune-backups":{"keep-daily":"7","keep-weekly":"4","keep-monthly":"6"}}'
VM_JOB='{"enabled":1,"vmid":"100","prune-backups":{"keep-daily":"7","keep-weekly":"4","keep-monthly":"6"}}'
hostname() { printf '%s\n' "$TEST_NODE"; }
pvesh() {
  printf '%s\n' "$*" >>"$TEST_ROOT/calls"
  case "$*" in
    "get /nodes --output-format json") jq -nc '[{node:"pve02",status:"online"},{node:"pve01",status:"online"}]' ;;
    "get /cluster/resources --type vm --output-format json") printf '%s\n' "$TEST_RESOURCES" ;;
    "get /cluster/backup/ct-backup --output-format json") printf '%s\n' "$CT_JOB" ;;
    "get /cluster/backup/vm-backup --output-format json") printf '%s\n' "$VM_JOB" ;;
    set*) return 0 ;;
    *) return 1 ;;
  esac
}

: >"$TEST_ROOT/calls"
main >/dev/null
assert_contains "leader reconciles exact CT membership" "set /cluster/backup/ct-backup --vmid 200 --enabled 1 --prune-backups keep-daily=7,keep-weekly=4,keep-monthly=6"
assert_not_contains "current VM membership is not rewritten" "set /cluster/backup/vm-backup"

: >"$TEST_ROOT/calls"
TEST_RESOURCES='[{"type":"lxc","vmid":200},{"type":"qemu","vmid":101,"tags":"no-backup"}]'
VM_JOB='{"enabled":1,"vmid":"100"}'
main >/dev/null
assert_contains "empty eligible VM set disables its job" "set /cluster/backup/vm-backup --enabled 0 --prune-backups keep-daily=7,keep-weekly=4,keep-monthly=6"
assert_not_contains "empty eligible VM set does not retain a stale VMID" "set /cluster/backup/vm-backup --vmid"

: >"$TEST_ROOT/calls"
TEST_RESOURCES='[{"type":"lxc","vmid":200},{"type":"qemu","vmid":100}]'
CT_JOB='{"enabled":1,"vmid":"200","prune-backups":{"keep-last":"1"}}'
VM_JOB='{"enabled":1,"vmid":"100","prune-backups":{"keep-daily":"7","keep-weekly":"4","keep-monthly":"6"}}'
main >/dev/null
assert_contains "retention drift is reconciled on CT job" "set /cluster/backup/ct-backup --vmid 200 --enabled 1 --prune-backups keep-daily=7,keep-weekly=4,keep-monthly=6"

: >"$TEST_ROOT/calls"
TEST_NODE=pve02
main >/dev/null
assert_not_contains "non-leader does not read cluster resources" "get /cluster/resources"
assert_not_contains "non-leader does not mutate backup jobs" "set /cluster/backup"

echo "${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
