#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
PASS=0
FAIL=0

pass() { echo "ok - $1"; PASS=$((PASS + 1)); }
test_fail() { echo "not ok - $1" >&2; FAIL=$((FAIL + 1)); }

assert_failure_contains() {
  local name="$1" expected="$2"
  shift 2
  if "$@" >"${TEST_ROOT}/output" 2>&1; then
    test_fail "$name"
  elif grep -Fq "$expected" "${TEST_ROOT}/output"; then
    pass "$name"
  else
    cat "${TEST_ROOT}/output" >&2
    test_fail "$name"
  fi
}

run_hook_from_stdin() {
  bash -s <"${SCRIPT_DIR}/backup/pve-workload-backup-hook"
}

assert_failure_contains "stdin hook execution dispatches without BASH_SOURCE" "Missing hook phase" run_hook_from_stdin

export BACKUP_STATE_DIR="${TEST_ROOT}/state"
export BACKUP_MOUNT="${TEST_ROOT}/nfs"
export WORKLOAD_ROOT="${BACKUP_MOUNT}/workloads"
mkdir -p "$BACKUP_STATE_DIR" "${BACKUP_MOUNT}/dump" "$WORKLOAD_ROOT"
source "${SCRIPT_DIR}/backup/pve-workload-backup-hook"

if grep -Fq -- '--info=progress2' "${SCRIPT_DIR}/backup/pve-workload-backup-hook"; then
  test_fail "backup hook avoids unbounded progress output"
elif grep -Fq -- '--info=stats1' "${SCRIPT_DIR}/backup/pve-workload-backup-hook"; then
  pass "backup hook uses bounded transfer statistics"
else
  test_fail "backup hook retains bounded transfer statistics"
fi

stale_probe="${BACKUP_MOUNT}/.workload-backup-probe.100"
active_probe="${BACKUP_MOUNT}/.workload-backup-probe.200"
mkdir "$stale_probe" "$active_probe"
touch -d '2 hours ago' "$stale_probe"
cleanup_stale_probe_dirs "$BACKUP_MOUNT"
if [[ ! -e "$stale_probe" && -d "$active_probe" ]]; then
  pass "stale interrupted probes are removed without touching active probes"
else
  test_fail "stale interrupted probes are removed without touching active probes"
fi
rm -rf "$active_probe"

pct() { printf 'rootfs: DATA:subvol-3500-disk-0,size=32G\n'; }
findmnt() { printf '/dev/pve/temp\n'; }
blockdev() { printf '68719476736\n'; }
if validate_temp_capacity_for_ct 3500; then
  pass "TEMP capacity accepts an exact-size block device despite filesystem overhead"
else
  test_fail "TEMP capacity accepts an exact-size block device despite filesystem overhead"
fi
blockdev() { printf '67645734912\n'; }
assert_failure_contains "TEMP capacity rejects stale undersizing" "rerun backupCT.sh --provision-temp" validate_temp_capacity_for_ct 3500
unset -f pct findmnt blockdev

snapshot_one="${TEST_ROOT}/snapshots/one"
snapshot_two="${TEST_ROOT}/snapshots/two"
mkdir -p "$snapshot_one" "$snapshot_two"
printf 'stable\n' >"${snapshot_one}/stable.txt"
printf 'version-one\n' >"${snapshot_one}/changed.txt"
printf 'data-stable\n' >"${snapshot_two}/stable.txt"
chown 1234:2345 "${snapshot_one}/stable.txt"

write_ready_state() {
  local generation="$1"
  jq -nc --arg generation "$generation" --arg one "$snapshot_one" --arg two "$snapshot_two" \
    '{ctid:"2100",hostname:"app.thesaints.home",generation:$generation,phase:"ready",snapshots:[{name:("pool/one@"+$generation),path:$one},{name:("pool/two@"+$generation),path:$two}]}' \
    >"$(state_file 2100)"
}

archive_one="${BACKUP_MOUNT}/dump/vzdump-lxc-2100-2026_08_27-02_00_00.tar.zst"
touch "$archive_one"
write_ready_state first
if mirror_generation 2100 "$archive_one"; then
  pass "first backup creates a full workload generation"
