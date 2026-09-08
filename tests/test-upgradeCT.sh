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
  if grep -Fq "$expected" "$file"; then pass "$name"; else cat "$file" >&2; fail "$name"; fi
}

assert_empty() {
  local name="$1" file="$2"
  if [[ ! -s "$file" ]]; then pass "$name"; else cat "$file" >&2; fail "$name"; fi
}

source "${SCRIPT_DIR}/upgradeCT.sh"

bridge_policy_resolve() {
  BRIDGE_POLICY_SELECTED=vmbr1
  BRIDGE_POLICY_REASON="test policy"
  BRIDGE_POLICY_RANK=3
}
bridge_policy_reconcile_guest() { return 0; }

path=$(build_release_path 3.19 3.24 | paste -sd,)
if [[ "$path" == "3.20,3.21,3.22,3.23,3.24" ]]; then
  pass "release path includes every intermediate Alpine release"
else
  fail "release path includes every intermediate Alpine release"
fi

CTID=2200
health_mode=""
check_ct_storage_health() {
  health_mode="$2"
  echo "  [!] CT $1: storage health warning: ZFS pool 'DATA' health is DEGRADED" >&2
  return 0
}
if warn_storage_health 2> "${TEST_ROOT}/storage-warning" && [[ "$health_mode" == "warn" ]]; then
  pass "degraded storage is warning-only"
else
  fail "degraded storage is warning-only"
fi
assert_contains "degraded storage warning remains visible" "${TEST_ROOT}/storage-warning" "storage health warning"

remote_release_log="${TEST_ROOT}/remote-release.log"
run_remote_release_test() (
  get_ct_owner_node() { echo pve02; }
  get_ct_status() { echo stopped; }
  pct_config() { echo "rootfs: DATA:subvol-2200-disk-0,size=20G"; }
  run_on_node() {
    local node="$1"
    shift
    printf '%s|%s\n' "$node" "$*" >>"$remote_release_log"
    if [[ "$1" == pvesm ]]; then
      echo /DATA/subvol-2200-disk-0
    elif [[ "$1" == cut ]]; then
      echo 3.23
    fi
  }
  [[ "$(read_ct_release)" == 3.23 ]] \
    && grep -Fq 'pve02|pvesm path DATA:subvol-2200-disk-0' "$remote_release_log" \
    && grep -Fq 'pve02|cut -d. -f1,2 /DATA/subvol-2200-disk-0/etc/alpine-release' "$remote_release_log" \
    && ! grep -Fq 'pve01|' "$remote_release_log"
)
if run_remote_release_test; then
  pass "stopped CT release detection reads rootfs state on the owner node"
else
  cat "$remote_release_log" >&2
  fail "stopped CT release detection reads rootfs state on the owner node"
fi

SNAPSHOT_NAME="pre-alpine-test"
SNAPSHOT_CREATED=false
SNAPSHOT_METHOD=""
ZFS_SNAPSHOT=""
: > "${TEST_ROOT}/zfs-mutations"
pct() { echo "rootfs: DATA:subvol-2200-disk-0,size=20G"; }
pvesm() { echo "/DATA/subvol-2200-disk-0"; }
zfs() {
  case "$1" in
    list) echo "DATA/subvol-2200-disk-0" ;;
    snapshot) echo "$2" >> "${TEST_ROOT}/zfs-mutations" ;;
  esac
}
if create_rollback_point && [[ "$SNAPSHOT_METHOD" == "zfs" && "$SNAPSHOT_CREATED" == "true" ]]; then
  pass "ZFS rootfs uses a direct rollback snapshot"
else
  fail "ZFS rootfs uses a direct rollback snapshot"
fi
assert_contains "ZFS rollback snapshot targets rootfs dataset" "${TEST_ROOT}/zfs-mutations" "DATA/subvol-2200-disk-0@pre-alpine-test"

: > "${TEST_ROOT}/buildkit-mutations"
ct_exec() {
  local command="${*: -1}"
  if [[ "$command" == *'grep -q "fatal error: fault"'* \
    && "$command" == *'grep -q "builder/builder-next"'* \
    && "$command" == *'grep -q "go.etcd.io/bbolt"'* ]]; then
    return 0
  fi
  printf '%s\n' "$command" >> "${TEST_ROOT}/buildkit-mutations"
}
if repair_buildkit_metadata 3.20 > "${TEST_ROOT}/buildkit-output"; then
  pass "exact BuildKit bbolt crash triggers metadata recovery"
