#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
MOCK_BIN="${TEST_ROOT}/bin"
mkdir -p "$MOCK_BIN"
trap 'rm -rf "$TEST_ROOT"' EXIT

PASS=0
FAIL=0

pass() {
  echo "ok - $1"
  PASS=$((PASS + 1))
}

fail() {
  echo "not ok - $1" >&2
  FAIL=$((FAIL + 1))
}

assert_success() {
  local name="$1"
  shift
  if "$@" >"${TEST_ROOT}/output" 2>&1; then
    pass "$name"
  else
    cat "${TEST_ROOT}/output" >&2
    fail "$name"
  fi
}

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

assert_failure() {
  local name="$1"
  shift
  if "$@" >"${TEST_ROOT}/output" 2>&1; then
    fail "$name"
  else
    pass "$name"
  fi
}

assert_output() {
  local name="$1" expected="$2"
  shift 2
  local actual
  if actual=$("$@" 2>&1) && [[ "$actual" == "$expected" ]]; then
    pass "$name"
  else
    echo "expected: ${expected}" >&2
    echo "actual:   ${actual}" >&2
    fail "$name"
  fi
}

cat >"${MOCK_BIN}/hostname" <<'EOF'
#!/usr/bin/env bash
echo pve01
EOF

cat >"${MOCK_BIN}/pvesh" <<'EOF'
#!/usr/bin/env bash
request="$*"
if [[ "$request" == *'/status'* ]]; then
  echo '{"active":1}'
elif [[ "$request" == *'/storage/local-lvm '* ]]; then
  echo '{"storage":"local-lvm","type":"lvmthin","vgname":"pve","thinpool":"data","content":"rootdir,images","shared":0,"disable":0}'
elif [[ "$request" == *'/storage/DATA '* ]]; then
  if [[ "${MOCK_BAD_DATA_TYPE:-false}" == "true" ]]; then
    echo '{"storage":"DATA","type":"dir","path":"/DATA","content":"rootdir,images","shared":0,"disable":0}'
  else
    echo '{"storage":"DATA","type":"zfspool","pool":"DATA","mountpoint":"/DATA","content":"rootdir,images","shared":0,"disable":0}'
  fi
elif [[ "$request" == *'/storage/DOCKER-DATA '* ]]; then
  echo '{"storage":"DOCKER-DATA","type":"dir","path":"/mnt/docker-data","content":"rootdir","create-base-path":0,"shared":0,"disable":0}'
elif [[ "$request" == *'/storage/DOCKER '* ]]; then
  echo '{"storage":"DOCKER","type":"dir","path":"/mnt/docker","content":"rootdir","create-base-path":0,"shared":0,"disable":0}'
else
  exit 1
fi
EOF

cat >"${MOCK_BIN}/lvs" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"-o lv_size,pool_lv"*) printf '68719476736 data\n' ;;
  *"-o lv_size pve/data"*) echo 107374182400 ;;
  *"-o data_percent pve/data"*) echo "${MOCK_DATA_PERCENT:-10.00}" ;;
  *"-o metadata_percent pve/data"*) echo "${MOCK_METADATA_PERCENT:-2.00}" ;;
  *) exit 1 ;;
esac
EOF

cat >"${MOCK_BIN}/df" <<'EOF'
#!/usr/bin/env bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf '/dev/pve/root 100 50 50 50%% /\n'
EOF

cat >"${MOCK_BIN}/ssh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"lv_size,data_percent,metadata_percent pve/data"*) echo "107374182400 10.00 2.00" ;;
  *"lv_size,pool_lv"*) echo 68719476736 ;;
  *"df -P /"*) echo 50 ;;
  *) exit 1 ;;
esac
EOF

cat >"${MOCK_BIN}/mountpoint" <<'EOF'
#!/usr/bin/env bash
path="${*: -1}"
if [[ "${MOCK_MISSING_MOUNT:-}" == "$path" ]]; then
  exit 1
fi
exit 0
EOF

cat >"${MOCK_BIN}/findmnt" <<'EOF'
#!/usr/bin/env bash
path="${*: -1}"
case "$path" in
  /) echo rpool/ROOT/pve-1 ;;
  /DATA) echo DATA ;;
  /mnt/docker) echo ARCHIVE/docker ;;
  /mnt/docker-data) echo DATA/docker-data ;;
  *) exit 1 ;;
esac
EOF

