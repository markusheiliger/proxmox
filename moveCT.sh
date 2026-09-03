#!/usr/bin/env bash
# Move one Docker LXC CT between Proxmox nodes, including its local bind data.
# Documentation: moveCT.md
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/commonCT.sh"

TARGET_NODE=""
SOURCE_NODE="$(hostname -s)"
DRY_RUN=false
FORCE=false
MOVE_ACTION="move"
ORIGINAL_STATUS=""
ORIGINAL_GPU_CONFIG=""
EXPECTED_SERVICES=""
MIGRATED=false
TARGET_DIRS_CREATED=false
COMMITTED=false
MOUNT_TRANSACTION_STARTED=false
TARGET_MOUNTS_ATTACHED=false
declare -a ORIGINAL_MOUNT_KEYS=()
declare -a ORIGINAL_MOUNT_VALUES=()
declare -a ORIGINAL_NETWORK_KEYS=()
declare -a ORIGINAL_NETWORK_VALUES=()
SOURCE_BRIDGE=""
SOURCE_BRIDGE_REASON=""
TARGET_BRIDGE=""
TARGET_BRIDGE_REASON=""
DIR_DOCKER=""
DIR_DOCKER_DATA=""
BACKUP_SEED_GENERATION=""
BACKUP_SEED_AGE_SECONDS=""
BACKUP_SEED_MAX_AGE_SECONDS=93600
MOVE_TUI_ENABLED=false
MOVE_TOTAL_STEPS=12
MOVE_STATE_ROOT="${MOVE_STATE_ROOT:-/etc/pve/priv/moveCT}"
MOVE_LOCK_ROOT="${MOVE_LOCK_ROOT:-/run/lock/moveCT}"
MOVE_STATE_FILE=""
MOVE_STATE_LOCK_FILE=""
MOVE_STATE_LOCK_FD=""
MOVE_PHASE=""
MOVE_STATE_REVISION=0
MOVE_TASK_UPID=""
MOVE_TASK_NODE=""
MOVE_LAST_SIGNAL=""
MIGRATION_BWLIMIT_KIB=""
MIGRATION_ESTIMATE_SECONDS=""
MOVE_COORDINATOR_BASHPID=""
ROLLBACK_IN_PROGRESS=false
MOVE_SUBMISSION_PID=""
MOVE_SUBMISSION_LOG=""

phase_rank() {
  case "${1:-}" in
    initialized) echo 0 ;; source_network_reconciled) echo 1 ;; target_prepared) echo 2 ;; seeded) echo 3 ;;
    live_sync_complete) echo 4 ;; stopped_sync_complete) echo 5 ;; data_verified) echo 6 ;;
    mounts_detached) echo 7 ;; migration_submitted) echo 8 ;; migration_complete) echo 9 ;;
    target_network_reconciled) echo 10 ;; mounts_restored) echo 11 ;; services_verified) echo 12 ;;
    dns_verified) echo 13 ;; committed) echo 14 ;; *) echo -1 ;;
  esac
}

phase_before() {
  (( $(phase_rank "$MOVE_PHASE") < $(phase_rank "$1") ))
}

move_state_path() {
  printf '%s/%s.json\n' "$MOVE_STATE_ROOT" "$1"
}