else
  test_fail "first backup creates a full workload generation"
fi
generation_one="${WORKLOAD_ROOT}/app.thesaints.home/vzdump-lxc-2100-2026_08_27-02_00_00"
[[ "$(cat "${generation_one}/docker/changed.txt")" == version-one ]] && pass "first generation contains source data" || test_fail "first generation contains source data"
ownership_restore="${TEST_ROOT}/ownership-restore"
mkdir "$ownership_restore"
rsync -a --numeric-ids "${generation_one}/docker/" "$ownership_restore/"
[[ "$(stat -c '%u:%g' "${ownership_restore}/stable.txt")" == "1234:2345" ]] && pass "generation restores numeric ownership" || test_fail "generation restores numeric ownership"

printf 'version-two\n' >"${snapshot_one}/changed.txt"
printf 'new\n' >"${snapshot_two}/new.txt"
archive_two="${BACKUP_MOUNT}/dump/vzdump-lxc-2100-2026_08_28-02_00_00.tar.zst"
touch "$archive_two"
write_ready_state second
if mirror_generation 2100 "$archive_two"; then
  pass "second backup creates a link-dest generation"
else
  test_fail "second backup creates a link-dest generation"
fi
generation_two="${WORKLOAD_ROOT}/app.thesaints.home/vzdump-lxc-2100-2026_08_28-02_00_00"
if [[ "$(stat -c '%d:%i' "${generation_one}/docker/stable.txt")" == "$(stat -c '%d:%i' "${generation_two}/docker/stable.txt")" ]]; then
  pass "unchanged files are hard-linked to the immutable basis"
else
  test_fail "unchanged files are hard-linked to the immutable basis"
fi
[[ "$(cat "${generation_one}/docker/changed.txt")" == version-one ]] && pass "changed files do not mutate retained generations" || test_fail "changed files do not mutate retained generations"
[[ "$(cat "${generation_two}/docker/changed.txt")" == version-two ]] && pass "changed files are copied into the new generation" || test_fail "changed files are copied into the new generation"

bad_archive="${BACKUP_MOUNT}/dump/vzdump-lxc-2100-test.tar.gz"
touch "$bad_archive"
write_ready_state bad
assert_failure_contains "non-zstd archive names are rejected" "Unexpected CT archive name" mirror_generation 2100 "$bad_archive"

orphan="${WORKLOAD_ROOT}/app.thesaints.home/vzdump-lxc-2100-2026_01_01-02_00_00"
mkdir -p "${orphan}/docker" "${orphan}/docker-data"
prune_orphan_generations
[[ ! -e "$orphan" ]] && pass "orphan workload generations are pruned" || test_fail "orphan workload generations are pruned"
[[ -d "$generation_one" && -d "$generation_two" ]] && pass "archive-backed generations remain protected" || test_fail "archive-backed generations remain protected"

snapshot_mount_one="${TEST_ROOT}/pool-one"
snapshot_mount_two="${TEST_ROOT}/pool-two"
mkdir -p "${snapshot_mount_one}/.zfs/snapshot/snap-success/app.thesaints.home"
mkdir -p "${snapshot_mount_two}/.zfs/snapshot/snap-success/app.thesaints.home"
snapshot_source_info() {
  case "$1" in
    /mnt/docker/app.thesaints.home) printf 'pool/one\t%s\tapp.thesaints.home\n' "$snapshot_mount_one" ;;
    /mnt/docker-data/app.thesaints.home) printf 'pool/two\t%s\tapp.thesaints.home\n' "$snapshot_mount_two" ;;
    *) return 1 ;;
  esac
}
zfs_log="${TEST_ROOT}/zfs.log"
zfs() {
  case "$1" in
    snapshot)
      printf 'snapshot %s\n' "$2" >>"$zfs_log"
      [[ "${FAIL_ZFS_SNAPSHOT:-}" != "$2" ]]
      ;;
    list) return 0 ;;
    destroy) printf 'destroy %s\n' "$2" >>"$zfs_log" ;;
    *) return 1 ;;
  esac
}
write_state 2100 "$(jq -nc '{ctid:"2100",hostname:"app.thesaints.home",generation:"snap-success",docker_source:"/mnt/docker/app.thesaints.home",data_source:"/mnt/docker-data/app.thesaints.home",phase:"prepared",snapshots:[]}')"
if create_snapshots 2100 && [[ "$(jq -r '.phase' "$(state_file 2100)")" == snapshotted && "$(jq '.snapshots | length' "$(state_file 2100)")" == 2 ]]; then
  pass "pre-restart records both ZFS snapshots"