else
  fail "exact BuildKit bbolt crash triggers metadata recovery"
fi
assert_contains "BuildKit metadata is archived rather than deleted" "${TEST_ROOT}/buildkit-mutations" "mv /var/lib/docker/buildkit '/var/lib/docker/buildkit.pre-alpine-3-20-"
assert_contains "Docker restarts after BuildKit recovery" "${TEST_ROOT}/buildkit-mutations" "rc-service docker start"

: > "${TEST_ROOT}/unrelated-mutations"
ct_exec() { return 1; }
if repair_buildkit_metadata 3.20 > "${TEST_ROOT}/unrelated-output"; then
  fail "unrelated Docker failure is not modified"
else
  pass "unrelated Docker failure is not modified"
fi
assert_empty "unrelated Docker failure performs no repair mutation" "${TEST_ROOT}/unrelated-mutations"

: > "${TEST_ROOT}/state-mutations"
if (
  set +e
  COMMITTED=false
  SNAPSHOT_CREATED=false
  ORIGINAL_STATUS=running
  capture_failure_diagnostics() { DIAGNOSTIC_LOG="${TEST_ROOT}/failure.log"; }
  get_ct_status() { echo stopped; }
  pct() { echo "$*" >> "${TEST_ROOT}/state-mutations"; }
  false
  rollback
); then
  fail "failed rollback-point creation preserves failure status"
else
  pass "failed rollback-point creation preserves failure status"
fi
assert_contains "failed rollback-point creation restores running CT" "${TEST_ROOT}/state-mutations" "start 2200"

mkdir -p "${TEST_ROOT}/rootfs/etc"
echo "3.19.9" > "${TEST_ROOT}/rootfs/etc/alpine-release"
: > "${TEST_ROOT}/mutations"

run_dry_run() {
  (
    build_ct_list() { CT_LIST=(2200); CT_MAP[2200]="nodered.thesaints.home"; }
    resolve_ct_from_input() { CTID=2200; CT_HOSTNAME="nodered.thesaints.home"; }
    get_ct_status() { echo stopped; }
    pct() {
      if [[ "$1" == "config" ]]; then
        echo "rootfs: DATA:subvol-2200-disk-0,size=8G"
      else
        echo "pct $*" >> "${TEST_ROOT}/mutations"
      fi
    }
    pvesm() { echo "${TEST_ROOT}/rootfs"; }
    main 2200 --target 3.24 --dry-run
  ) > "${TEST_ROOT}/dry-run-output" 2>&1
}

run_dry_run
assert_contains "dry-run reports CT and target" "${TEST_ROOT}/dry-run-output" "CT 2200 (nodered.thesaints.home): Alpine 3.19 -> 3.24"
assert_contains "dry-run reports complete release path" "${TEST_ROOT}/dry-run-output" "Release path: 3.20 3.21 3.22 3.23 3.24"
assert_contains "dry-run reports no changes" "${TEST_ROOT}/dry-run-output" "[dry-run] No changes made."
assert_empty "stopped CT dry-run performs no pct mutation" "${TEST_ROOT}/mutations"

run_dry_run_downgrade() {
  (
    build_ct_list() { CT_LIST=(2200); CT_MAP[2200]="nodered.thesaints.home"; }
    resolve_ct_from_input() { CTID=2200; CT_HOSTNAME="nodered.thesaints.home"; }
    get_ct_status() { echo stopped; }
    pct() { echo "rootfs: DATA:subvol-2200-disk-0,size=8G"; }
    pvesm() { echo "${TEST_ROOT}/rootfs"; }
    main 2200 --target 3.18 --dry-run
  ) > "${TEST_ROOT}/downgrade-output" 2>&1
}

if run_dry_run_downgrade; then
  fail "downgrade is rejected"
else
  pass "downgrade is rejected"
fi

candidate_list=$(
  CT_LIST=(2000 2100 2200 2300)
  read_ct_release() {
    case "$CTID" in
      2000) echo 3.23 ;;
      2100) echo 3.24 ;;
      2200) echo 3.25 ;;
      2300) return 1 ;;
    esac
  }
  collect_upgrade_candidates 3.24
  printf '%s\n' "${CT_LIST[*]}"
)
if [[ "$candidate_list" == "2000" ]]; then
  pass "candidate list contains only Alpine CTs older than target"