chmod +x "${MOCK_BIN}"/*
export PATH="${MOCK_BIN}:${PATH}"
export SCRIPT_DIR
source "${SCRIPT_DIR}/commonCT.sh"

assert_success "valid storage contract" validate_node_storage_contract pve01
assert_success "valid local-lvm rootfs capacity" validate_rootfs_target_capacity pve01 16 20
assert_success "valid OS root headroom" validate_os_root_headroom pve01 20
assert_success "remote local-lvm capacity is validated over SSH" validate_rootfs_target_capacity pve02 16 20
assert_success "remote OS root headroom is validated over SSH" validate_os_root_headroom pve02 20
if grep -Fq '\044' "${SCRIPT_DIR}/commonCT.sh"; then
  fail "remote capacity awk uses portable field references"
else
  pass "remote capacity awk uses portable field references"
fi

export MOCK_DATA_PERCENT=70
assert_failure_contains "local-lvm projected headroom is enforced" "lacks 20% headroom" \
  validate_rootfs_target_capacity pve01 16 20
unset MOCK_DATA_PERCENT

export MOCK_METADATA_PERCENT=80
assert_failure_contains "local-lvm metadata pressure is rejected" "metadata usage" \
  validate_rootfs_target_capacity pve01 1 20
unset MOCK_METADATA_PERCENT

export MOCK_BAD_DATA_TYPE=true
assert_failure_contains "wrong DATA type is rejected" "must be type zfspool" validate_node_storage_contract pve01
unset MOCK_BAD_DATA_TYPE

export MOCK_MISSING_MOUNT=/mnt/docker-data
assert_failure_contains "missing Docker-data mount is rejected" "is not a mountpoint" validate_node_storage_contract pve01
unset MOCK_MISSING_MOUNT

mkdir -p "${TEST_ROOT}/gpu/absent/pci" "${TEST_ROOT}/gpu/absent/dri"
assert_output "node without GPU is classified absent" "STATE absent" \
  env GPU_PCI_ROOT="${TEST_ROOT}/gpu/absent/pci" GPU_DRI_ROOT="${TEST_ROOT}/gpu/absent/dri" \
  bash -c "source '${SCRIPT_DIR}/commonCT.sh'; probe_local_gpu_capability"

mkdir -p "${TEST_ROOT}/gpu/broken/pci/0000:00:02.0" "${TEST_ROOT}/gpu/broken/dri"
echo 0x030000 > "${TEST_ROOT}/gpu/broken/pci/0000:00:02.0/class"
assert_output "GPU without render device is classified broken" "STATE broken" \
  env GPU_PCI_ROOT="${TEST_ROOT}/gpu/broken/pci" GPU_DRI_ROOT="${TEST_ROOT}/gpu/broken/dri" \
  bash -c "source '${SCRIPT_DIR}/commonCT.sh'; probe_local_gpu_capability"

assert_success "moveCT help parses" bash "${SCRIPT_DIR}/moveCT.sh" --help
assert_failure_contains "legacy --gpu option is rejected" "Unknown option '--gpu'" bash "${SCRIPT_DIR}/moveCT.sh" --gpu
if grep -Fq 'resolve_ct_gpu_capability "$CTID" "$TARGET_NODE" "$RELEVANT_PROFILE_GROUPS"' "${SCRIPT_DIR}/moveCT.sh" \
  && ! grep -Fq 'detect_node_gpu_capability "$TARGET_NODE"' "${SCRIPT_DIR}/moveCT.sh"; then
  pass "move preflight uses CT-aware GPU capability"
else
  fail "move preflight uses CT-aware GPU capability"
fi
if grep -Fq "The CT will be stopped briefly for the final data sync" "${SCRIPT_DIR}/moveCT.sh"; then
  pass "move confirmation explains downtime in plain language"
else
  fail "move confirmation explains downtime in plain language"
fi
assert_failure_contains "create rejects rootfs storage overrides" "storage is fixed to local-lvm" \
  bash "${SCRIPT_DIR}/createCT.sh" app.thesaints.home STORAGE=DATA

if grep -Fq -- '--target-storage local-lvm:local-lvm' "${SCRIPT_DIR}/moveCT.sh" \
  && ! grep -Fq -- '--target-storage DATA:DATA' "${SCRIPT_DIR}/moveCT.sh"; then
  pass "move and rollback mappings are local-lvm only"
else
  fail "move and rollback mappings are local-lvm only"
fi

source "${SCRIPT_DIR}/moveCT.sh"
assert_failure_contains "move abort reports the validation reason" "ERROR: validation failed" abort_move "validation failed"
MOVE_TUI_ENABLED=false
assert_success "move progress is safe without an interactive TTY" move_status_progress 1 "Testing progress"
if grep -Fq -- '-o ServerAliveInterval=5 -o ServerAliveCountMax=3' "${SCRIPT_DIR}/moveCT.sh"; then
  pass "remote moves detect established SSH connection loss"
else
  fail "remote moves detect established SSH connection loss"
fi
state_check_line=$(grep -n 'Existing move transaction found for CT' "${SCRIPT_DIR}/moveCT.sh" | head -1 | cut -d: -f1)
target_path_check_line=$(grep -n 'Target bind paths already exist' "${SCRIPT_DIR}/moveCT.sh" | head -1 | cut -d: -f1)
if [[ -n "$state_check_line" && -n "$target_path_check_line" \
  && "$state_check_line" -lt "$target_path_check_line" ]]; then
  pass "fresh move detects retained transaction before target path ambiguity"
else
  fail "fresh move detects retained transaction before target path ambiguity"
fi

contract_sequence=$(declare -f validate_move_node_contracts |
  grep -E 'validate_(node_storage_contract|rootfs_target_capacity|os_root_headroom)' |
  sed -E 's/^[[:space:]]*//; s/CONTRACT_NODE_HEADER_ACTIVE=true[[:space:]]+//; s/[[:space:]]*\\$//; s/[[:space:]]*\|\| return 1$//')
expected_contract_sequence=$(cat <<'EOF'
validate_node_storage_contract "$node" || return 1;
validate_rootfs_target_capacity "$node" "$additional_rootfs_gib" 20 || return 1;
validate_os_root_headroom "$node" 20
EOF
)
if [[ "$contract_sequence" == "$expected_contract_sequence" ]]; then
  pass "node storage and capacity contracts retain their order"
else
  printf 'actual contract order:\n%s\n' "$contract_sequence" >&2
  fail "node storage and capacity contracts retain their order"
