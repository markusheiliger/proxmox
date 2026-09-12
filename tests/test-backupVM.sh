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
  local name="$1" file="$2" expected="$3"
  if grep -Fq -- "$expected" "$file"; then pass "$name"; else cat "$file" >&2; fail "$name"; fi
}
assert_not_contains() {
  local name="$1" file="$2" unexpected="$3"
  if ! grep -Fq -- "$unexpected" "$file"; then pass "$name"; else cat "$file" >&2; fail "$name"; fi
}

export CONFIG_FILE="${TEST_ROOT}/commonCT.json"
export BACKUP_MOUNT_ROOT="${TEST_ROOT}/mnt"
cp "${SCRIPT_DIR}/commonCT.json" "$CONFIG_FILE"
source "${SCRIPT_DIR}/backupVM.sh"

TEST_RESOURCES='[
  {"type":"lxc","vmid":2200,"name":"app.thesaints.home","node":"pve01"},
  {"type":"qemu","vmid":1000,"name":"vm.thesaints.home","node":"pve01"},
  {"type":"qemu","vmid":1001,"name":"excluded.thesaints.home","node":"pve01","tags":"no-backup"},
  {"type":"qemu","vmid":91000,"name":"restore.thesaints.home","node":"pve01","tags":"backup-restore-test"}
]'
STORAGE_ACTIVE_PVE01=1
STORAGE_ACTIVE_PVE02=1

pvesh() {
  case "$*" in
    "get /cluster/resources --type vm --output-format json") printf '%s\n' "$TEST_RESOURCES" ;;
    "get /nodes --output-format json") jq -nc '[{node:"pve01",status:"online"},{node:"pve02",status:"online"}]' ;;
    "get /nodes/pve01/storage/SYNOLOGY/status --output-format json") jq -nc --argjson active "$STORAGE_ACTIVE_PVE01" '{active:$active}' ;;
    "get /nodes/pve02/storage/SYNOLOGY/status --output-format json") jq -nc --argjson active "$STORAGE_ACTIVE_PVE02" '{active:$active}' ;;
    "get /cluster/backup/vm-backup") return 1 ;;
    *) printf 'pvesh %s\n' "$*" >>"${TEST_ROOT}/mutations" ;;
  esac
}

[[ "$(cluster_vm_ids)" == 1000 ]] && pass "VM selector includes only eligible QEMU guests" || fail "VM selector includes only eligible QEMU guests"

DRY_RUN=true
: >"${TEST_ROOT}/mutations"
configure_job >"${TEST_ROOT}/configure-output"
assert_contains "VM job uses snapshot mode" "${TEST_ROOT}/configure-output" "--mode snapshot"
assert_contains "VM job uses the midnight schedule" "${TEST_ROOT}/configure-output" "00:00:00"
assert_contains "VM job contains eligible VMID" "${TEST_ROOT}/configure-output" "--vmid 1000"
assert_not_contains "VM job inherits storage retention" "${TEST_ROOT}/configure-output" "--prune-backups"
assert_not_contains "VM job has no workload hook" "${TEST_ROOT}/configure-output" "--script"
assert_not_contains "VM job has no TEMP staging" "${TEST_ROOT}/configure-output" "--tmpdir"

run_backup all >"${TEST_ROOT}/run-output"
assert_contains "VM dry-run builds native vzdump command" "${TEST_ROOT}/run-output" "vzdump 1000"
assert_contains "VM dry-run keeps snapshot mode" "${TEST_ROOT}/run-output" "--mode snapshot"
assert_not_contains "VM run has no workload hook" "${TEST_ROOT}/run-output" "--script"
assert_not_contains "VM dry-run performs no mutation" "${TEST_ROOT}/mutations" "pvesh"

STORAGE_ACTIVE_PVE02=0
if verify_backup_storage_nodes 2>"${TEST_ROOT}/storage-error"; then
  fail "inactive backup storage rejects VM operations"
else
  pass "inactive backup storage rejects VM operations"
fi
assert_contains "inactive storage error identifies its node" "${TEST_ROOT}/storage-error" "Backup storage SYNOLOGY is not active on pve02"
STORAGE_ACTIVE_PVE02=1

mkdir -p "${BACKUP_MOUNT_ROOT}/SYNOLOGY/dump"
archive="${BACKUP_MOUNT_ROOT}/SYNOLOGY/dump/vzdump-qemu-1000-2026_08_27-00_00_00.vma.zst"
touch "$archive"
verify_archives >"${TEST_ROOT}/verify-output"
assert_contains "VM verification accepts a fresh VMA archive" "${TEST_ROOT}/verify-output" "OK VM 1000"

RESTORE_ID=92000
RESTORE_NODE=""
restore_test 1000 >"${TEST_ROOT}/restore-output"
assert_contains "VM restore dry-run reports unique isolation" "${TEST_ROOT}/restore-output" "unique identity, all NICs link down"
assert_contains "VM restore dry-run performs no restore" "${TEST_ROOT}/restore-output" "[dry-run] Would restore"

DRY_RUN=false
: >"${TEST_ROOT}/nic-mutations"
run_on_node() {
  local node="$1"
  shift
  if [[ "$1 $2" == "qm config" ]]; then
    cat <<'EOF'
net0: virtio=AA:BB:CC:DD:EE:01,bridge=vmbr1
net1: e1000=AA:BB:CC:DD:EE:02,bridge=vmbr2,link_down=0,firewall=1
EOF
  else
    printf '%s\n' "$*" >>"${TEST_ROOT}/nic-mutations"
  fi
}
isolate_vm_nics pve01 92000 vmbr7
assert_contains "first restored NIC uses policy bridge and is disabled" "${TEST_ROOT}/nic-mutations" "--net0 virtio=AA:BB:CC:DD:EE:01,bridge=vmbr7,link_down=1"
assert_contains "existing link state is replaced in place" "${TEST_ROOT}/nic-mutations" "--net1 e1000=AA:BB:CC:DD:EE:02,bridge=vmbr7,link_down=1,firewall=1"
assert_not_contains "restored NIC has no duplicate link state" "${TEST_ROOT}/nic-mutations" "link_down=0"

echo "${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