else
  test_fail "pre-restart records both ZFS snapshots"
fi

rm -f "$zfs_log"
mkdir -p "${snapshot_mount_one}/.zfs/snapshot/snap-rollback/app.thesaints.home"
mkdir -p "${snapshot_mount_two}/.zfs/snapshot/snap-rollback/app.thesaints.home"
write_state 2100 "$(jq -nc '{ctid:"2100",hostname:"app.thesaints.home",generation:"snap-rollback",docker_source:"/mnt/docker/app.thesaints.home",data_source:"/mnt/docker-data/app.thesaints.home",phase:"prepared",snapshots:[]}')"
export FAIL_ZFS_SNAPSHOT="pool/two@snap-rollback"
assert_failure_contains "second snapshot failure aborts pre-restart" "Failed to create pool/two@snap-rollback" create_snapshots 2100
unset FAIL_ZFS_SNAPSHOT
if grep -Fq 'destroy pool/one@snap-rollback' "$zfs_log"; then
  pass "second snapshot failure rolls back the first snapshot"
else
  test_fail "second snapshot failure rolls back the first snapshot"
fi
if ! grep -Fq 'pct start' "$zfs_log"; then
  pass "snapshot failure leaves CT thaw handling to vzdump"
else
  test_fail "snapshot failure leaves CT thaw handling to vzdump"
fi

source "${SCRIPT_DIR}/backupCT.sh"
CT_LIST=(100 2700)
CT_MAP[100]=ca.thesaints.home
CT_MAP[2700]=ca.thesaints.home
if resolve_ct_from_input ca.thesaints.home >"${TEST_ROOT}/duplicate-hostname" 2>&1; then
  test_fail "duplicate CT hostnames require a numeric CTID"
elif grep -Fq 'matches multiple CTs: 100 2700. Use a numeric CTID.' "${TEST_ROOT}/duplicate-hostname"; then
  pass "duplicate CT hostnames require a numeric CTID"
else
  test_fail "duplicate CT hostnames require a numeric CTID"
fi
if resolve_ct_from_input 2700 && [[ "$CTID" == 2700 ]]; then
  pass "numeric CTID remains unambiguous"
else
  test_fail "numeric CTID remains unambiguous"
fi
CT_TAGS[100]='backup-restore-test;temporary'
CT_TAGS[2700]='production'
if ct_has_tag 100 backup-restore-test && ! ct_has_tag 2700 backup-restore-test; then
  pass "restore-test tags are matched exactly"
else
  test_fail "restore-test tags are matched exactly"
fi

restore_resources='[
  {"type":"lxc","vmid":2100,"name":"app.thesaints.home"},
  {"type":"qemu","vmid":2200,"name":"vm.thesaints.home"}
]'
pvesh() {
  [[ "$*" == "get /cluster/nextid" ]] || return 1
  printf '2300\n'
}
RESTORE_ID=""
if resolve_restore_id "$restore_resources" >"${TEST_ROOT}/restore-id-output" \
  && [[ "$RESTORE_ID" == 2300 ]] \
  && grep -Fq 'Automatically selected restore CTID 2300.' "${TEST_ROOT}/restore-id-output"; then
  pass "restore test automatically selects the next cluster ID"
else
  test_fail "restore test automatically selects the next cluster ID"
fi
pvesh() { return 1; }
RESTORE_ID=2400
if resolve_restore_id "$restore_resources" && [[ "$RESTORE_ID" == 2400 ]]; then
  pass "explicit restore ID bypasses automatic allocation"