fi
move_contract_calls=$(sed -n '/validate_move_node_contracts "$SOURCE_NODE"/,/detect_node_gpu_capability/p' \
  "${SCRIPT_DIR}/moveCT.sh" | grep 'validate_move_node_contracts' | sed -E 's/^[[:space:]]*//; s/[[:space:]]*\|\| exit 1$//')
expected_move_contract_calls=$(cat <<'EOF'
validate_move_node_contracts "$SOURCE_NODE" 0
validate_move_node_contracts "$TARGET_NODE" "$rootfs_size_gib"
EOF
)
if [[ "$move_contract_calls" == "$expected_move_contract_calls" ]]; then
  pass "contract headers run once for source then target"
else
  printf 'actual contract headers:\n%s\n' "$move_contract_calls" >&2
  fail "contract headers run once for source then target"
fi

fallback_compose="${TEST_ROOT}/fallback-compose"
mkdir -p "$fallback_compose"
cat > "${fallback_compose}/docker-compose.yaml" <<'EOF'
services:
  app:
    image: example/app
    command: ["sh", "-c", "probe >/dev/null 2>&1"]
    devices:
      - /dev/dri/renderD128:/dev/dri/renderD128
  worker:
    image: example/worker
EOF
ORIGINAL_STATUS=stopped
DIR_DOCKER="$fallback_compose"
collect_device_requirements
if [[ ${#DEVICE_REQUIREMENTS[@]} -eq 1 \
  && "${DEVICE_REQUIREMENTS[0]}" == $'app\t/dev/dri/renderD128' ]]; then
  pass "fallback device parser ignores command redirections"
else
  printf 'fallback requirements: %q\n' "${DEVICE_REQUIREMENTS[@]}" >&2
  fail "fallback device parser ignores command redirections"
fi

original_collect_device_requirements=$(declare -f collect_device_requirements)
original_remote=$(declare -f remote)
device_validation_calls="${TEST_ROOT}/device-validation-calls"
mock_device_requirement=$'frigate\t/dev/dri'
collect_device_requirements() {
  DEVICE_REQUIREMENTS=("$mock_device_requirement")
}
remote() {
  printf '%s\t%s\n' "$TARGET_NODE" "$*" >> "$device_validation_calls"
  [[ "$TARGET_NODE" == pve02 && "$*" == "test -e '/dev/dri'" ]]
}
TARGET_NODE=pve02
NODE_GPU_STATE=available
: > "$device_validation_calls"
assert_success "generic DRM passes on a capable remote target" validate_target_devices
if grep -Fxq $'pve02\ttest -e \'/dev/dri\'' "$device_validation_calls"; then
  pass "generic DRM existence check uses the selected target"
else
  fail "generic DRM existence check uses the selected target"
fi

for unavailable_state in absent broken; do
  NODE_GPU_STATE="$unavailable_state"
  : > "$device_validation_calls"
  assert_failure_contains "generic DRM rejects ${unavailable_state} target capability" \
    "requires DRM, but the target has no usable render device" validate_target_devices
  if [[ ! -s "$device_validation_calls" ]]; then
    pass "${unavailable_state} DRM rejection occurs before target path probing"
  else
    fail "${unavailable_state} DRM rejection occurs before target path probing"
  fi
done

original_has_device_free_profile=$(declare -f has_device_free_profile)
has_device_free_profile() { return 0; }
NODE_GPU_STATE=absent
: > "$device_validation_calls"
assert_success "validated CPU profile permits a target without DRM" validate_target_devices
if [[ ! -s "$device_validation_calls" ]]; then
  pass "CPU fallback bypasses irrelevant target DRM path probing"
else
  fail "CPU fallback bypasses irrelevant target DRM path probing"
fi
eval "$original_has_device_free_profile"

NODE_GPU_STATE=available
mock_device_requirement=$'frigate\t/dev/bus/usb'
assert_failure_contains "broad USB remains rejected during move preflight" \
  "USB device identity cannot be proven on another node" validate_target_devices

eval "$original_collect_device_requirements"
eval "$original_remote"

original_ct_exec=$(declare -f ct_exec)
original_compose_file_has_managed_profiles=$(declare -f compose_file_has_managed_profiles)
profile_validation_calls="${TEST_ROOT}/profile-validation-calls"
device_free_compose_json='{"services":{"app":{"container_name":"app"}}}'
ct_exec() {
  printf '%s\n' "$*" >> "$profile_validation_calls"
  printf '%s\n' "$device_free_compose_json"
}
SOURCE_NODE=pve02
ORIGINAL_STATUS=running
DIR_DOCKER=/mnt/docker/app.thesaints.home
assert_success "device-free profile structure is accepted" has_device_free_profile
if grep -Fq "COMPOSE_PROFILES=no-discrete-gpu" \
  "$profile_validation_calls"; then
  pass "CPU fallback validation renders inside the source CT"
else
  fail "CPU fallback validation renders inside the source CT"
fi
device_free_compose_json='{"services":{"app":{"container_name":"app","devices":[{"source":"/dev/dri"}]}}}'
assert_failure "device mapping invalidates CPU fallback profile" has_device_free_profile

compose_file_has_managed_profiles() { return 0; }
device_free_compose_json='{"services":{"app":{"container_name":"app"}}}'
: > "$profile_validation_calls"
assert_success "grouped device-free fallback structure is accepted" has_device_free_profile
if grep -Fq "COMPOSE_PROFILES='gpu-none'" "$profile_validation_calls"; then
  pass "managed fallback validation uses the configured default"
else
  fail "managed fallback validation uses the configured default"
fi

ORIGINAL_STATUS=stopped
assert_failure "stopped CT cannot claim a rendered device-free fallback" has_device_free_profile
eval "$original_ct_exec"
eval "$original_compose_file_has_managed_profiles"

SOURCE_NODE=pve01
DIR_DOCKER=/mnt/docker/app.thesaints.home
ORIGINAL_STATUS=stopped
compose_file_has_managed_profiles() { return 0; }
assert_failure_contains "stopped managed-profile CT move is rejected before mutation" \
  "cannot be moved safely" validate_stopped_profile_move
compose_file_has_managed_profiles() { return 1; }
assert_success "stopped legacy-profile CT remains movable" validate_stopped_profile_move
ORIGINAL_STATUS=running
compose_file_has_managed_profiles() { return 0; }
assert_success "running managed-profile CT remains movable" validate_stopped_profile_move
eval "$original_compose_file_has_managed_profiles"

assert_output "migration-specific bandwidth overrides default" "2048" \
  parse_migration_bwlimit_kib "default=1024,migration=2048,restore=4096"
assert_output "default bandwidth applies without migration override" "1024" \
  parse_migration_bwlimit_kib "clone=4096,default=1024"
assert_output "missing bandwidth policy remains unknown" "" parse_migration_bwlimit_kib ""

task_list='[{"upid":"UPID:pve01:OLD:vzmigrate:2200:root@pam:","type":"vzmigrate","starttime":1},{"upid":"UPID:pve01:NEW:vzmigrate:2200:root@pam:","type":"vzmigrate","starttime":2}]'
assert_output "new native migration UPID is selected from task history" \
  "UPID:pve01:NEW:vzmigrate:2200:root@pam:" \
  select_new_migration_upid "$task_list" "UPID:pve01:OLD:vzmigrate:2200:root@pam:"
assert_failure "previous migration UPID is not rediscovered" \
  select_new_migration_upid '[{"upid":"UPID:pve01:OLD:vzmigrate:2200:root@pam:","type":"vzmigrate","starttime":1}]' \
  "UPID:pve01:OLD:vzmigrate:2200:root@pam:"
assert_failure "malformed task history is rejected cleanly" \
  select_new_migration_upid 'unexpected output' ""

export MOVE_STATE_ROOT="${TEST_ROOT}/move-state"
CTID=2200
CT_HOSTNAME=app.thesaints.home
SOURCE_NODE=pve01
TARGET_NODE=pve02
ORIGINAL_STATUS=running
EXPECTED_SERVICES=$'app\ncaddy'
DIR_DOCKER=/mnt/docker/app.thesaints.home
DIR_DOCKER_DATA=/mnt/docker-data/app.thesaints.home
ORIGINAL_MOUNT_KEYS=(mp0 mp1)
ORIGINAL_MOUNT_VALUES=("/mnt/docker/app.thesaints.home,mp=/mnt/docker" "/mnt/docker-data/app.thesaints.home,mp=/mnt/docker-data")
ORIGINAL_NETWORK_KEYS=(net0 net1)
ORIGINAL_NETWORK_VALUES=("name=eth0,bridge=vmbr1" "name=eth1,bridge=vmbr1")
SOURCE_BRIDGE=vmbr1
SOURCE_BRIDGE_REASON="type CT"
TARGET_BRIDGE=vmbr2
TARGET_BRIDGE_REASON="hostname/name app.thesaints.home"
MOVE_PHASE=initialized
MOVE_STATE_FILE=$(move_state_path "$CTID")
mkdir -p "$MOVE_STATE_ROOT"
save_move_state
first_revision=$MOVE_STATE_REVISION
checkpoint_move target_prepared >/dev/null
if [[ "$MOVE_STATE_REVISION" -gt "$first_revision" ]] \
  && [[ "$(jq -r '.phase' "$MOVE_STATE_FILE")" == target_prepared ]] \
  && [[ "$(jq -r '.mount_keys | join(" ")' "$MOVE_STATE_FILE")" == "mp0 mp1" ]] \
  && [[ "$(jq -r '.network.target_bridge' "$MOVE_STATE_FILE")" == vmbr2 ]]; then
  pass "move checkpoints are atomic, revisioned, and preserve mounts and network policy"
else
  fail "move checkpoints are atomic, revisioned, and preserve mounts and network policy"
fi

MOVE_PHASE=""
ORIGINAL_MOUNT_KEYS=()
ORIGINAL_MOUNT_VALUES=()
CT_NODE["$CTID"]=""
load_move_state
if [[ "$MOVE_PHASE" == target_prepared \
  && "${ORIGINAL_MOUNT_VALUES[1]}" == "/mnt/docker-data/app.thesaints.home,mp=/mnt/docker-data" \
  && "$SOURCE_BRIDGE" == vmbr1 && "$TARGET_BRIDGE" == vmbr2 \
  && "${CT_NODE[$CTID]}" == pve01 ]]; then
  pass "saved pre-migration transaction reloads with source ownership"
else
  fail "saved pre-migration transaction reloads with source ownership"
fi

MOVE_PHASE=mounts_restored
MOUNT_TRANSACTION_STARTED=false
save_move_state
MOUNT_TRANSACTION_STARTED=false
load_move_state
if [[ "$MOUNT_TRANSACTION_STARTED" == true && "${CT_NODE[$CTID]}" == pve02 ]]; then
  pass "resumed post-migration state restores target ownership and detached mounts"
else
  fail "resumed post-migration state restores target ownership and detached mounts"
fi

profile_checkpoint_line=$(grep -n 'checkpoint_move profile_tags_reconciled' "${SCRIPT_DIR}/moveCT.sh" | head -1 | cut -d: -f1)
service_verify_line=$(grep -n 'verify_target_services' "${SCRIPT_DIR}/moveCT.sh" | tail -1 | cut -d: -f1)
if [[ -n "$profile_checkpoint_line" && -n "$service_verify_line" \
  && "$profile_checkpoint_line" -lt "$service_verify_line" ]]; then
  pass "target profile reconciliation checkpoints before Compose verification"
else
  fail "target profile reconciliation checkpoints before Compose verification"
fi

task_commands="${TEST_ROOT}/task-commands"
pvesh() {
  printf '%s\n' "$*" >>"$task_commands"
  case "$*" in
    create*) touch "${TEST_ROOT}/task-launched"; return 0 ;;
    *'/tasks '*|*'/tasks --'*)
      if [[ -e "${TEST_ROOT}/task-launched" ]]; then
        jq -n '[{upid:"UPID:pve01:00000001:00000001:00000001:vzmigrate:2200:root@pam:",type:"vzmigrate",starttime:2}]'
      else
        jq -n '[]'
      fi
      ;;
    *status*) jq -n '{status:"stopped",exitstatus:"OK"}' ;;
    *) return 1 ;;
  esac
}
MOVE_PHASE=mounts_detached
submit_migration_task >/dev/null
wait_for_migration_task >/dev/null
if [[ "$MOVE_PHASE" == migration_complete && "$MOVE_TASK_UPID" == UPID:* ]] \
  && grep -Fq '/nodes/pve01/lxc/2200/migrate' "$task_commands" \
  && grep -Fq "/nodes/pve01/tasks/${MOVE_TASK_UPID}/status" "$task_commands"; then
  pass "native Proxmox migration UPID is persisted and polled"
else
  cat "$task_commands" >&2
  fail "native Proxmox migration UPID is persisted and polled"
fi
unset -f pvesh

rollback_definition=$(declare -f rollback)
rollback_calls="${TEST_ROOT}/rollback-calls"
rollback() {
  printf 'rollback\n' >> "$rollback_calls"
  return "${1:-1}"
}
run_command_substitution_failure() (
  MOVE_COORDINATOR_BASHPID="$BASHPID"
  trap transaction_error_handler ERR
  local_output=$(false)
)
set +e
run_command_substitution_failure >/dev/null 2>&1
command_substitution_status=$?
set -e
if [[ "$command_substitution_status" -ne 0 \
  && "$(wc -l < "$rollback_calls")" -eq 1 ]]; then
  pass "command substitution failure triggers exactly one coordinator rollback"
else
  cat "$rollback_calls" 2>/dev/null >&2 || true
  fail "command substitution failure triggers exactly one coordinator rollback"
fi
eval "$rollback_definition"

set +e
(
  MOVE_LAST_SIGNAL=""
  move_signal_handler TERM 143
) >/dev/null 2>&1
signal_status=$?
set -e
if [[ "$signal_status" -eq 143 && "$(jq -r '.last_signal' "$MOVE_STATE_FILE")" == TERM ]]; then
  pass "move signals retain a resumable interruption checkpoint"
else
  fail "move signals retain a resumable interruption checkpoint"
fi

mount_commands="${TEST_ROOT}/mount-commands"
mount_config=$'rootfs: local-lvm:vm-2200-disk-0,size=16G\nmp0: /mnt/docker/app.thesaints.home,mp=/mnt/docker,backup=0\nmp1: /mnt/docker-data/app.thesaints.home,mp=/mnt/docker-data,ro=0'
pct() {
  if [[ "$1" == "config" ]]; then
    printf '%s\n' "$mount_config"
  else
    printf '%q ' "$@" >> "$mount_commands"
    printf '\n' >> "$mount_commands"
  fi
}
CTID=2200
CT_HOSTNAME=app.thesaints.home
SOURCE_NODE=pve01
TARGET_NODE=pve02
assert_success "original bind mount values are captured" capture_original_mounts
if [[ "${ORIGINAL_MOUNT_KEYS[*]}" == "mp0 mp1" \
  && "${ORIGINAL_MOUNT_VALUES[0]}" == "/mnt/docker/app.thesaints.home,mp=/mnt/docker,backup=0" \
  && "${ORIGINAL_MOUNT_VALUES[1]}" == "/mnt/docker-data/app.thesaints.home,mp=/mnt/docker-data,ro=0" ]]; then
  pass "bind mount keys and options are preserved verbatim"
else
  fail "bind mount keys and options are preserved verbatim"
fi
assert_success "source bind mounts detach deterministically" detach_source_mounts
if grep -Fq 'set 2200 -delete mp0' "$mount_commands" \
  && grep -Fq 'set 2200 -delete mp1' "$mount_commands"; then
  pass "source detach removes every captured mount"
else
  cat "$mount_commands" >&2
  fail "source detach removes every captured mount"
fi
mount_config=$'rootfs: local-lvm:vm-2200-disk-0,size=16G\nmp0: /mnt/docker/changed.thesaints.home,mp=/mnt/docker\nmp1: /mnt/docker-data/app.thesaints.home,mp=/mnt/docker-data,ro=0'
assert_failure_contains "mount drift aborts before migration mutation" "changed during pre-copy" \
  validate_mounts_unchanged
mount_config=$'rootfs: local-lvm:vm-2200-disk-0,size=16G\nmp0: /mnt/docker/app.thesaints.home,mp=/mnt/docker,backup=0\nmp1: /mnt/docker-data/app.thesaints.home,mp=/mnt/docker-data,ro=0'
assert_success "source bind mounts restore exactly" restore_source_mounts
if grep -Fq 'set 2200 -mp0 /mnt/docker/app.thesaints.home\,mp=/mnt/docker\,backup=0' "$mount_commands" \
  && grep -Fq 'set 2200 -mp1 /mnt/docker-data/app.thesaints.home\,mp=/mnt/docker-data\,ro=0' "$mount_commands"; then
  pass "source restore reapplies complete mount values"
else
  cat "$mount_commands" >&2
  fail "source restore reapplies complete mount values"
fi

: > "$mount_commands"
remote() { printf '%s\n' "$*" >> "$mount_commands"; }
assert_success "target bind mounts restore exactly" restore_target_mounts
if grep -Fq "pct set '2200' '-mp0' /run/pve-imds/2200\,mp=/mnt/pve-imds\,ro=1\,shared=1\,backup=0" "$mount_commands" \
  && grep -Fq "pct set '2200' '-mp1' /mnt/docker/app.thesaints.home\,mp=/mnt/docker" "$mount_commands" \
  && grep -Fq "pct set '2200' '-mp2' /mnt/docker-data/app.thesaints.home\,mp=/mnt/docker-data" "$mount_commands"; then
  pass "target restore applies the canonical three mount values"
else
  cat "$mount_commands" >&2
  fail "target restore applies the canonical three mount values"
fi
unset -f pct

rsync() { return 0; }
assert_success "checksum verification accepts identical rsync trees" verify_target_tree /source "Test tree"
rsync() { printf '>f+++++++++ changed-file\n'; }
assert_failure_contains "checksum verification rejects rsync differences" "differs after final synchronization" \
  verify_target_tree /source "Test tree"
unset -f rsync

backup_root="${TEST_ROOT}/backup"
complete_stem="vzdump-lxc-2200-2026_08_28-01_00_00"
incomplete_stem="vzdump-lxc-2200-2026_08_28-02_00_00"
mkdir -p "${backup_root}/TEST/dump" \
  "${backup_root}/TEST/workloads/app.thesaints.home/${complete_stem}/docker" \
  "${backup_root}/TEST/workloads/app.thesaints.home/${complete_stem}/docker-data" \
  "${backup_root}/TEST/workloads/app.thesaints.home/${incomplete_stem}/docker"
touch "${backup_root}/TEST/dump/${complete_stem}.tar.zst" \
  "${backup_root}/TEST/dump/${incomplete_stem}.tar.zst"
export BACKUP_MOUNT_ROOT="$backup_root"
config_get_backup_storage() { echo TEST; }
remote() { [[ "${MOCK_SEED_INACCESSIBLE:-false}" != "true" ]]; }
CTID=2200
CT_HOSTNAME=app.thesaints.home
assert_success "newest complete fresh backup seed is selected" find_backup_seed
assert_output "incomplete newer backup is skipped" "$complete_stem" basename "$BACKUP_SEED_GENERATION"

touch -d '27 hours ago' "${backup_root}/TEST/dump/${complete_stem}.tar.zst"
assert_failure "stale backup seed is rejected" find_backup_seed
touch "${backup_root}/TEST/dump/${complete_stem}.tar.zst"
export MOCK_SEED_INACCESSIBLE=true
assert_failure "target-inaccessible backup seed is rejected" find_backup_seed
unset MOCK_SEED_INACCESSIBLE
assert_success "fresh backup can be reselected" find_backup_seed

seed_commands="${TEST_ROOT}/seed-commands"
DIR_DOCKER=/mnt/docker/app.thesaints.home
DIR_DOCKER_DATA=/mnt/docker-data/app.thesaints.home
remote() { printf '%s\n' "$*" >> "$seed_commands"; }
assert_success "target-local backup seed command succeeds" seed_target_from_backup
if grep -Fq -- "--human-readable --info=progress2,stats1 '${BACKUP_SEED_GENERATION}/docker/' '${DIR_DOCKER}/'" "$seed_commands" \
  && grep -Fq "${BACKUP_SEED_GENERATION}/docker-data/" "$seed_commands"; then
  pass "backup seed preserves both workload trees on target"
else
  cat "$seed_commands" >&2
  fail "backup seed preserves both workload trees on target"
fi

if [[ $(grep -o -- '--info=progress2,stats1' "${SCRIPT_DIR}/moveCT.sh" | wc -l) -eq 5 ]]; then
  pass "every move rsync path reports aggregate progress"
else
  fail "every move rsync path reports aggregate progress"
fi

: > "$seed_commands"
remote() {
  printf '%s\n' "$*" >> "$seed_commands"
  [[ "$*" != rsync* ]]
}
assert_success "failed backup seed falls back before source sync" seed_target_or_fallback
if [[ -z "$BACKUP_SEED_GENERATION" ]] \
  && grep -Fq "rm -rf --one-file-system -- '$DIR_DOCKER' '$DIR_DOCKER_DATA' && mkdir -p" "$seed_commands"; then
  pass "failed backup seed resets partial target trees"
else
  cat "$seed_commands" >&2
  fail "failed backup seed resets partial target trees"
fi

TARGET_NODE=pve02
CTID=2200
capacity_config=$'rootfs: local-lvm:vm-2200-disk-0,size=16G\nmp0: /mnt/docker/app.thesaints.home,mp=/mnt/docker\nmp1: /mnt/docker-data/app.thesaints.home,mp=/mnt/docker-data'
pct() { [[ "$1" == "config" ]] && printf '%s\n' "$capacity_config"; }
assert_success "local-lvm rootfs is accepted for moves" validate_ct_storage_scope
assert_output "rootfs size is parsed for target capacity" "16" get_ct_rootfs_size_gib
capacity_config=$'rootfs: DATA:subvol-2200-disk-0,size=16G\nmp0: /mnt/docker/app.thesaints.home,mp=/mnt/docker\nmp1: /mnt/docker-data/app.thesaints.home,mp=/mnt/docker-data'
assert_failure_contains "DATA rootfs is rejected for cross-node moves" "must use managed storage 'local-lvm'" \
  validate_ct_storage_scope
capacity_config=$'rootfs: local-lvm:vm-2200-disk-0,size=16G\nmp0: /mnt/docker/app.thesaints.home,mp=/mnt/docker\nmp1: /mnt/docker-data/app.thesaints.home,mp=/mnt/docker-data\nmp2: /srv/unmanaged,mp=/srv/unmanaged'
assert_success "unmanaged bind sources are accepted for canonical deletion" validate_ct_storage_scope
capacity_config='rootfs: local-lvm:vm-2200-disk-0,size=16G'
assert_failure_contains "move rejects a CT whose required bind mounts are absent" \
  "required bind mount '/mnt/docker/app.thesaints.home,mp=/mnt/docker' is missing" \
  validate_ct_storage_scope
unset -f pct

transaction_root="${TEST_ROOT}/transaction-resolution"
mkdir -p "$transaction_root"
MOVE_STATE_ROOT="$transaction_root"
printf '{"ctid":"3500","hostname":"moved.example"}\n' > "${transaction_root}/3500.json"
MOVE_STATE_FILE=""
assert_success "numeric moved CT resolves from transaction state" resolve_move_state_input 3500
if [[ "$CTID" == 3500 && "$MOVE_STATE_FILE" == "${transaction_root}/3500.json" ]]; then
  pass "numeric recovery does not require local pct visibility"
else
  fail "numeric recovery does not require local pct visibility"
fi
MOVE_STATE_FILE=""
assert_success "hostname moved CT resolves from transaction state" resolve_move_state_input moved.example
if [[ "$CTID" == 3500 && "$MOVE_STATE_FILE" == "${transaction_root}/3500.json" ]]; then
  pass "hostname recovery does not require local pct visibility"
else
  fail "hostname recovery does not require local pct visibility"
fi
MOVE_STATE_ROOT="${TEST_ROOT}/move-state"
CTID=2200
CT_HOSTNAME=app.thesaints.home

move_commands="${TEST_ROOT}/move-commands"
remote() {
  printf '%s\n' "$*" >> "$move_commands"
  case "$*" in
    *"config --format json"*)
      printf '%s\n' '{"services":{"frigate-config-cpu":{"container_name":"frigate-config-cpu","restart":"no"},"frigate-cpu":{"container_name":"frigate-cpu","restart":"always"}}}'
      ;;
    *".State.Status"*"frigate-cpu"*) printf '%s\n' running ;;
  esac
}
target_ct_exec --timeout 30 2200 "echo target"
if grep -Fq "timeout 30 pct exec '2200' -- sh -c echo\\ target" "$move_commands"; then
  pass "target CT executor preserves timeout and CTID"
else
  cat "$move_commands" >&2
  fail "target CT executor preserves timeout and CTID"
fi

: > "$move_commands"
reconcile_compose_permissions() { echo "reconcile $*" >> "$move_commands"; }
if verify_target_services; then
  mapfile -t move_steps < "$move_commands"
  if [[ "${move_steps[0]}" == *"docker compose config --format json"* \
    && "${move_steps[1]}" == "reconcile 2200" \
    && "${move_steps[2]}" == *"docker compose up -d"* ]] \
    && [[ "$(grep -c "docker inspect.*frigate-cpu" "$move_commands")" -eq 2 ]] \
    && ! grep -q "docker inspect.*frigate-config-cpu" "$move_commands"; then
    pass "target verifies the selected runtime after permissions and startup"
  else
    cat "$move_commands" >&2
    fail "target verifies the selected runtime after permissions and startup"
  fi
else
  fail "target verifies the selected runtime after permissions and startup"
fi