acquire_move_state_lock() {
  mkdir -p "$MOVE_STATE_ROOT"
  [[ "$MOVE_STATE_ROOT" == /etc/pve/* ]] || chmod 0700 "$MOVE_STATE_ROOT"
  install -d -m 0700 "$MOVE_LOCK_ROOT"
  MOVE_STATE_LOCK_FILE="${MOVE_LOCK_ROOT}/${CTID}.lock"
  exec {MOVE_STATE_LOCK_FD}>"$MOVE_STATE_LOCK_FILE"
  flock -n "$MOVE_STATE_LOCK_FD" || abort_move "Another move transaction controls CT ${CTID}."
}

save_move_state() {
  [[ -n "$MOVE_STATE_FILE" ]] || return 0
  local temporary keys_json values_json network_keys_json network_values_json
  MOVE_STATE_REVISION=$((MOVE_STATE_REVISION + 1))
  temporary="${MOVE_STATE_FILE}.tmp.$$"
  keys_json=$(printf '%s\n' "${ORIGINAL_MOUNT_KEYS[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')
  values_json=$(printf '%s\n' "${ORIGINAL_MOUNT_VALUES[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')
  network_keys_json=$(printf '%s\n' "${ORIGINAL_NETWORK_KEYS[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')
  network_values_json=$(printf '%s\n' "${ORIGINAL_NETWORK_VALUES[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')
  jq -n \
    --argjson revision "$MOVE_STATE_REVISION" --arg phase "$MOVE_PHASE" \
    --arg ctid "$CTID" --arg hostname "$CT_HOSTNAME" \
    --arg source "$SOURCE_NODE" --arg target "$TARGET_NODE" \
    --arg original_status "$ORIGINAL_STATUS" --arg original_gpu "$ORIGINAL_GPU_CONFIG" \
    --arg expected_services "$EXPECTED_SERVICES" \
    --arg docker "$DIR_DOCKER" --arg docker_data "$DIR_DOCKER_DATA" \
    --arg seed "$BACKUP_SEED_GENERATION" --arg upid "$MOVE_TASK_UPID" \
    --arg task_node "$MOVE_TASK_NODE" --arg signal "$MOVE_LAST_SIGNAL" \
    --arg bwlimit "$MIGRATION_BWLIMIT_KIB" --arg estimate "$MIGRATION_ESTIMATE_SECONDS" \
    --argjson mount_keys "$keys_json" --argjson mount_values "$values_json" \
    --arg source_bridge "$SOURCE_BRIDGE" --arg source_bridge_reason "$SOURCE_BRIDGE_REASON" \
    --arg target_bridge "$TARGET_BRIDGE" --arg target_bridge_reason "$TARGET_BRIDGE_REASON" \
    --argjson network_keys "$network_keys_json" --argjson network_values "$network_values_json" \
    '{schema:2,revision:$revision,phase:$phase,ctid:$ctid,hostname:$hostname,
      source_node:$source,target_node:$target,original_status:$original_status,
      original_gpu_config:$original_gpu,
      expected_services:$expected_services,paths:{docker:$docker,docker_data:$docker_data},
      backup_seed:$seed,mount_keys:$mount_keys,mount_values:$mount_values,
      network:{original_keys:$network_keys,original_values:$network_values,
        source_bridge:$source_bridge,source_reason:$source_bridge_reason,
        target_bridge:$target_bridge,target_reason:$target_bridge_reason},
      migration:{task_node:$task_node,upid:$upid,bwlimit_kib:$bwlimit,estimate_seconds:$estimate},
      last_signal:$signal,updated_at:(now|todateiso8601)}' >"$temporary"
  [[ "$MOVE_STATE_ROOT" == /etc/pve/* ]] || chmod 0600 "$temporary"
  mv "$temporary" "$MOVE_STATE_FILE"
}

checkpoint_move() {
  MOVE_PHASE="$1"
  MOVE_LAST_SIGNAL=""
  save_move_state
  echo "  [✓] Move checkpoint: ${MOVE_PHASE} (revision ${MOVE_STATE_REVISION})"
}

load_move_state() {
  MOVE_STATE_FILE=$(move_state_path "$CTID")
  [[ -f "$MOVE_STATE_FILE" ]] || abort_move "No resumable move transaction exists for CT ${CTID}."
  jq -e '.schema == 2 and (.revision | type == "number")
    and (.network.source_bridge | test("^vmbr[0-9]+$"))
    and (.network.target_bridge | test("^vmbr[0-9]+$"))' "$MOVE_STATE_FILE" >/dev/null \
    || abort_move "Move state is invalid: ${MOVE_STATE_FILE}"
  MOVE_STATE_REVISION=$(jq -r '.revision' "$MOVE_STATE_FILE")
  MOVE_PHASE=$(jq -r '.phase' "$MOVE_STATE_FILE")
  CT_HOSTNAME=$(jq -r '.hostname' "$MOVE_STATE_FILE")
  SOURCE_NODE=$(jq -r '.source_node' "$MOVE_STATE_FILE")
  TARGET_NODE=$(jq -r '.target_node' "$MOVE_STATE_FILE")
  ORIGINAL_STATUS=$(jq -r '.original_status' "$MOVE_STATE_FILE")
  ORIGINAL_GPU_CONFIG=$(jq -r '.original_gpu_config // ""' "$MOVE_STATE_FILE")
  EXPECTED_SERVICES=$(jq -r '.expected_services' "$MOVE_STATE_FILE")
  DIR_DOCKER=$(jq -r '.paths.docker' "$MOVE_STATE_FILE")
  DIR_DOCKER_DATA=$(jq -r '.paths.docker_data' "$MOVE_STATE_FILE")
  BACKUP_SEED_GENERATION=$(jq -r '.backup_seed' "$MOVE_STATE_FILE")
  MOVE_TASK_UPID=$(jq -r '.migration.upid' "$MOVE_STATE_FILE")
  MOVE_TASK_NODE=$(jq -r '.migration.task_node' "$MOVE_STATE_FILE")
  MIGRATION_BWLIMIT_KIB=$(jq -r '.migration.bwlimit_kib' "$MOVE_STATE_FILE")
  MIGRATION_ESTIMATE_SECONDS=$(jq -r '.migration.estimate_seconds' "$MOVE_STATE_FILE")
  mapfile -t ORIGINAL_MOUNT_KEYS < <(jq -r '.mount_keys[]' "$MOVE_STATE_FILE")
  mapfile -t ORIGINAL_MOUNT_VALUES < <(jq -r '.mount_values[]' "$MOVE_STATE_FILE")
  mapfile -t ORIGINAL_NETWORK_KEYS < <(jq -r '.network.original_keys[]' "$MOVE_STATE_FILE")
  mapfile -t ORIGINAL_NETWORK_VALUES < <(jq -r '.network.original_values[]' "$MOVE_STATE_FILE")
  SOURCE_BRIDGE=$(jq -r '.network.source_bridge' "$MOVE_STATE_FILE")
  SOURCE_BRIDGE_REASON=$(jq -r '.network.source_reason' "$MOVE_STATE_FILE")
  TARGET_BRIDGE=$(jq -r '.network.target_bridge' "$MOVE_STATE_FILE")
  TARGET_BRIDGE_REASON=$(jq -r '.network.target_reason' "$MOVE_STATE_FILE")
  TARGET_DIRS_CREATED=true
  [[ $(phase_rank "$MOVE_PHASE") -lt $(phase_rank mounts_detached) ]] || MOUNT_TRANSACTION_STARTED=true
  [[ $(phase_rank "$MOVE_PHASE") -lt $(phase_rank migration_complete) ]] || MIGRATED=true
  [[ $(phase_rank "$MOVE_PHASE") -lt $(phase_rank mounts_restored) ]] || TARGET_MOUNTS_ATTACHED=true
  [[ "$MOVE_PHASE" != committed ]] || COMMITTED=true
}

move_signal_handler() {
  local signal="$1" code="$2"
  trap - HUP INT TERM
  MOVE_LAST_SIGNAL="$signal"
  save_move_state || true
  echo "[!] Move interrupted by ${signal}; transaction checkpoint retained for --resume." >&2
  move_status_cleanup
  exit "$code"
}

move_status_init() {
  [[ -t 0 && -t 1 ]] || return 0
  status_bar_init
  MOVE_TUI_ENABLED=true
}

move_status_progress() {
  [[ "$MOVE_TUI_ENABLED" == "true" ]] || return 0
  status_progress "$1" "$MOVE_TOTAL_STEPS" "$2" >/dev/tty 2>/dev/null || true
}

move_status_cleanup() {
  [[ "$MOVE_TUI_ENABLED" == "true" ]] || return 0
  status_bar_cleanup >/dev/tty 2>/dev/null || true
  MOVE_TUI_ENABLED=false
}

abort_move() {
  echo "ERROR: $*" >&2
  return 1
}

usage() {
  cat <<'EOF'
Usage: moveCT.sh [CTID|hostname] [--node NODE] [--dry-run] [--force]
  moveCT.sh --status CTID|hostname
  moveCT.sh --resume CTID|hostname [--force]
  moveCT.sh --abort CTID|hostname [--force]

Moves one LXC CT and its /mnt/docker/<hostname> and
/mnt/docker-data/<hostname> trees to another online Proxmox node.

  --node NODE              Destination node (interactive when omitted)
  --dry-run                Validate and print the transaction without changes
  --force                  Skip the final confirmation
  --status CT              Reconcile saved transaction and live task state
  --resume CT              Continue a saved transaction from its checkpoint
  --abort CT               Explicitly roll a saved transaction back when safe
EOF
}

remote() {
  ssh -o BatchMode=yes -o ConnectTimeout=10 \
    -o ServerAliveInterval=5 -o ServerAliveCountMax=3 "$TARGET_NODE" "$@"
}

run_on_node() {
  local node="${1:-}" argument quoted command=""
  shift || true
  if [[ "$node" == "$SOURCE_NODE" ]]; then
    "$@"
    return
  fi
  if [[ "$node" == "$TARGET_NODE" ]]; then
    for argument in "$@"; do
      printf -v quoted '%q' "$argument"
      command+="${command:+ }${quoted}"
    done
    remote "$command"
    return
  fi
  echo "ERROR: Move command requested for unexpected node '${node}'." >&2
  return 1
}

# Match ct_exec's calling convention while executing against the target node.
target_ct_exec() {
  local ct_timeout="" ctid cmd quoted_cmd command_prefix=""
  if [[ "${1:-}" == "--timeout" ]]; then
    ct_timeout="$2"
    shift 2
  fi
  ctid="$1"
  shift
  cmd="$*"
  printf -v quoted_cmd '%q' "$cmd"
  [[ -z "$ct_timeout" ]] || command_prefix="timeout ${ct_timeout} "
  remote "${command_prefix}pct exec '${ctid}' -- sh -c ${quoted_cmd}"
}

collect_device_requirements() {
  local compose_json="" source service
  DEVICE_REQUIREMENTS=()

  if [[ "$ORIGINAL_STATUS" == "running" ]]; then
    compose_json=$(ct_exec --timeout 30 "$CTID" \
      'cd /mnt/docker && docker compose config --format json' 2>/dev/null || true)
  fi

  if [[ -n "$compose_json" ]] && jq -e '.services' >/dev/null 2>&1 <<< "$compose_json"; then
    while IFS= read -r source; do
      [[ -n "$source" && "$source" != "null" ]] && DEVICE_REQUIREMENTS+=("$source")
    done < <(jq -r '
      .services | to_entries[] | .key as $service
      | .value.devices[]?
      | if type == "string" then split(":")[0] else (.source // empty) end
      | "\($service)\t\(.)"' <<< "$compose_json")

    while IFS= read -r source; do
      [[ -n "$source" ]] && DEVICE_REQUIREMENTS+=("$source")
    done < <(jq -r '
      .services | to_entries[] | .key as $service
      | select((.value.runtime // "") == "nvidia"
          or any(.value.deploy.resources.reservations.devices[]?; any(.capabilities[]?; . == "gpu")))
      | "\($service)\tGPU_REQUEST"' <<< "$compose_json")
  else
    # The fallback is intentionally limited to YAML list items whose value
    # starts with /dev. Searching every /dev token also mistakes command
    # redirections such as ">/dev/null" for host-device mappings.
    while IFS=$'\t' read -r service source; do
      [[ -n "$source" ]] && DEVICE_REQUIREMENTS+=("${service}"$'\t'"${source}")
    done < <(awk '
      /^[^[:space:]#][^:]*:[[:space:]]*$/ {
        if ($0 == "services:") { in_services = 1; next }
        if (in_services) { in_services = 0 }
      }
      in_services && /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ {
        service = $1
        sub(/:$/, "", service)
        in_devices = 0
        next
      }
      in_services && /^    devices:[[:space:]]*$/ { in_devices = 1; next }
      in_services && /^    [A-Za-z0-9_.-]+:/ { in_devices = 0 }
      in_services && in_devices && /^[[:space:]]*-[[:space:]]*\/dev\// {
        value = $0
        sub(/^[[:space:]]*-[[:space:]]*/, "", value)
        sub(/[[:space:]#].*$/, "", value)
        split(value, fields, ":")
        print service "\t" fields[1]
      }
    ' "$DIR_DOCKER/docker-compose.yaml" 2>/dev/null | sort -u || true)
  fi
}

validate_target_devices() {
  local requirement service source
  local failures=()
  collect_device_requirements

  for requirement in "${DEVICE_REQUIREMENTS[@]}"; do
    service="${requirement%%$'\t'*}"
    source="${requirement#*$'\t'}"
    if [[ "$source" == "GPU_REQUEST" ]]; then
      [[ "$NODE_GPU_STATE" == "available" ]] || failures+=("${service}: requests a GPU")
      continue
    fi
    if [[ "$source" == "/dev/bus/usb" ]]; then
      failures+=("${service}: maps /dev/bus/usb; USB device identity cannot be proven on another node")
      continue
    fi
    if ! remote "test -e '$source'" 2>/dev/null; then
      failures+=("${service}: target device '${source}' is missing")
    fi
  done

  if [[ ${#failures[@]} -gt 0 ]]; then
    echo "ERROR: Target device compatibility failed:" >&2
    printf '  - %s\n' "${failures[@]}" >&2
    return 1
  fi
}

resolve_move_bridge_contracts() {
  bridge_policy_resolve "$SOURCE_NODE" CT "$CTID" "$CT_HOSTNAME" || return 1
  SOURCE_BRIDGE="$BRIDGE_POLICY_SELECTED"
  SOURCE_BRIDGE_REASON="$BRIDGE_POLICY_REASON"
  bridge_policy_resolve "$TARGET_NODE" CT "$CTID" "$CT_HOSTNAME" || return 1
  TARGET_BRIDGE="$BRIDGE_POLICY_SELECTED"
  TARGET_BRIDGE_REASON="$BRIDGE_POLICY_REASON"
  echo "Network contract '${SOURCE_NODE}': ${SOURCE_BRIDGE} (${SOURCE_BRIDGE_REASON})"
  bridge_policy_reconcile_guest "$SOURCE_NODE" CT "$CTID" "$SOURCE_BRIDGE" true || return 1
  echo "Network contract '${TARGET_NODE}': ${TARGET_BRIDGE} (${TARGET_BRIDGE_REASON})"
  # Preview destination rewriting from the current source-side NIC definitions.
  bridge_policy_reconcile_guest "$SOURCE_NODE" CT "$CTID" "$TARGET_BRIDGE" true || return 1
}

capture_original_networks() {
  local line key value
  ORIGINAL_NETWORK_KEYS=()
  ORIGINAL_NETWORK_VALUES=()
  while IFS= read -r line; do
    key="${line%%:*}"
    value="${line#*: }"
    ORIGINAL_NETWORK_KEYS+=("$key")
    ORIGINAL_NETWORK_VALUES+=("$value")
  done < <(pct config "$CTID" 2>/dev/null | grep -E '^net[0-9]+:' || true)
  (( ${#ORIGINAL_NETWORK_KEYS[@]} > 0 )) || {
    echo "ERROR: CT ${CTID} has no netN devices to migrate." >&2
    return 1
  }
}

validate_move_node_contracts() {
  local node="$1" additional_rootfs_gib="$2"
  echo "Contract validation '${node}'"
  CONTRACT_NODE_HEADER_ACTIVE=true validate_node_storage_contract "$node" || return 1
  CONTRACT_NODE_HEADER_ACTIVE=true validate_rootfs_target_capacity \
    "$node" "$additional_rootfs_gib" 20 || return 1
  CONTRACT_NODE_HEADER_ACTIVE=true validate_os_root_headroom "$node" 20 || return 1
}

validate_ct_storage_scope() {
  local line key value source storage
  local failures=()
  local docker_mount=false docker_data_mount=false

  while IFS= read -r line; do
    key="${line%%:*}"
    value="${line#*: }"
    source="${value%%,*}"
    if [[ "$source" == /* ]]; then
      case "$source" in
        "$DIR_DOCKER")
          if [[ ",$value," == *,mp=/mnt/docker,* ]]; then
            docker_mount=true
          else
            failures+=("${key}: '${source}' must map to /mnt/docker")
          fi
          ;;
        "$DIR_DOCKER_DATA")
          if [[ ",$value," == *,mp=/mnt/docker-data,* ]]; then
            docker_data_mount=true
          else
            failures+=("${key}: '${source}' must map to /mnt/docker-data")
          fi
          ;;
        *) failures+=("${key}: unsupported bind mount '${source}'") ;;
      esac
    else
      storage="${source%%:*}"
      if [[ "$key" == "rootfs" ]]; then
        [[ "$storage" == "local-lvm" ]] \
          || failures+=("${key}: must use managed storage 'local-lvm' (found '${storage}')")
      else
        failures+=("${key}: unsupported managed mount storage '${storage}'")
      fi
    fi
  done < <(pct config "$CTID" 2>/dev/null | grep -E '^(rootfs|mp[0-9]+):' || true)

  [[ "$docker_mount" == true ]] \
    || failures+=("required bind mount '${DIR_DOCKER},mp=/mnt/docker' is missing")
  [[ "$docker_data_mount" == true ]] \
    || failures+=("required bind mount '${DIR_DOCKER_DATA},mp=/mnt/docker-data' is missing")

  if [[ ${#failures[@]} -gt 0 ]]; then
    echo "ERROR: CT storage layout is outside moveCT scope:" >&2
    printf '  - %s\n' "${failures[@]}" >&2
    return 1
  fi
}

capture_original_mounts() {
  local line key value
  ORIGINAL_MOUNT_KEYS=()
  ORIGINAL_MOUNT_VALUES=()
  while IFS= read -r line; do
    key="${line%%:*}"
    value="${line#*: }"
    ORIGINAL_MOUNT_KEYS+=("$key")
    ORIGINAL_MOUNT_VALUES+=("$value")
  done < <(pct config "$CTID" 2>/dev/null | grep -E '^mp[0-9]+:' || true)
}

validate_mounts_unchanged() {
  local index expected="" current
  for index in "${!ORIGINAL_MOUNT_KEYS[@]}"; do
    expected+="${ORIGINAL_MOUNT_KEYS[$index]}: ${ORIGINAL_MOUNT_VALUES[$index]}"$'\n'
  done
  expected="${expected%$'\n'}"
  current=$(pct config "$CTID" 2>/dev/null | grep -E '^mp[0-9]+:' || true)
  if [[ "$current" != "$expected" ]]; then
    echo "ERROR: CT bind mount configuration changed during pre-copy; refusing migration." >&2
    return 1
  fi
}

detach_source_mounts() {
  local key
  validate_mounts_unchanged || return 1
  MOUNT_TRANSACTION_STARTED=true
  for key in "${ORIGINAL_MOUNT_KEYS[@]}"; do
    if pct config "$CTID" 2>/dev/null | grep -qE "^${key}:"; then
      echo "  Detaching ${key} for rootfs migration"
      pct set "$CTID" -delete "$key" || return 1
    fi
  done
}

restore_source_mounts() {
  local index key value
  for index in "${!ORIGINAL_MOUNT_KEYS[@]}"; do
    key="${ORIGINAL_MOUNT_KEYS[$index]}"
    value="${ORIGINAL_MOUNT_VALUES[$index]}"
    echo "  Restoring ${key} on ${SOURCE_NODE}"
    pct set "$CTID" "-${key}" "$value" || return 1
  done
  MOUNT_TRANSACTION_STARTED=false
}

ensure_source_mounts_restored() {
  local index key expected current
  for index in "${!ORIGINAL_MOUNT_KEYS[@]}"; do
    key="${ORIGINAL_MOUNT_KEYS[$index]}"
    expected="${ORIGINAL_MOUNT_VALUES[$index]}"
    current=$(pct config "$CTID" 2>/dev/null | sed -n "s/^${key}:[[:space:]]*//p" || true)
    if [[ "$current" != "$expected" ]]; then
      echo "  Restoring ${key} on ${SOURCE_NODE}"
      pct set "$CTID" "-${key}" "$expected" || return 1
    fi
  done
  for index in "${!ORIGINAL_MOUNT_KEYS[@]}"; do
    key="${ORIGINAL_MOUNT_KEYS[$index]}"
    expected="${ORIGINAL_MOUNT_VALUES[$index]}"
    current=$(pct config "$CTID" 2>/dev/null | sed -n "s/^${key}:[[:space:]]*//p" || true)
    [[ "$current" == "$expected" ]] || {
      echo "ERROR: Source mount ${key} does not match its original value after restoration." >&2
      return 1
    }
  done
  MOUNT_TRANSACTION_STARTED=false
}

restore_target_mounts() {
  local index key value quoted_value
  for index in "${!ORIGINAL_MOUNT_KEYS[@]}"; do
    key="${ORIGINAL_MOUNT_KEYS[$index]}"
    value="${ORIGINAL_MOUNT_VALUES[$index]}"
    printf -v quoted_value '%q' "$value"
    echo "  Restoring ${key} on ${TARGET_NODE}"
    remote "pct set '$CTID' '-${key}' ${quoted_value}" || return 1
  done
  TARGET_MOUNTS_ATTACHED=true
}

detach_target_mounts() {
  local key
  for key in "${ORIGINAL_MOUNT_KEYS[@]}"; do
    if remote "pct config '$CTID' | grep -qE '^${key}:'"; then
      echo "  Detaching ${key} on ${TARGET_NODE} for reverse migration"
      remote "pct set '$CTID' -delete '$key'" || return 1
    fi
  done
  TARGET_MOUNTS_ATTACHED=false
}

get_ct_rootfs_size_gib() {
  local rootfs size
  rootfs=$(pct config "$CTID" 2>/dev/null | sed -n 's/^rootfs:[[:space:]]*//p')
  size=$(sed -nE 's/.*(^|,)size=([0-9]+([.][0-9]+)?)([KMGT]).*/\2 \4/p' <<< "$rootfs")
  [[ -n "$size" ]] || { echo "ERROR: Cannot determine rootfs size for CT ${CTID}." >&2; return 1; }
  awk '$2 == "K" { print $1 / 1048576 }
       $2 == "M" { print $1 / 1024 }
       $2 == "G" { print $1 }
       $2 == "T" { print $1 * 1024 }' <<< "$size"
}

parse_migration_bwlimit_kib() {
  local policy="${1:-}" part default_limit="" migration_limit=""
  local -a parts=()
  policy="${policy// /}"
  IFS=',' read -ra parts <<< "$policy"
  for part in "${parts[@]}"; do
    case "$part" in
      migration=*) migration_limit="${part#*=}" ;;
      default=*) default_limit="${part#*=}" ;;
    esac
  done
  if [[ "$migration_limit" =~ ^[0-9]+$ ]]; then
    echo "$migration_limit"
  elif [[ "$default_limit" =~ ^[0-9]+$ ]]; then
    echo "$default_limit"
  fi
}

inspect_migration_bandwidth() {
  local rootfs_gib="$1" options policy
  options=$(pvesh get /cluster/options --output-format json 2>/dev/null || true)
  policy=$(jq -r '.bwlimit // empty' <<< "$options" 2>/dev/null || true)
  MIGRATION_BWLIMIT_KIB=$(parse_migration_bwlimit_kib "$policy")
  MIGRATION_ESTIMATE_SECONDS=""
  if [[ "$MIGRATION_BWLIMIT_KIB" =~ ^[0-9]+$ ]] && (( MIGRATION_BWLIMIT_KIB > 0 )); then
    MIGRATION_ESTIMATE_SECONDS=$(awk -v gib="$rootfs_gib" -v kib="$MIGRATION_BWLIMIT_KIB" \
      'BEGIN { printf "%.0f", (gib * 1024 * 1024) / kib }')
    printf 'Migration bandwidth policy: %s KiB/s; rootfs transfer floor: %dh %02dm.\n' \
      "$MIGRATION_BWLIMIT_KIB" "$((MIGRATION_ESTIMATE_SECONDS / 3600))" "$(((MIGRATION_ESTIMATE_SECONDS % 3600) / 60))"
  elif [[ "$MIGRATION_BWLIMIT_KIB" == "0" ]]; then
    echo "Migration bandwidth policy: unlimited; duration cannot be predicted."
  else
    echo "Migration bandwidth policy: not reported; duration cannot be predicted."
  fi
}

confirm_slow_migration() {
  local answer
  [[ "$MIGRATION_ESTIMATE_SECONDS" =~ ^[0-9]+$ ]] || return 0
  (( MIGRATION_ESTIMATE_SECONDS > 21600 )) || return 0
  [[ "$FORCE" != "true" ]] || return 0
  read -rp "The configured migration limit implies more than six hours. Continue anyway? [y/N]: " answer
  [[ "$answer" =~ ^[Yy]$ ]] || abort_move "Move cancelled because of the restrictive migration bandwidth policy."
}

select_new_migration_upid() {
  local tasks_json="${1:-}" previous_upid="${2:-}"
  jq -er --arg previous "$previous_upid" '
    [.[]
      | select(.type == "vzmigrate")
      | select((.upid // "") != $previous)]
    | sort_by(.starttime // 0)
    | last
    | .upid
    | select(type == "string" and startswith("UPID:") and endswith(":"))
  ' <<< "$tasks_json" 2>/dev/null
}

query_migration_tasks() {
  local since="$1"
  pvesh get "/nodes/${SOURCE_NODE}/tasks" --vmid "$CTID" \
    --typefilter vzmigrate --source all --since "$since" --limit 20 \
    --output-format json 2>/dev/null
}

submit_migration_task() {
  local previous_tasks previous_upid="" tasks candidate="" attempt launch_status=0
  local started
  MOVE_TASK_NODE="$SOURCE_NODE"
  MOVE_TASK_UPID=""
  started=$(date +%s)
  previous_tasks=$(query_migration_tasks "$((started - 86400))" || true)
  previous_upid=$(jq -r 'sort_by(.starttime // 0) | last | .upid // empty' \
    <<< "$previous_tasks" 2>/dev/null || true)
  MOVE_SUBMISSION_LOG="${MOVE_LOCK_ROOT}/${CTID}.migration-submit.log"
  : > "$MOVE_SUBMISSION_LOG"

  # pvesh intentionally runs workers synchronously in its local CLI environment.
  # Run that waiter separately, then discover and persist the native worker UPID.
  pvesh create "/nodes/${SOURCE_NODE}/lxc/${CTID}/migrate" \
    --target "$TARGET_NODE" --target-storage local-lvm:local-lvm \
    >"$MOVE_SUBMISSION_LOG" 2>&1 &
  MOVE_SUBMISSION_PID=$!

  for attempt in {1..60}; do
    tasks=$(query_migration_tasks "$((started - 5))" || true)
    candidate=$(select_new_migration_upid "$tasks" "$previous_upid" || true)
    if [[ -n "$candidate" ]]; then
      MOVE_TASK_UPID="$candidate"
      checkpoint_move migration_submitted
      echo "  Proxmox migration task: ${MOVE_TASK_UPID}"
      return 0
    fi
    if ! kill -0 "$MOVE_SUBMISSION_PID" 2>/dev/null; then
      if wait "$MOVE_SUBMISSION_PID"; then
        launch_status=0
      else
        launch_status=$?
      fi
      MOVE_SUBMISSION_PID=""
      tasks=$(query_migration_tasks "$((started - 5))" || true)
      candidate=$(select_new_migration_upid "$tasks" "$previous_upid" || true)
      if [[ -n "$candidate" ]]; then
        MOVE_TASK_UPID="$candidate"
        checkpoint_move migration_submitted
        echo "  Proxmox migration task: ${MOVE_TASK_UPID}"
        return 0
      fi
      [[ ! -s "$MOVE_SUBMISSION_LOG" ]] || tail -n 20 "$MOVE_SUBMISSION_LOG" >&2
      abort_move "Proxmox migration task did not start (pvesh status ${launch_status})."
      return 1
    fi
    sleep 1
  done

  MOVE_LAST_SIGNAL="migration-task-discovery-timeout"
  save_move_state || true
  echo "ERROR: Proxmox migration launcher is active, but its UPID could not be discovered." >&2
  echo "       Transaction retained at ${MOVE_STATE_FILE}; do not start or abort another move." >&2
  move_status_cleanup
  exit 1
}

get_migration_task_status() {
  pvesh get "/nodes/${MOVE_TASK_NODE}/tasks/${MOVE_TASK_UPID}/status" --output-format json 2>/dev/null
}

migration_task_running() {
  local status
  [[ -n "$MOVE_TASK_UPID" && -n "$MOVE_TASK_NODE" ]] || return 1
  status=$(get_migration_task_status) || return 1
  [[ $(jq -r '.status // empty' <<< "$status") == running ]]
}

wait_for_migration_task() {
  local status state exit_status
  [[ -n "$MOVE_TASK_UPID" ]] || abort_move "The migration checkpoint has no Proxmox UPID."
  while true; do
    status=$(get_migration_task_status) || abort_move "Cannot read Proxmox task ${MOVE_TASK_UPID}."
    state=$(jq -r '.status // empty' <<< "$status")
    if [[ "$state" == stopped ]]; then
      exit_status=$(jq -r '.exitstatus // empty' <<< "$status")
      [[ "$exit_status" == OK ]] || abort_move "Proxmox migration task failed: ${exit_status:-unknown}."
      if [[ -n "$MOVE_SUBMISSION_PID" ]]; then
        wait "$MOVE_SUBMISSION_PID" || true
        MOVE_SUBMISSION_PID=""
      fi
      [[ -z "$MOVE_SUBMISSION_LOG" ]] || rm -f "$MOVE_SUBMISSION_LOG"
      MIGRATED=true
      checkpoint_move migration_complete
      return 0
    fi
    [[ "$state" == running ]] || abort_move "Proxmox migration task has unexpected status '${state:-missing}'."
    sleep 5
  done
}

sync_to_target() {
  local delete_flag="${1:-false}"
  local options=(-aHAXS --numeric-ids --modify-window=-1 --human-readable --info=progress2,stats1)
  [[ "$delete_flag" == "true" ]] && options+=(--delete)
  rsync "${options[@]}" -e 'ssh -o BatchMode=yes -o ConnectTimeout=10' \
    "${DIR_DOCKER}/" "${TARGET_NODE}:${DIR_DOCKER}/"
  rsync "${options[@]}" -e 'ssh -o BatchMode=yes -o ConnectTimeout=10' \
    "${DIR_DOCKER_DATA}/" "${TARGET_NODE}:${DIR_DOCKER_DATA}/"
}

verify_target_tree() {
  local path="$1" label="$2" differences
  if ! differences=$(rsync -aHAXSnic --delete --modify-window=-1 \
    --out-format='%i %n%L' -e 'ssh -o BatchMode=yes -o ConnectTimeout=10' \
    "${path}/" "${TARGET_NODE}:${path}/"); then
    abort_move "${label} verification could not compare source and target."
  fi
  if [[ -n "$differences" ]]; then
    printf '%s\n' "$differences" >&2
    abort_move "${label} differs after final synchronization."
  fi
}

sync_back_to_source() {
  rsync -aHAXS --numeric-ids --delete --human-readable --info=progress2,stats1 -e 'ssh -o BatchMode=yes -o ConnectTimeout=10' \
    "${TARGET_NODE}:${DIR_DOCKER}/" "${DIR_DOCKER}/"
  rsync -aHAXS --numeric-ids --delete --human-readable --info=progress2,stats1 -e 'ssh -o BatchMode=yes -o ConnectTimeout=10' \
    "${TARGET_NODE}:${DIR_DOCKER_DATA}/" "${DIR_DOCKER_DATA}/"
}

find_backup_seed() {
  local storage mount_path archive stem generation now modified age
  BACKUP_SEED_GENERATION=""
  BACKUP_SEED_AGE_SECONDS=""
  storage=$(config_get_backup_storage 2>/dev/null || true)
  [[ -n "$storage" ]] || return 1
  mount_path="${BACKUP_MOUNT_ROOT:-/mnt/pve}/${storage}"
  [[ -d "${mount_path}/dump" ]] || return 1
  now=$(date +%s)

  while IFS= read -r archive; do
    modified=$(stat -c %Y "$archive" 2>/dev/null || true)
    [[ "$modified" =~ ^[0-9]+$ ]] || continue
    age=$((now - modified))
    (( age >= 0 && age <= BACKUP_SEED_MAX_AGE_SECONDS )) || continue
    stem=$(basename "${archive%.tar.zst}")
    generation="${mount_path}/workloads/${CT_HOSTNAME}/${stem}"
    [[ -d "${generation}/docker" && -d "${generation}/docker-data" ]] || continue
    if remote "test -r '${generation}/docker' -a -r '${generation}/docker-data'"; then
      BACKUP_SEED_GENERATION="$generation"
      BACKUP_SEED_AGE_SECONDS="$age"
      return 0
    fi
  done < <(find "${mount_path}/dump" -maxdepth 1 -type f \
    -name "vzdump-lxc-${CTID}-*.tar.zst" -print 2>/dev/null | sort -r)

  return 1
}

seed_target_from_backup() {
  [[ -n "$BACKUP_SEED_GENERATION" ]] || return 1
  remote "rsync -aHAXS --numeric-ids --delete --human-readable --info=progress2,stats1 '${BACKUP_SEED_GENERATION}/docker/' '${DIR_DOCKER}/' && rsync -aHAXS --numeric-ids --delete --human-readable --info=progress2,stats1 '${BACKUP_SEED_GENERATION}/docker-data/' '${DIR_DOCKER_DATA}/'"
}

reset_target_dirs() {
  remote "rm -rf --one-file-system -- '$DIR_DOCKER' '$DIR_DOCKER_DATA' && mkdir -p '$DIR_DOCKER' '$DIR_DOCKER_DATA'"
}

seed_target_or_fallback() {
  [[ -n "$BACKUP_SEED_GENERATION" ]] || return 0
  echo "Seeding target workload data from $(basename "$BACKUP_SEED_GENERATION")"
  if seed_target_from_backup; then
    return 0
  fi
  echo "[!] Backup seed failed; resetting target paths and using source pre-copy." >&2
  reset_target_dirs
  BACKUP_SEED_GENERATION=""
  BACKUP_SEED_AGE_SECONDS=""
}

restore_original_gpu_config() {
  local config_file="/etc/pve/lxc/${CTID}.conf"
  sed -i \
    -e '\|^lxc.cgroup2.devices.allow: c 226:\* rwm$|d' \
    -e '\|^lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir$|d' \
    "$config_file"
  [[ -n "$ORIGINAL_GPU_CONFIG" ]] && printf '%s\n' "$ORIGINAL_GPU_CONFIG" >> "$config_file"
}

get_ct_owner_node() {
  pvesh get /cluster/resources --type vm --output-format json 2>/dev/null \
    | jq -r --argjson vmid "$CTID" '.[] | select(.type == "lxc" and .vmid == $vmid) | .node' \
    | head -1
}

reconcile_source_bridge_after_migration() {
  local attempt lock=""
  for ((attempt = 1; attempt <= 30; attempt++)); do
    lock=$(pct config "$CTID" 2>/dev/null | sed -n 's/^lock:[[:space:]]*//p' || true)
    if [[ -z "$lock" ]] \
      && bridge_policy_reconcile_guest "$SOURCE_NODE" CT "$CTID" "$SOURCE_BRIDGE"; then
      return 0
    fi
    (( attempt < 30 )) && sleep 2
  done
  echo "ERROR: Source bridge ${SOURCE_BRIDGE} could not be reconciled after waiting for migration cleanup${lock:+ (lock: ${lock})}." >&2
  return 1
}

cleanup_target_dirs() {
  [[ "$TARGET_DIRS_CREATED" == "true" ]] || return 0
  remote "rm -rf --one-file-system -- '$DIR_DOCKER' '$DIR_DOCKER_DATA'"
}

transaction_error_handler() {
  local exit_code=$?
  if [[ -n "$MOVE_COORDINATOR_BASHPID" && "$BASHPID" != "$MOVE_COORDINATOR_BASHPID" ]]; then
    return "$exit_code"
  fi
  rollback "$exit_code"
}

rollback() {
  local caught_exit=$? owner_node
  local exit_code="${1:-$caught_exit}"
  local recovery_failure_code="$exit_code"
  (( recovery_failure_code != 0 )) || recovery_failure_code=1
  trap - ERR
  if [[ "$ROLLBACK_IN_PROGRESS" == "true" ]]; then
    echo "[!] Rollback is already in progress; suppressing duplicate recovery." >&2
    move_status_cleanup
    exit "$exit_code"
  fi
  ROLLBACK_IN_PROGRESS=true
  [[ "$COMMITTED" == "true" ]] && return 0
  if migration_task_running; then
    MOVE_LAST_SIGNAL="failure-while-proxmox-task-running"
    save_move_state || true
    echo "[!] Proxmox migration task ${MOVE_TASK_UPID} is still running; rollback was not attempted." >&2
    echo "    Rerun moveCT.sh --status ${CTID}, then moveCT.sh --resume ${CTID}." >&2
    move_status_cleanup
    exit "$exit_code"
  fi
  move_status_progress 12 "Move failed; rolling back..."
  echo "[!] Move failed; starting rollback." >&2

  owner_node=$(get_ct_owner_node || true)
  if [[ "$owner_node" == "$TARGET_NODE" ]]; then
    remote "pct stop '$CTID' --skiplock 1" >/dev/null 2>&1 || true
    if ! detach_target_mounts; then
      restore_target_mounts || true
      echo "[✗] Could not detach target bind mounts; refusing reverse migration." >&2
      echo "    CT ${CTID} remains owned by ${TARGET_NODE} and stopped." >&2
      move_status_cleanup
      exit "$recovery_failure_code"
    fi
    if ! sync_back_to_source; then
      restore_target_mounts || true
      echo "[✗] Reverse data sync failed; refusing reverse migration and retaining both data copies." >&2
      echo "    CT ${CTID} remains owned by ${TARGET_NODE} and stopped." >&2
      move_status_cleanup
      exit "$recovery_failure_code"
    fi
    # Keep the target-valid bridge in the stopped CT configuration during the
    # reverse migration. Proxmox permits a stopped config to migrate even when
    # that bridge is not present on the destination; reconcile immediately on
    # the source before the CT can start. Do not configure a source-only bridge
    # on the target, and do not rely on a version-specific migration remap flag.
    if ! remote "pct migrate '$CTID' '$SOURCE_NODE' --target-storage local-lvm:local-lvm"; then
      restore_target_mounts || true
      echo "[✗] Automatic reverse migration failed. CT ${CTID} remains owned by ${TARGET_NODE}." >&2
      echo "    Source data: ${DIR_DOCKER}, ${DIR_DOCKER_DATA}" >&2
      echo "    Target data: ${TARGET_NODE}:${DIR_DOCKER}, ${TARGET_NODE}:${DIR_DOCKER_DATA}" >&2
      move_status_cleanup
      exit "$recovery_failure_code"
    fi
    MIGRATED=false
    owner_node="$SOURCE_NODE"
  elif [[ -z "$owner_node" ]]; then
    echo "[✗] CT ${CTID} live ownership is unknown; refusing automatic rollback mutation." >&2
    move_status_cleanup
    exit "$recovery_failure_code"
  elif [[ -n "$owner_node" && "$owner_node" != "$SOURCE_NODE" ]]; then
    echo "[✗] CT ${CTID} ownership is unexpected (${owner_node}); refusing automatic rollback mutation." >&2
    move_status_cleanup
    exit "$recovery_failure_code"
  fi

  # Live ownership is authoritative when resuming a rollback. The saved phase
  # may still say migration_complete/mounts_restored after a prior process
  # successfully reverse-migrated but exited before updating its checkpoint.
  if [[ "$owner_node" == "$SOURCE_NODE" ]]; then
    if ! reconcile_source_bridge_after_migration; then
      echo "[✗] CT ${CTID} is on ${SOURCE_NODE}, but source bridge reconciliation failed." >&2
      echo "    The CT remains stopped; source and target workload data were retained." >&2
      move_status_cleanup
      exit "$recovery_failure_code"
    fi
  fi

  # Always verify source mounts from persisted state. A previous recovery may
  # have reverse-migrated successfully without advancing the saved phase.
  if ! ensure_source_mounts_restored; then
    echo "[✗] CT ${CTID} returned to ${SOURCE_NODE}, but its bind mounts could not be restored." >&2
    echo "    The CT remains stopped; source and target workload data were retained." >&2
    move_status_cleanup
    exit "$recovery_failure_code"
  fi

  restore_original_gpu_config || true
  if [[ "$ORIGINAL_STATUS" == "running" ]]; then
    if [[ "$(get_ct_status "$CTID")" != running ]]; then
      pct start "$CTID" || {
        echo "[✗] CT ${CTID} source configuration was restored, but its original running state could not be restored." >&2
        move_status_cleanup
        exit "$recovery_failure_code"
      }
    fi
    [[ "$(get_ct_status "$CTID")" == running ]] || {
      echo "[✗] CT ${CTID} did not reach its original running state; target data and transaction state were retained." >&2
      move_status_cleanup
      exit "$recovery_failure_code"
    }
  elif [[ "$(get_ct_status "$CTID")" != stopped ]]; then
    echo "[✗] CT ${CTID} did not retain its original stopped state; target data and transaction state were retained." >&2
    move_status_cleanup
    exit "$recovery_failure_code"
  fi
  if ! cleanup_target_dirs; then
    echo "[✗] Target cleanup could not be confirmed; retaining transaction state and both workload copies." >&2
    echo "    Restore connectivity to ${TARGET_NODE}, stop any target rsync, then retry --abort ${CTID}." >&2
    move_status_cleanup
    exit "$recovery_failure_code"
  fi
  move_status_cleanup
  [[ -z "$MOVE_STATE_FILE" ]] || rm -f "$MOVE_STATE_FILE"
  echo "[!] Rollback completed; CT ${CTID} restored on ${SOURCE_NODE}." >&2
  exit "$exit_code"
}

verify_target_services() {
  local service state health attempt
  remote "pct exec '$CTID' -- sh -c 'cd /mnt/docker && docker compose config --quiet'"
  COMPOSE_PERMISSION_EXECUTOR=target_ct_exec reconcile_compose_permissions "$CTID"
  remote "pct exec '$CTID' -- sh -c 'cd /mnt/docker && docker compose up -d'"

  while IFS= read -r service; do
    [[ -n "$service" ]] || continue
    state=""
    health=""
    for attempt in {1..60}; do
      state=$(remote "pct exec '$CTID' -- docker inspect -f '{{.State.Status}}' '$service'" 2>/dev/null || true)
      health=$(remote "pct exec '$CTID' -- docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' '$service'" 2>/dev/null || true)
      if [[ "$state" == "running" && ( -z "$health" || "$health" == "healthy" ) ]]; then
        break
      fi
      [[ "$state" != "exited" && "$state" != "dead" ]] || break
      sleep 2
    done
    [[ "$state" == "running" ]] || { echo "ERROR: Service '${service}' is ${state:-missing}." >&2; return 1; }
    [[ -z "$health" || "$health" == "healthy" ]] || { echo "ERROR: Service '${service}' is ${health}." >&2; return 1; }
  done <<< "$EXPECTED_SERVICES"
}

verify_target_dns() {
  local target_ip resolved_ips attempt
  target_ip=$(remote "pct exec '$CTID' -- sh -c \"ip -4 -o addr show scope global | awk 'NR == 1 {split(\\\$4, a, \\\"/\\\"); print a[1]}'\"" 2>/dev/null || true)
  [[ -n "$target_ip" ]] || { echo "ERROR: CT ${CTID} has no target IPv4 address." >&2; return 1; }

  for attempt in {1..30}; do
    resolved_ips=$(getent ahostsv4 "$CT_HOSTNAME" 2>/dev/null | awk '{print $1}' | sort -u || true)
    if grep -Fxq "$target_ip" <<< "$resolved_ips"; then
      echo "  [✓] DNS ${CT_HOSTNAME} resolves to ${target_ip}"
      return 0
    fi
    sleep 2
  done

  echo "ERROR: DNS for ${CT_HOSTNAME} does not resolve to target IP ${target_ip}." >&2
  return 1
}

safe_remove_source_data() {
  local expected path canonical
  for path in "$DIR_DOCKER" "$DIR_DOCKER_DATA"; do
    case "$path" in
      "/mnt/docker/${CT_HOSTNAME}") expected="$path" ;;
      "/mnt/docker-data/${CT_HOSTNAME}") expected="$path" ;;
      *) echo "ERROR: Refusing unsafe source cleanup path '${path}'." >&2; return 1 ;;
    esac
    [[ ! -L "$path" ]] || { echo "ERROR: Refusing symlink cleanup '${path}'." >&2; return 1; }
    canonical=$(realpath -e "$path")
    [[ "$canonical" == "$expected" ]] || { echo "ERROR: Cleanup path changed: '${canonical}'." >&2; return 1; }
  done
  rm -rf --one-file-system -- "$DIR_DOCKER" "$DIR_DOCKER_DATA"
}

report_move_status() {
  local owner task_status="not-submitted" task_exit="" lock=""
  owner=$(get_ct_owner_node || true)
  if [[ -n "$MOVE_TASK_UPID" ]]; then
    local status
    if status=$(get_migration_task_status); then
      task_status=$(jq -r '.status // "unknown"' <<< "$status")
      task_exit=$(jq -r '.exitstatus // empty' <<< "$status")
    else
      task_status="unavailable"
    fi
  fi
  if [[ "$owner" == "$SOURCE_NODE" ]]; then
    lock=$(pct config "$CTID" 2>/dev/null | sed -n 's/^lock:[[:space:]]*//p' || true)
  elif [[ "$owner" == "$TARGET_NODE" ]]; then
    lock=$(remote "pct config '$CTID'" 2>/dev/null | sed -n 's/^lock:[[:space:]]*//p' || true)
  fi
  echo "Move transaction: CT ${CTID} (${CT_HOSTNAME})"
  echo "  State:      ${MOVE_PHASE} (revision ${MOVE_STATE_REVISION})"
  echo "  Route:      ${SOURCE_NODE} -> ${TARGET_NODE}"
  echo "  Bridges:    ${SOURCE_BRIDGE} (${SOURCE_BRIDGE_REASON}) -> ${TARGET_BRIDGE} (${TARGET_BRIDGE_REASON})"
  echo "  Live owner: ${owner:-unknown}"
  echo "  CT lock:    ${lock:-none}"
  echo "  Task:       ${task_status}${task_exit:+ (${task_exit})}"
  [[ -z "$MOVE_TASK_UPID" ]] || echo "  UPID:       ${MOVE_TASK_UPID}"
  echo "  State file: ${MOVE_STATE_FILE}"
}

report_legacy_move_status() {
  local owner config="" status="" tasks upid task_detail task_state task_exit task_log
  owner=$(get_ct_owner_node || true)
  echo "Legacy move inspection: CT ${CTID} (${CT_HOSTNAME})"
  echo "  No checkpoint state exists; this report is read-only."
  echo "  Live owner: ${owner:-unknown}"
  if [[ "$owner" == "$(hostname -s)" ]]; then
    status=$(pct status "$CTID" 2>/dev/null || true)
    config=$(pct config "$CTID" 2>/dev/null || true)
  elif [[ -n "$owner" ]]; then
    status=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$owner" "pct status '$CTID'" 2>/dev/null || true)
    config=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$owner" "pct config '$CTID'" 2>/dev/null || true)
  fi
  echo "  Status:     ${status:-unknown}"
  printf '%s\n' "$config" | grep -E '^(rootfs|mp[0-9]+|unused[0-9]+|lock):' | sed 's/^/  Config:     /' || true
  if [[ -n "$owner" ]]; then
    tasks=$(pvesh get "/nodes/${owner}/tasks" --vmid "$CTID" --limit 50 --output-format json 2>/dev/null || true)
    while IFS= read -r upid; do
      [[ -n "$upid" ]] || continue
      task_detail=$(pvesh get "/nodes/${owner}/tasks/${upid}/status" --output-format json 2>/dev/null || true)
      task_state=$(jq -r '.status // "unavailable"' <<< "$task_detail" 2>/dev/null || echo unavailable)
      task_exit=$(jq -r '.exitstatus // empty' <<< "$task_detail" 2>/dev/null || true)
      echo "  Task:       ${upid} state=${task_state}${task_exit:+ exit=${task_exit}}"
      task_log=$(pvesh get "/nodes/${owner}/tasks/${upid}/log" --limit 8 --output-format json 2>/dev/null || true)
      jq -r '.[]?.t // empty | "    log: " + .' <<< "$task_log" 2>/dev/null || true
    done < <(jq -r '.[] | select((.type // "") | test("migrate"; "i")) | .upid // empty' \
      <<< "$tasks" 2>/dev/null || true)
  fi
  if [[ -n "$TARGET_NODE" ]]; then
    echo "  Requested target inspection: ${TARGET_NODE}"
    remote "pvesm list local-lvm --vmid '$CTID' 2>/dev/null || true; \
      for path in '$DIR_DOCKER' '$DIR_DOCKER_DATA'; do \
        if test -e \"\$path\"; then du -sh \"\$path\"; else echo \"missing: \$path\"; fi; \
      done" | sed 's/^/  Target:     /'
  fi
  echo "  Do not retry or delete either workload copy until ownership, mounts, and the last migration task agree."
}

resolve_move_state_input() {
  local input="$1" state match=""
  if [[ "$input" =~ ^[0-9]+$ ]]; then
    CTID="$input"
    MOVE_STATE_FILE=$(move_state_path "$CTID")
    return 0
  fi
  for state in "$MOVE_STATE_ROOT"/*.json; do
    [[ -f "$state" ]] || continue
    if [[ $(jq -r '.hostname // empty' "$state" 2>/dev/null || true) == "$input" ]]; then
      [[ -z "$match" ]] || abort_move "Multiple move transactions match hostname '${input}'."
      match="$state"
    fi
  done
  [[ -n "$match" ]] || return 1
  CTID=$(jq -r '.ctid // empty' "$match" 2>/dev/null)
  [[ "$CTID" =~ ^[0-9]+$ ]] || abort_move "Move state has an invalid CTID: ${match}"
  MOVE_STATE_FILE="$match"
}

run_move_transaction() {
  local ct_lock
  move_status_init
  MOVE_COORDINATOR_BASHPID="$BASHPID"
  ROLLBACK_IN_PROGRESS=false
  trap transaction_error_handler ERR
  trap 'move_signal_handler HUP 129' HUP
  trap 'move_signal_handler INT 130' INT
  trap 'move_signal_handler TERM 143' TERM

  if phase_before source_network_reconciled; then
    move_status_progress 1 "Reconciling source bridge policy..."
    bridge_policy_reconcile_guest "$SOURCE_NODE" CT "$CTID" "$SOURCE_BRIDGE"
    checkpoint_move source_network_reconciled
  fi

  if phase_before target_prepared; then
    move_status_progress 2 "Preparing target workload paths..."
    remote "mkdir -p '$DIR_DOCKER' '$DIR_DOCKER_DATA'"
    TARGET_DIRS_CREATED=true
    checkpoint_move target_prepared
  fi

  if phase_before seeded; then
    move_status_progress 3 "Seeding target from shared backup..."
    seed_target_or_fallback
    checkpoint_move seeded
  fi

  if phase_before live_sync_complete; then
    move_status_progress 4 "Synchronizing live workload changes..."
    sync_to_target false
    checkpoint_move live_sync_complete
  fi

  if phase_before stopped_sync_complete; then
    ct_lock=$(pct config "$CTID" 2>/dev/null | sed -n 's/^lock:[[:space:]]*//p' || true)
    [[ -z "$ct_lock" ]] || abort_move "CT ${CTID} became locked during pre-copy (${ct_lock})."
    move_status_progress 5 "Stopping CT for final synchronization..."
    if [[ "$ORIGINAL_STATUS" == "running" ]]; then
      pct shutdown "$CTID" --timeout 60 || pct stop "$CTID"
      ensure_ct_stopped "$CTID"
    fi
    move_status_progress 6 "Applying final stopped workload delta..."
    sync_to_target true
    checkpoint_move stopped_sync_complete
  fi

  if phase_before data_verified; then
    move_status_progress 7 "Verifying workload data integrity..."
    verify_target_tree "$DIR_DOCKER" "Docker tree"
    verify_target_tree "$DIR_DOCKER_DATA" "Docker-data tree"
    checkpoint_move data_verified
  fi

  if phase_before mounts_detached; then
    move_status_progress 8 "Preparing CT rootfs migration to ${TARGET_NODE}..."
    detect_node_gpu_capability "$TARGET_NODE"
    reconcile_stopped_ct_gpu_config "$CTID"
    detach_source_mounts
    checkpoint_move mounts_detached
  fi

  if phase_before migration_submitted; then
    submit_migration_task
  fi
  if [[ "$MOVE_PHASE" == migration_submitted ]]; then
    move_status_progress 8 "Waiting for Proxmox migration task..."
    wait_for_migration_task
  fi

  if phase_before target_network_reconciled; then
    move_status_progress 9 "Reconciling target bridge policy..."
    bridge_policy_reconcile_guest "$TARGET_NODE" CT "$CTID" "$TARGET_BRIDGE"
    checkpoint_move target_network_reconciled
  fi

  if phase_before mounts_restored; then
    restore_target_mounts
    checkpoint_move mounts_restored
  fi

  if phase_before services_verified; then
    move_status_progress 10 "Starting and validating target services..."
    if [[ "$ORIGINAL_STATUS" == "running" ]]; then
      remote "pct start '$CTID'"
      remote "pct exec '$CTID' -- sh -c 'for i in \$(seq 1 60); do docker info >/dev/null 2>&1 && exit 0; sleep 2; done; exit 1'"
      verify_target_services
    fi
    checkpoint_move services_verified
  fi

  if phase_before dns_verified; then
    if [[ "$ORIGINAL_STATUS" == "running" ]]; then
      move_status_progress 11 "Validating target DNS..."
      verify_target_dns
    else
      move_status_progress 11 "Preserving original stopped state..."
    fi
    checkpoint_move dns_verified
  fi

  if phase_before committed; then
    move_status_progress 12 "Committing move and cleaning source data..."
    safe_remove_source_data
    COMMITTED=true
    checkpoint_move committed
  fi
  trap - ERR HUP INT TERM
  move_status_cleanup
  echo "Move committed successfully. Transaction log: ${RUN_LOG_FILE}"
}

main() {
  local -a original_args=("$@")
  local ct_arg="" arg target_status answer ct_lock rootfs_size_gib
  while [[ $# -gt 0 ]]; do
    arg="$1"
    case "$arg" in
      --node) [[ $# -ge 2 ]] || { echo "ERROR: --node requires a value." >&2; exit 1; }; TARGET_NODE="$2"; shift 2 ;;
      --status|--resume|--abort)
        [[ $# -ge 2 ]] || { echo "ERROR: ${arg} requires a CT." >&2; exit 1; }
        MOVE_ACTION="${arg#--}"
        ct_arg="$2"
        shift 2
        ;;
      --dry-run) DRY_RUN=true; shift ;;
      --force) FORCE=true; shift ;;
      -h|--help) usage; exit 0 ;;
      -*) echo "ERROR: Unknown option '${arg}'." >&2; usage; exit 1 ;;
      *) [[ -z "$ct_arg" ]] || { echo "ERROR: Only one CT may be moved." >&2; exit 1; }; ct_arg="$arg"; shift ;;
    esac
  done

  if [[ "$MOVE_ACTION" != status ]]; then
    set -- "${original_args[@]}"
    lifecycle_log_init "${BASH_SOURCE[0]}" "$@"
  fi

  [[ $EUID -eq 0 ]] || { echo "ERROR: Run moveCT.sh as root on the source node." >&2; exit 1; }
  if [[ "$MOVE_ACTION" != move ]]; then
    resolve_move_state_input "$ct_arg" || true
    if [[ -n "$MOVE_STATE_FILE" && -f "$MOVE_STATE_FILE" ]]; then
      [[ "$MOVE_ACTION" == status ]] || acquire_move_state_lock
      load_move_state
      report_move_status
      [[ "$MOVE_ACTION" != status ]] || exit 0
      [[ "$(hostname -s)" == "$SOURCE_NODE" ]] \
        || { echo "ERROR: Resume or abort this transaction on authoritative node ${SOURCE_NODE}." >&2; exit 1; }
      if [[ "$MOVE_ACTION" == abort ]]; then
        [[ "$FORCE" == true ]] || {
          read -rp "Abort and recover CT ${CTID} to ${SOURCE_NODE} when safe? [y/N]: " answer
          [[ "$answer" =~ ^[Yy]$ ]] || { echo "Aborted without changes."; exit 0; }
        }
        if migration_task_running; then
          echo "ERROR: Proxmox migration task ${MOVE_TASK_UPID} is still running; abort is unsafe." >&2
          exit 1
        fi
        rollback 0
      fi
      run_move_transaction
      exit 0
    fi
    [[ "$MOVE_ACTION" == status ]] \
      || { echo "ERROR: No resumable move transaction exists for '${ct_arg}'." >&2; exit 1; }
  fi
  build_ct_list
  if [[ -n "$ct_arg" ]]; then
    resolve_ct_from_input "$ct_arg" || exit 1
  else
    select_ct_interactive_single "move" || exit 1
  fi
  if [[ "$MOVE_ACTION" == status ]]; then
    MOVE_STATE_FILE=$(move_state_path "$CTID")
    get_ct_dirs "$CT_HOSTNAME"
    report_legacy_move_status
    exit 0
  fi

  MOVE_STATE_FILE=$(move_state_path "$CTID")
  if [[ -e "$MOVE_STATE_FILE" ]]; then
    echo "ERROR: Existing move transaction found for CT ${CTID}." >&2
    echo "       Inspect it with: ./moveCT.sh --status ${CTID}" >&2
    echo "       Complete recovery with: ./moveCT.sh --abort ${CTID} --force" >&2
    exit 1
  fi

  [[ -n "$TARGET_NODE" ]] || select_target_node "$SOURCE_NODE" || exit 1
  [[ "$TARGET_NODE" != "$SOURCE_NODE" ]] || { echo "ERROR: Source and target nodes are identical." >&2; exit 1; }

  target_status=$(pvesh get /nodes --output-format json 2>/dev/null \
    | jq -r --arg node "$TARGET_NODE" '.[] | select(.node == $node) | .status' || true)
  [[ "$target_status" == "online" ]] || { echo "ERROR: Target node '${TARGET_NODE}' is not online." >&2; exit 1; }

  get_ct_dirs "$CT_HOSTNAME"
  ORIGINAL_STATUS=$(get_ct_status "$CTID")
  [[ "$ORIGINAL_STATUS" == "running" || "$ORIGINAL_STATUS" == "stopped" ]] || { echo "ERROR: Unsupported CT status '${ORIGINAL_STATUS}'." >&2; exit 1; }
  ct_lock=$(pct config "$CTID" 2>/dev/null | sed -n 's/^lock:[[:space:]]*//p' || true)
  [[ -z "$ct_lock" ]] || { echo "ERROR: CT ${CTID} is locked (${ct_lock})." >&2; exit 1; }
  validate_ct_storage_scope || exit 1
  capture_original_mounts
  capture_original_networks || exit 1
  rootfs_size_gib=$(get_ct_rootfs_size_gib) || exit 1
  validate_move_node_contracts "$SOURCE_NODE" 0 || exit 1
  validate_move_node_contracts "$TARGET_NODE" "$rootfs_size_gib" || exit 1
  resolve_move_bridge_contracts || exit 1

  detect_node_gpu_capability "$TARGET_NODE" || exit 1
  validate_target_devices || exit 1
  inspect_migration_bandwidth "$rootfs_size_gib"

  [[ -d "$DIR_DOCKER" && -d "$DIR_DOCKER_DATA" ]] || { echo "ERROR: Source bind trees are incomplete." >&2; exit 1; }
  if remote "test -e '$DIR_DOCKER' -o -e '$DIR_DOCKER_DATA'"; then
    echo "ERROR: Target bind paths already exist; refusing ambiguous merge." >&2
    exit 1
  fi
  find_backup_seed || true

  echo "CT ${CTID} (${CT_HOSTNAME}): ${SOURCE_NODE} -> ${TARGET_NODE}"
  echo "State: ${ORIGINAL_STATUS}; target GPU: ${NODE_GPU_STATE} (${NODE_GPU_RENDER_DEVICES[*]:-none})"
  echo "Data: ${DIR_DOCKER}, ${DIR_DOCKER_DATA}"
  echo "Mounts: ${#ORIGINAL_MOUNT_KEYS[@]} local bind mount(s) will be detached only during rootfs migration"
  echo "Bridges: ${SOURCE_BRIDGE} (${SOURCE_BRIDGE_REASON}) -> ${TARGET_BRIDGE} (${TARGET_BRIDGE_REASON}); all ${#ORIGINAL_NETWORK_KEYS[@]} NIC(s)"
  if [[ -n "$BACKUP_SEED_GENERATION" ]]; then
    echo "Seed: $(basename "$BACKUP_SEED_GENERATION") from shared backup ($((BACKUP_SEED_AGE_SECONDS / 3600))h old)"
  else
    echo "Seed: no complete backup within 26h; using source pre-copy"
  fi
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "Dry run complete; no changes made."
    exit 0
  fi
  if [[ "$FORCE" != "true" ]]; then
    read -rp "Proceed with the move? The CT will be stopped briefly for the final data sync. [y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
  fi
  confirm_slow_migration

  ORIGINAL_GPU_CONFIG=$(grep -E '^lxc\.(cgroup2\.devices\.allow: c 226:\* rwm|mount\.entry: /dev/dri dev/dri none bind,optional,create=dir)$' "/etc/pve/lxc/${CTID}.conf" || true)
  if [[ "$ORIGINAL_STATUS" == "running" ]]; then
    EXPECTED_SERVICES=$(ct_exec --timeout 30 "$CTID" 'docker ps --format {{.Names}}' 2>/dev/null || true)
  fi

  acquire_move_state_lock
  [[ ! -e "$MOVE_STATE_FILE" ]] \
    || { echo "ERROR: Existing move transaction found; use --status or --resume for CT ${CTID}." >&2; exit 1; }
  MOVE_PHASE=initialized
  save_move_state
  run_move_transaction
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi