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

run_delete_dry_run() {
  local force="${1:-false}"
  local output="$2" mutations="$3"
  (
    source "${SCRIPT_DIR}/deleteCT.sh"
    build_ct_list() { CT_LIST=(2100); CT_MAP[2100]="app.thesaints.home"; CT_STATUS[2100]="running"; }
    resolve_ct_from_input() { CTID=2100; CT_HOSTNAME="app.thesaints.home"; }
    validate_node_storage_contract() { return 0; }
    get_ct_dirs() {
      DIR_DOCKER="${TEST_ROOT}/docker/app.thesaints.home"
      DIR_DOCKER_DATA="${TEST_ROOT}/docker-data/app.thesaints.home"
    }
    validate_cleanup_path() { return 0; }
    get_ct_status() { echo running; }
    pct() {
      if [[ "$1" == "config" ]]; then
        echo "rootfs: DATA:subvol-2100-disk-0,size=8G"
        echo "mp0: /mnt/docker/app.thesaints.home,mp=/mnt/docker"
      else
        echo "pct $*" >> "$mutations"
      fi
    }
    destroy_ct() { echo destroy >> "$mutations"; }
    cleanup_folders() { echo cleanup >> "$mutations"; }

    if [[ "$force" == "true" ]]; then
      main 2100 --force --dry-run
    else
      main 2100 --dry-run <<< $'y\ny'
    fi
  ) > "$output" 2>&1
}

mkdir -p "${TEST_ROOT}/docker/app.thesaints.home" "${TEST_ROOT}/docker-data/app.thesaints.home"
echo data > "${TEST_ROOT}/docker/app.thesaints.home/file"
: > "${TEST_ROOT}/delete-mutations"
run_delete_dry_run false "${TEST_ROOT}/delete-output" "${TEST_ROOT}/delete-mutations"
assert_contains "delete dry-run prints CT plan" "${TEST_ROOT}/delete-output" "CT:       2100 (app.thesaints.home) [running]"
assert_contains "delete dry-run records folder deletion" "${TEST_ROOT}/delete-output" "Data:     delete"
assert_contains "delete dry-run reports no changes" "${TEST_ROOT}/delete-output" "[dry-run] No changes made."
assert_empty "delete dry-run executes no mutation" "${TEST_ROOT}/delete-mutations"

: > "${TEST_ROOT}/delete-force-mutations"
run_delete_dry_run true "${TEST_ROOT}/delete-force-output" "${TEST_ROOT}/delete-force-mutations"
assert_contains "delete force dry-run remains non-mutating" "${TEST_ROOT}/delete-force-output" "[dry-run] No changes made."
assert_empty "delete force dry-run executes no mutation" "${TEST_ROOT}/delete-force-mutations"

run_rename_dry_run() {
  local output="$1" mutations="$2"
  (
    source "${SCRIPT_DIR}/renameCT.sh"
    set -E
    trap 'echo "ERR line ${LINENO}: ${BASH_COMMAND}" >&2' ERR
    CONFIG_FILE="${TEST_ROOT}/commonCT.json"
    validate_node_storage_contract() { return 0; }
    config_exists() { return 0; }
    config_domain_exists() { return 0; }
    config_udmpro_configured() { return 0; }
    extract_domain_from_hostname() { echo thesaints.home; }
    build_ct_list() {
      CT_LIST=(2100 2200)
      CT_MAP[2100]="old.thesaints.home"
      CT_MAP[2200]="other.thesaints.home"
      CT_STATUS[2100]="running"
      CT_STATUS[2200]="running"
    }
    get_ct_dirs() {
      DIR_DOCKER="${TEST_ROOT}/docker/$1"
      DIR_DOCKER_DATA="${TEST_ROOT}/docker-data/$1"
    }
    get_ct_status() { echo running; }
    ct_exec() { echo 10.0.0.10; }
    pct() {
      if [[ "$1" == "config" ]]; then
        echo "net0: name=eth0,hwaddr=AA:BB:CC:DD:EE:FF,ip=dhcp"
        echo "mp0: /mnt/docker/old.thesaints.home,mp=/mnt/docker"
        echo "mp1: /mnt/docker-data/old.thesaints.home,mp=/mnt/docker-data"
      else
        echo "pct $*" >> "$mutations"
      fi
    }
    do_rename() { echo rename >> "$mutations"; }
    refresh_cts() { echo refresh >> "$mutations"; }

    main old.thesaints.home new.thesaints.home --dry-run
  ) > "$output" 2>&1
}

mkdir -p "${TEST_ROOT}/docker/old.thesaints.home" "${TEST_ROOT}/docker-data/old.thesaints.home"
printf '{"host":"old.thesaints.home"}\n' > "${TEST_ROOT}/commonCT.json"
: > "${TEST_ROOT}/rename-mutations"
run_rename_dry_run "${TEST_ROOT}/rename-output" "${TEST_ROOT}/rename-mutations" &
rename_pid=$!
if wait "$rename_pid"; then
  assert_contains "rename dry-run prints hostname transition" "${TEST_ROOT}/rename-output" "old.thesaints.home  ->  new.thesaints.home"
  assert_contains "rename dry-run prints config count" "${TEST_ROOT}/rename-output" "commonCT.json (1 replacement(s))"
  assert_contains "rename dry-run prints refresh order" "${TEST_ROOT}/rename-output" "refreshCT.sh other.thesaints.home"
  assert_contains "rename dry-run reports no changes" "${TEST_ROOT}/rename-output" "[dry-run] No changes made."
else
  cat "${TEST_ROOT}/rename-output" >&2
  fail "rename dry-run completes"
fi
assert_empty "rename dry-run executes no mutation" "${TEST_ROOT}/rename-mutations"

echo "${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]