rollback_commands="${TEST_ROOT}/rollback-commands"
ORIGINAL_MOUNT_KEYS=(mp0)
ORIGINAL_MOUNT_VALUES=("/mnt/docker/app.thesaints.home,mp=/mnt/docker")
SOURCE_NODE=pve01
TARGET_NODE=pve02
CTID=2200
COMMITTED=false
MIGRATED=false
MOUNT_TRANSACTION_STARTED=true
TARGET_DIRS_CREATED=true
ORIGINAL_STATUS=stopped
get_ct_owner_node() { echo pve01; }
pct() {
  printf 'source-pct %s\n' "$*" >> "$rollback_commands"
  [[ "$*" != *"-mp0"* ]]
}
remote() { printf 'remote %s\n' "$*" >> "$rollback_commands"; }
restore_original_gpu_config() { return 0; }
move_status_cleanup() { return 0; }
reconcile_source_bridge_after_migration() { return 0; }
ensure_source_mounts_restored() { restore_source_mounts; }
run_failed_source_restore() (
  set +e
  false
  rollback
)
assert_failure_contains "failed source mount restoration is reported" "bind mounts could not be restored" \
  run_failed_source_restore
if ! grep -Fq 'rm -rf' "$rollback_commands"; then
  pass "failed source mount restoration retains target data"
else
  cat "$rollback_commands" >&2
  fail "failed source mount restoration retains target data"
fi

: > "$rollback_commands"
ensure_source_mounts_restored() { MOUNT_TRANSACTION_STARTED=false; return 0; }
get_ct_status() { echo stopped; }
MOVE_STATE_FILE="${MOVE_STATE_ROOT}/2200.json"
printf '{}\n' >"$MOVE_STATE_FILE"
MOUNT_TRANSACTION_STARTED=false
TARGET_DIRS_CREATED=true
get_ct_owner_node() { echo pve01; }
pct() { return 0; }
remote() { return 1; }
run_unreachable_target_rollback() (
  set +e
  rollback 1
)
assert_failure_contains "unreachable target cleanup is reported" "retaining transaction state" \
  run_unreachable_target_rollback
if [[ -f "$MOVE_STATE_FILE" ]]; then
  pass "unconfirmed target cleanup retains resumable transaction state"
else
  fail "unconfirmed target cleanup retains resumable transaction state"
fi

: > "$rollback_commands"
MOVE_STATE_FILE="${MOVE_STATE_ROOT}/2200.json"
printf '{}\n' >"$MOVE_STATE_FILE"
TARGET_DIRS_CREATED=true
get_ct_owner_node() { echo pve01; }
pct() { return 0; }
remote() { return 0; }
reconcile_source_bridge_after_migration() { return 0; }
run_explicit_abort() (
  set +e
  rollback 0
)
if run_explicit_abort >"${TEST_ROOT}/explicit-abort-output" 2>&1 \
  && grep -Fq "Rollback completed" "${TEST_ROOT}/explicit-abort-output"; then
  pass "successful explicit abort exits successfully"
else
  cat "${TEST_ROOT}/explicit-abort-output" >&2
  fail "successful explicit abort exits successfully"
fi

: > "$rollback_commands"
MIGRATED=true
MOUNT_TRANSACTION_STARTED=true
TARGET_MOUNTS_ATTACHED=true
get_ct_owner_node() { echo pve02; }
reconcile_source_bridge_after_migration() { return 0; }
ensure_source_mounts_restored() {
  echo "source-pct set 2200 -mp0 ${ORIGINAL_MOUNT_VALUES[0]}" >> "$rollback_commands"
  MOUNT_TRANSACTION_STARTED=false
}
pct() {
  if [[ "$1" == config ]]; then
    printf 'net0: name=eth0,bridge=vmbr1,type=veth\n'
    return 0
  fi
  printf 'source-pct %s\n' "$*" >> "$rollback_commands"
  return 0
}
remote() {
  printf 'remote %s\n' "$*" >> "$rollback_commands"
  return 0
}
sync_back_to_source() { echo 'sync-back' >> "$rollback_commands"; }
run_target_rollback() (
  set +e
  false
  rollback
)
set +e
rollback_output=$(run_target_rollback 2>&1)
rollback_status=$?
set -e
if [[ "$rollback_status" -eq 1 && "$rollback_output" == *"Rollback completed"* ]]; then
  pass "target-owned rollback completes with original failure status"
else
  printf '%s\n' "$rollback_output" >&2
  fail "target-owned rollback completes with original failure status"
fi
delete_line=$(grep -n "remote pct set '2200' -delete 'mp0'" "$rollback_commands" | cut -d: -f1)
migrate_line=$(grep -n "remote pct migrate '2200' 'pve01'" "$rollback_commands" | cut -d: -f1)
restore_line=$(grep -n 'source-pct set 2200 -mp0' "$rollback_commands" | cut -d: -f1)
cleanup_line=$(grep -n 'remote rm -rf' "$rollback_commands" | cut -d: -f1)
if [[ -n "$delete_line" && -n "$migrate_line" && -n "$restore_line" && -n "$cleanup_line" \
  && "$delete_line" -lt "$migrate_line" && "$migrate_line" -lt "$restore_line" \
  && "$restore_line" -lt "$cleanup_line" ]]; then
  pass "rollback detaches, reverse-migrates, restores, then cleans up"
else
  cat "$rollback_commands" >&2
  fail "rollback detaches, reverse-migrates, restores, then cleans up"
fi
if ! grep -Fq -- "--target-bridge" "$rollback_commands" \
  && grep -Fq -- "remote pct migrate '2200' 'pve01' --target-storage local-lvm:local-lvm" "$rollback_commands"; then
  pass "reverse migration avoids unsupported bridge remap flags"
else
  cat "$rollback_commands" >&2
  fail "reverse migration avoids unsupported bridge remap flags"
fi

echo "${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]