else
  test_fail "explicit restore ID bypasses automatic allocation"
fi
RESTORE_ID=2100
assert_failure_contains "occupied restore ID is rejected" "already exists" resolve_restore_id "$restore_resources"

temp_resources='[
  {"type":"lxc","vmid":2000,"maxdisk":17179869184},
  {"type":"lxc","vmid":3500,"maxdisk":34359738368},
  {"type":"lxc","vmid":92200,"maxdisk":137438953472,"tags":"backup-restore-test"},
  {"type":"qemu","vmid":1000,"maxdisk":274877906944}
]'
if [[ "$(calculate_temp_size_gib "$temp_resources")" == "64" ]]; then
  pass "TEMP size is twice the largest production CT rootfs"
else
  test_fail "TEMP size is twice the largest production CT rootfs"
fi
prerequisite_log="${TEST_ROOT}/prerequisites.log"
ssh_argument_log="${TEST_ROOT}/ssh-arguments.log"
hostname() { echo pve01; }
ssh() { printf '<%s>\n' "$@" >"$ssh_argument_log"; }
run_on_node pve02 sh -c "command -v 'jq' >/dev/null 2>&1"
if [[ "$(tail -n 1 "$ssh_argument_log")" == "<sh -c command\\ -v\\ \\'jq\\'\\ \\>/dev/null\\ 2\\>\\&1>" ]]; then
  pass "remote executor sends one shell-safe command to SSH"
else
  cat "$ssh_argument_log" >&2
  test_fail "remote executor sends one shell-safe command to SSH"
fi
unset -f ssh hostname
online_nodes() { printf 'pve01\npve02\n'; }
run_on_node() {
  local node="$1"
  shift
  printf '%s: %s\n' "$node" "$*" >>"$prerequisite_log"
  if [[ "$*" == "findmnt -rn -o SOURCE,FSTYPE --target /TEMP" ]]; then
    printf '/dev/pve/temp ext4\n'
  elif [[ "$node" == pve02 && "$*" == *"command -v 'jq'"* && "$*" != *apt-get* ]]; then
    [[ -f "${TEST_ROOT}/jq-installed" ]]
  else
    if [[ "$node" == pve02 && "$*" == *"apt-get install"* ]]; then
      touch "${TEST_ROOT}/jq-installed"
    fi
    return 0
  fi
}
DRY_RUN=false
if install_prerequisites_cluster; then
  pass "host prerequisites reconcile across all online nodes"
else
  test_fail "host prerequisites reconcile across all online nodes"
fi
if grep -Fq 'pve02: env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq jq' "$prerequisite_log"; then
  pass "missing jq is installed noninteractively on its node"
else
  test_fail "missing jq is installed noninteractively on its node"
fi
if ! grep -Fq 'pve01: env DEBIAN_FRONTEND=noninteractive apt-get install' "$prerequisite_log"; then
  pass "nodes with prerequisites are not mutated"
else
  test_fail "nodes with prerequisites are not mutated"
fi
>"$prerequisite_log"
prepare_backup_tmpdir_cluster
if grep -Fq 'test -d /TEMP' "$prerequisite_log" && \
  grep -Fq 'install -d -o root -g root -m 1777 /TEMP/vzdump-tmp' "$prerequisite_log" && \
  grep -Fq 'chmod 1777 /TEMP/vzdump-tmp' "$prerequisite_log"; then
  pass "vzdump staging requires TEMP and is traversable by mapped LXC root"
else
  test_fail "vzdump staging requires TEMP and is traversable by mapped LXC root"
fi
if ! grep -E 'ssh .*sha256sum' "${SCRIPT_DIR}/backupCT.sh" | grep -Fq '$1'; then
  pass "remote checksum commands do not expand positional parameters locally"
else
  test_fail "remote checksum commands do not expand positional parameters locally"
fi
if grep -Fq -- '--tmpdir "$tmpdir"' "${SCRIPT_DIR}/backupCT.sh"; then
  pass "manual and scheduled backups use node-local vzdump staging"
else
  test_fail "manual and scheduled backups use node-local vzdump staging"