else
  echo "$candidate_list" >&2
  fail "candidate list contains only Alpine CTs older than target"
fi

: > "${TEST_ROOT}/selection-routing"
if (
  build_ct_list() {
    CT_LIST=(2000 2100 2200 2300)
    CT_MAP[2000]="webtop.thesaints.home"
    CT_MAP[2100]="seafile.thesaints.de"
    CT_MAP[2200]="nodered.thesaints.home"
    CT_MAP[2300]="home.thesaints.home"
    CT_STATUS[2000]="running"
    CT_STATUS[2100]="running"
    CT_STATUS[2200]="running"
    CT_STATUS[2300]="running"
  }
  read_ct_release() {
    case "$CTID" in
      2000) echo 3.23 ;;
      2100) echo 3.19 ;;
      2200) echo 3.24 ;;
      2300) return 1 ;;
    esac
  }
  select_ct_interactive_multi() {
    echo "multi:${CT_LIST[*]}" >> "${TEST_ROOT}/selection-routing"
    SELECTED_CTS=(2000 2100)
  }
  select_ct_interactive_single() {
    echo "single" >> "${TEST_ROOT}/selection-routing"
    return 1
  }
  prepare_upgrade() {
    CTID="$1"
    CT_HOSTNAME="${CT_MAP[$CTID]}"
    ORIGINAL_STATUS=running
    case "$CTID" in
      2000) PREPARED_CURRENT=3.23 ;;
      2100) PREPARED_CURRENT=3.19 ;;
    esac
  }
  main --target 3.24 --dry-run
) > "${TEST_ROOT}/multi-dry-run-output" 2>&1; then
  pass "options-only invocation uses candidate multi-select"
else
  cat "${TEST_ROOT}/multi-dry-run-output" >&2
  fail "options-only invocation uses candidate multi-select"
fi
assert_contains "multi-select receives only upgrade candidates" "${TEST_ROOT}/selection-routing" "multi:2000 2100"
if grep -Fq "single" "${TEST_ROOT}/selection-routing"; then
  fail "candidate selection avoids single-select"
else
  pass "candidate selection avoids single-select"
fi
assert_contains "batch preview includes first selected CT" "${TEST_ROOT}/multi-dry-run-output" "CT 2000 (webtop.thesaints.home): Alpine 3.23 -> 3.24"
assert_contains "batch preview includes full older release path" "${TEST_ROOT}/multi-dry-run-output" "Release path: 3.20 3.21 3.22 3.23 3.24"

: > "${TEST_ROOT}/empty-selection"
if (
  build_ct_list() {
    CT_LIST=(2200)
    CT_MAP[2200]="nodered.thesaints.home"
    CT_STATUS[2200]="running"
  }
  read_ct_release() { echo 3.24; }
  select_ct_interactive_multi() { echo called > "${TEST_ROOT}/empty-selection"; }
  main --target 3.24
) > "${TEST_ROOT}/no-candidates-output" 2>&1; then
  pass "no candidates exits successfully"
else
  cat "${TEST_ROOT}/no-candidates-output" >&2
  fail "no candidates exits successfully"
fi
assert_contains "no candidates reports target" "${TEST_ROOT}/no-candidates-output" "No containers are eligible for upgrade to Alpine 3.24."
assert_empty "no candidates does not open multi-select" "${TEST_ROOT}/empty-selection"

: > "${TEST_ROOT}/current-confirmation"
if (
  build_ct_list() { CT_LIST=(2200); CT_MAP[2200]="nodered.thesaints.home"; }
  resolve_ct_from_input() { CTID=2200; CT_HOSTNAME="nodered.thesaints.home"; }
  get_ct_status() { echo running; }
  pct() { [[ "$1" == "config" ]] && return 0; echo "$*" >> "${TEST_ROOT}/current-confirmation"; }
  read_ct_release() { echo 3.24; }
  main 2200 --target 3.24
) > "${TEST_ROOT}/already-current-output" 2>&1; then
  pass "explicit already-current CT remains a successful no-op"
else
  cat "${TEST_ROOT}/already-current-output" >&2
  fail "explicit already-current CT remains a successful no-op"
fi
assert_contains "already-current message is preserved" "${TEST_ROOT}/already-current-output" "Already at the requested release; no changes needed."
assert_empty "already-current CT performs no mutation" "${TEST_ROOT}/current-confirmation"

: > "${TEST_ROOT}/batch-events"
if (
  build_ct_list() {
    CT_LIST=(2000 2100)
    CT_MAP[2000]="webtop.thesaints.home"
    CT_MAP[2100]="seafile.thesaints.de"
    CT_STATUS[2000]="running"
    CT_STATUS[2100]="running"
  }
  read_ct_release() { echo 3.23; }
  select_ct_interactive_multi() { SELECTED_CTS=(2000 2100); }
  prepare_upgrade() {
    CTID="$1"
    CT_HOSTNAME="${CT_MAP[$CTID]}"
    ORIGINAL_STATUS=running
    PREPARED_CURRENT=3.23
  }
  perform_upgrade() {
    echo "upgrade:${CTID}:${SNAPSHOT_CREATED}:${COMMITTED}" >> "${TEST_ROOT}/batch-events"
    SNAPSHOT_CREATED=true
    COMMITTED=true
  }
  main --target 3.24 --force
) > "${TEST_ROOT}/batch-output" 2>&1; then
  pass "selected candidates upgrade serially"
else
  cat "${TEST_ROOT}/batch-output" >&2
  fail "selected candidates upgrade serially"
fi
assert_contains "first selected CT upgrades" "${TEST_ROOT}/batch-events" "upgrade:2000:false:false"
assert_contains "second selected CT receives reset rollback state" "${TEST_ROOT}/batch-events" "upgrade:2100:false:false"
assert_contains "batch success summary is reported" "${TEST_ROOT}/batch-output" "All 2 selected CT(s) upgraded successfully."

: > "${TEST_ROOT}/decline-events"
if printf 'n\n' | (
  build_ct_list() {
    CT_LIST=(2000 2100)
    CT_MAP[2000]="webtop.thesaints.home"
    CT_MAP[2100]="seafile.thesaints.de"
    CT_STATUS[2000]="running"
    CT_STATUS[2100]="running"
  }
  read_ct_release() { echo 3.23; }
  select_ct_interactive_multi() { SELECTED_CTS=(2000 2100); }
  prepare_upgrade() {
    CTID="$1"
    CT_HOSTNAME="${CT_MAP[$CTID]}"
    ORIGINAL_STATUS=running
    PREPARED_CURRENT=3.23
  }
  perform_upgrade() { echo "$CTID" >> "${TEST_ROOT}/decline-events"; }
  main --target 3.24
) > "${TEST_ROOT}/decline-output" 2>&1; then
  pass "one declined batch confirmation exits successfully"
else
  cat "${TEST_ROOT}/decline-output" >&2
  fail "one declined batch confirmation exits successfully"
fi
assert_contains "declined batch reports abort" "${TEST_ROOT}/decline-output" "Aborted."
assert_empty "declined batch upgrades no CTs" "${TEST_ROOT}/decline-events"

: > "${TEST_ROOT}/failure-events"
set +e
(
  set -Ee
  build_ct_list() {
    CT_LIST=(2000 2100)
    CT_MAP[2000]="webtop.thesaints.home"
    CT_MAP[2100]="seafile.thesaints.de"
    CT_STATUS[2000]="running"
    CT_STATUS[2100]="running"
  }
  read_ct_release() { echo 3.23; }
  select_ct_interactive_multi() { SELECTED_CTS=(2000 2100); }
  prepare_upgrade() {
    CTID="$1"
    CT_HOSTNAME="${CT_MAP[$CTID]}"
    ORIGINAL_STATUS=running
    PREPARED_CURRENT=3.23
  }
  perform_upgrade() {
    echo "$CTID" >> "${TEST_ROOT}/failure-events"
    return 1
  }
  main --target 3.24 --force
) > "${TEST_ROOT}/failure-output" 2>&1
failure_status=$?
set -e
if [[ $failure_status -eq 0 ]]; then
  fail "failed selected CT stops batch"
else
  pass "failed selected CT stops batch"
fi
if [[ "$(cat "${TEST_ROOT}/failure-events")" == "2000" ]]; then
  pass "later selected CT does not start after failure"
else
  cat "${TEST_ROOT}/failure-events" >&2
  fail "later selected CT does not start after failure"
fi

echo "${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]