fi

remote_backup_log="${TEST_ROOT}/remote-backup.log"
remote_resources='[{"type":"lxc","vmid":2100,"name":"app.thesaints.home","node":"pve02"}]'
config_get_backup_storage() { echo backup-nfs; }
config_get_backup_hook_path() { echo /usr/local/lib/pve-backup/pve-workload-backup-hook; }
config_get_backup_tmpdir() { echo /TEMP/vzdump-tmp; }
config_get_backup_mode() { echo suspend; }
config_get_backup_compress() { echo zstd; }
config_get_backup_bwlimit_kib() { echo 0; }
config_get_backup_ionice() { echo 7; }
verify_hook_cluster() { :; }
pvesh() {
  [[ "$*" == "get /cluster/resources --type vm --output-format json" ]] || return 1
  printf '%s\n' "$remote_resources"
}
run_on_node() {
  local node="$1"
  shift
  printf '%s|%s\n' "$node" "$*" >>"$remote_backup_log"
}
DRY_RUN=false
if run_backup app.thesaints.home \
  && grep -Fq 'pve02|install -d -o root -g root -m 1777 /TEMP/vzdump-tmp' "$remote_backup_log" \
  && grep -Fq 'pve02|vzdump 2100 --storage backup-nfs --tmpdir /TEMP/vzdump-tmp --mode suspend --compress zstd --script /usr/local/lib/pve-backup/pve-workload-backup-hook --ionice 7' "$remote_backup_log" \
  && ! grep -Fq 'pve01|' "$remote_backup_log"; then
  pass "manual backup dispatches node-local staging and vzdump to the CT owner"
else
  cat "$remote_backup_log" >&2
  test_fail "manual backup dispatches node-local staging and vzdump to the CT owner"
fi

remote_restore_log="${TEST_ROOT}/remote-restore.log"
restore_archive="${BACKUP_MOUNT}/dump/vzdump-lxc-2100-2026_08_28-02_00_00.tar.zst"
restore_generation="${WORKLOAD_ROOT}/app.thesaints.home/vzdump-lxc-2100-2026_08_28-02_00_00"
mkdir -p "${restore_generation}/docker" "${restore_generation}/docker-data"
touch "$restore_archive"
config_get_backup_storage() { printf '../../%s\n' "${BACKUP_MOUNT#/}"; }
online_nodes() { printf 'pve01\npve02\n'; }
bridge_policy_resolve() {
  BRIDGE_POLICY_SELECTED=vmbr0
  BRIDGE_POLICY_REASON="test fixture"
}
run_node_shell() {
  printf '%s|%s\n' "$1" "$2" >>"$remote_restore_log"
}
RESTORE_ID=92200
RESTORE_NODE=""
DRY_RUN=true
if restore_test app.thesaints.home >"${TEST_ROOT}/remote-restore-output" \
  && grep -Fq 'pve02|test ! -e ' "$remote_restore_log" \
  && grep -Fq 'Target: CT 92200 on pve02' "${TEST_ROOT}/remote-restore-output" \
  && ! grep -Fq 'pve01|' "$remote_restore_log"; then
  pass "restore test defaults staging and restore planning to the source CT owner"
else
  cat "$remote_restore_log" >&2
  cat "${TEST_ROOT}/remote-restore-output" >&2
  test_fail "restore test defaults staging and restore planning to the source CT owner"
fi

pct() {
  case "$2" in
    92200) printf 'hostname: nodered.thesaints.home\ntags: backup-restore-test\n' ;;
    2200) printf 'hostname: nodered.thesaints.home\n' ;;
    *) return 1 ;;
  esac
}
if is_restore_test_ct 92200 && ! is_restore_test_ct 2200; then
  pass "restore-test tag distinguishes isolated CTs"
else
  test_fail "restore-test tag distinguishes isolated CTs"
fi
pvesh() {
  jq -nc '[
    {type:"lxc",vmid:2200,name:"nodered.thesaints.home"},
    {type:"lxc",vmid:2201,name:"excluded.thesaints.home",tags:"no-backup"},
    {type:"lxc",vmid:92200,name:"nodered.thesaints.home",tags:"backup-restore-test"}
  ]'
}
[[ "$(cluster_lxc_ids)" == 2200 ]] && pass "scheduled VMIDs honor CT exclusion tags" || test_fail "scheduled VMIDs honor CT exclusion tags"
if grep -Fq 'pct set "$RESTORE_ID" -tags backup-restore-test -onboot 0' "${SCRIPT_DIR}/backupCT.sh"; then
  pass "restore tests receive the exclusion tag and stay disabled at boot"
else
  test_fail "restore tests receive the exclusion tag and stay disabled at boot"
fi

health_resources='[{"type":"lxc","vmid":2100,"name":"app.thesaints.home","node":"pve01"}]'
health_archive="${BACKUP_MOUNT}/dump/vzdump-lxc-2100-2026_08_28-02_00_00.tar.zst"
health_generation="${WORKLOAD_ROOT}/app.thesaints.home/vzdump-lxc-2100-2026_08_28-02_00_00"
mkdir -p "${health_generation}/docker" "${health_generation}/docker-data"
touch -d '2 hours ago' "$health_archive"
HEALTH_LOCK=backup
HEALTH_TASKS='[]'
pvesh() {
  case "$*" in
    "get /nodes/pve01/lxc/2100/config --output-format json") jq -nc --arg lock "$HEALTH_LOCK" '{lock:$lock}' ;;
    "get /nodes/pve01/tasks --source active --typefilter vzdump --output-format json") printf '%s\n' "$HEALTH_TASKS" ;;
    *) return 1 ;;
  esac
}
BACKUP_MAX_AGE_SECONDS=3600
assert_failure_contains "idle old backup lock is reported stale" "STALE LOCK CT 2100" check_stale_backup_locks "$health_resources" "$BACKUP_MOUNT"
HEALTH_TASKS='[{"type":"vzdump"}]'
if check_stale_backup_locks "$health_resources" "$BACKUP_MOUNT" >"${TEST_ROOT}/active-lock" 2>&1 && grep -Fq "ACTIVE LOCK CT 2100" "${TEST_ROOT}/active-lock"; then
  pass "active backup lock is not classified stale"
else
  test_fail "active backup lock is not classified stale"
fi
HEALTH_TASKS='[]'
touch "$health_archive"
if check_stale_backup_locks "$health_resources" "$BACKUP_MOUNT" >"${TEST_ROOT}/recent-lock" 2>&1 && grep -Fq "RECENT LOCK CT 2100" "${TEST_ROOT}/recent-lock"; then
  pass "recent idle backup lock receives a grace period"
else
  test_fail "recent idle backup lock receives a grace period"
fi
HEALTH_LOCK=migrate
if check_stale_backup_locks "$health_resources" "$BACKUP_MOUNT" >"${TEST_ROOT}/other-lock" 2>&1 && [[ ! -s "${TEST_ROOT}/other-lock" ]]; then
  pass "non-backup CT locks are ignored"
else
  test_fail "non-backup CT locks are ignored"
fi
if grep -Eq '^[[:space:]]*pct[[:space:]]+unlock|pvesh[[:space:]]+(set|create|delete)' "${SCRIPT_DIR}/backup/lib-backup-health.sh"; then
  test_fail "backup lock health check is read-only"
else
  pass "backup lock health check is read-only"
fi
if declare -f audit_cluster | grep -Fq 'verify_hook_cluster'; then
  pass "CT audit checks deployed hook drift"
else
  test_fail "CT audit checks deployed hook drift"
fi
if declare -f run_backup | grep -Fq 'verify_hook_cluster'; then
  pass "manual CT backup checks deployed hook drift"
else
  test_fail "manual CT backup checks deployed hook drift"
fi
if grep -Fq -- '--verify) verify_hook_cluster && check_cluster_backup_locks && verify_pairs' "${SCRIPT_DIR}/backupCT.sh"; then
  pass "CT pair verification checks hook drift and locks"
else
  test_fail "CT pair verification checks hook drift and locks"
fi

echo "${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]