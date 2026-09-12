#!/usr/bin/env bash
# QEMU VM backup lifecycle. Documentation: backupVM.md
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/commonCT.sh"

ACTION=""
RUN_TARGET=""
RESTORE_ID=""
RESTORE_NODE=""
DRY_RUN=false
FORCE=false
VMID=""
VM_NAME=""
SOURCE_NODE=""
RESTORE_CREATED=false

usage() {
  cat <<'EOF'
Usage: backupVM.sh ACTION [options]

  --configure-job         Reconcile the dedicated QEMU vzdump job
  --reconcile-job         Refresh eligible VMIDs on the existing QEMU job
  --run <VMID|hostname|all>  Run an immediate QEMU snapshot backup
  --verify                Verify the latest archive for every eligible VM
  --restore-test <VM>     Restore the newest archive into an isolated VM
  --restore-id <unused>   Required unused VMID for --restore-test
  --node <node>           Restore-test node (defaults to source VM node)
  --force                 Skip restore-test confirmation
  --dry-run               Print mutations without performing them
EOF
}

online_nodes() {
  pvesh get /nodes --output-format json | jq -r '.[] | select(.status == "online") | .node' | sort
}

run_on_node() {
  local node="$1" argument quoted command=""
  shift
  if [[ "$node" == "$(hostname -s)" ]]; then
    "$@"
    return
  fi
  for argument in "$@"; do
    printf -v quoted '%q' "$argument"
    command+="${command:+ }${quoted}"
  done
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$node" "$command"
}

cluster_vm_ids() {
  backup_resource_ids qemu
}

backup_storage_mount() {
  printf '%s/%s\n' "${BACKUP_MOUNT_ROOT:-/mnt/pve}" "$(config_get_backup_vm_storage)"
}

verify_backup_storage_nodes() {
  local requested_node="${1:-}" storage node status failed=false
  storage=$(config_get_backup_vm_storage)
  while IFS= read -r node; do
    [[ -z "$requested_node" || "$node" == "$requested_node" ]] || continue
    status=$(pvesh get "/nodes/${node}/storage/${storage}/status" --output-format json 2>/dev/null || true)
    if [[ -z "$status" ]] || ! jq -e '.active == 1' <<<"$status" >/dev/null; then
      echo "ERROR: Backup storage ${storage} is not active on ${node}." >&2
      failed=true
    fi
  done < <(online_nodes)
  [[ "$failed" == false ]]
}

resolve_cluster_vm() {
  local input="$1" resources match_count eligible_ids
  resources=$(pvesh get /cluster/resources --type vm --output-format json)
  if [[ "$input" =~ ^[0-9]+$ ]]; then
    match_count=$(jq --argjson id "$input" '[.[] | select(.type == "qemu" and .vmid == $id)] | length' <<<"$resources")
    [[ "$match_count" == 1 ]] || { echo "ERROR: VM ${input} was not found exactly once." >&2; return 1; }
    VMID="$input"
  else
    match_count=$(jq --arg name "$input" '[.[] | select(.type == "qemu" and .name == $name)] | length' <<<"$resources")
    [[ "$match_count" == 1 ]] || { echo "ERROR: VM hostname ${input} was not found exactly once." >&2; return 1; }
    VMID=$(jq -r --arg name "$input" '.[] | select(.type == "qemu" and .name == $name) | .vmid' <<<"$resources")
  fi
  eligible_ids=",$(backup_resource_ids qemu "$resources"),"
  [[ "$eligible_ids" == *",${VMID},"* ]] || {
    echo "ERROR: VM ${VMID} is excluded from backup by tag." >&2
    return 1
  }
  VM_NAME=$(jq -r --argjson id "$VMID" '.[] | select(.type == "qemu" and .vmid == $id) | .name' <<<"$resources")
  SOURCE_NODE=$(jq -r --argjson id "$VMID" '.[] | select(.type == "qemu" and .vmid == $id) | .node' <<<"$resources")
}

configure_job() {
  local job_id storage schedule repeat_missed compress
  verify_backup_storage_nodes
  local bwlimit ionice notification_mode vmids enabled_value repeat_value
  job_id=$(config_get_backup_vm_job_id)
  storage=$(config_get_backup_vm_storage)
  schedule=$(config_get_backup_vm_schedule)
  repeat_missed=$(config_get_backup_vm_repeat_missed)
  compress=$(config_get_backup_compress)
  bwlimit=$(config_get_backup_bwlimit_kib)
  ionice=$(config_get_backup_ionice)
  notification_mode=$(config_get_backup_notification_mode)
  vmids=$(cluster_vm_ids)
  [[ "$repeat_missed" == true ]] && repeat_value=1 || repeat_value=0
  if [[ -n "$vmids" && "$(config_get_backup_vm_enabled)" == true ]]; then enabled_value=1; else enabled_value=0; fi

  if [[ -z "$vmids" ]]; then
    if pvesh get "/cluster/backup/${job_id}" >/dev/null 2>&1; then
      if [[ "$DRY_RUN" == true ]]; then
        echo "Would disable QEMU backup job ${job_id}: no eligible VMs."
      else
        pvesh set "/cluster/backup/${job_id}" --enabled 0
        echo "Disabled QEMU backup job ${job_id}: no eligible VMs."
      fi
    else
      echo "No eligible QEMU VMs; job ${job_id} was not created."
    fi
    return 0
  fi

  local arguments=(--storage "$storage" --mode "$(config_get_backup_vm_mode)" --compress "$compress"
    --schedule "$schedule" --repeat-missed "$repeat_value" --enabled "$enabled_value" --vmid "$vmids"
    --ionice "$ionice" --notification-mode "$notification_mode")
  (( bwlimit == 0 )) || arguments+=(--bwlimit "$bwlimit")
  if [[ "$DRY_RUN" == true ]]; then
    printf 'Would reconcile /cluster/backup/%s with:' "$job_id"
    printf ' %q' "${arguments[@]}"
    printf '\n'
  elif pvesh get "/cluster/backup/${job_id}" >/dev/null 2>&1; then
    pvesh set "/cluster/backup/${job_id}" "${arguments[@]}"
    echo "Updated QEMU backup job ${job_id}."
  else
    pvesh create /cluster/backup --id "$job_id" "${arguments[@]}"
    echo "Created QEMU backup job ${job_id}."
  fi
}

reconcile_job() {
  local job_id vmids
  job_id=$(config_get_backup_vm_job_id)
  pvesh get "/cluster/backup/${job_id}" >/dev/null 2>&1 || {
    echo "ERROR: QEMU backup job ${job_id} does not exist; run --configure-job." >&2
    return 1
  }
  vmids=$(cluster_vm_ids)
  if [[ "$DRY_RUN" == true ]]; then
    if [[ -n "$vmids" ]]; then
      echo "Would set QEMU backup job ${job_id} VMIDs to ${vmids} and enable it."
    else
      echo "Would disable QEMU backup job ${job_id}: no eligible VMs."
    fi
  elif [[ -n "$vmids" ]]; then
    pvesh set "/cluster/backup/${job_id}" --vmid "$vmids" --enabled 1 >/dev/null
    echo "Reconciled QEMU backup job ${job_id}: ${vmids}."
  else
    pvesh set "/cluster/backup/${job_id}" --enabled 0 >/dev/null
    echo "Disabled QEMU backup job ${job_id}: no eligible VMs."
  fi
}

run_backup() {
  local target="$1" resources vmids vmid node storage mode compress bwlimit ionice
  local selected=()
  resources=$(pvesh get /cluster/resources --type vm --output-format json)
  if [[ "$target" == all ]]; then
    vmids=$(backup_resource_ids qemu "$resources")
    [[ -n "$vmids" ]] || { echo "No eligible QEMU VMs found."; return 0; }
    IFS=',' read -r -a selected <<<"$vmids"
  else
    resolve_cluster_vm "$target"
    selected=("$VMID")
  fi
  storage=$(config_get_backup_vm_storage)
  mode=$(config_get_backup_vm_mode)
  compress=$(config_get_backup_compress)
  bwlimit=$(config_get_backup_bwlimit_kib)
  ionice=$(config_get_backup_ionice)
  for vmid in "${selected[@]}"; do
    node=$(jq -r --argjson id "$vmid" '.[] | select(.type == "qemu" and .vmid == $id) | .node' <<<"$resources")
    [[ -n "$node" ]] || { echo "ERROR: Cannot resolve node for VM ${vmid}." >&2; return 1; }
    verify_backup_storage_nodes "$node"
    local command=(vzdump "$vmid" --storage "$storage" --mode "$mode" --compress "$compress" --ionice "$ionice")
    (( bwlimit == 0 )) || command+=(--bwlimit "$bwlimit")
    if [[ "$DRY_RUN" == true ]]; then
      printf 'Would run on %s:' "$node"
      printf ' %q' "${command[@]}"
      printf '\n'
    else
      echo "Starting QEMU snapshot backup for VM ${vmid} on ${node}."
      run_on_node "$node" "${command[@]}"
    fi
  done
}

verify_archives() {
  local mount_path resources vmid name archive age_seconds failed=false now
  mount_path=$(backup_storage_mount)
  [[ -d "${mount_path}/dump" ]] || { echo "ERROR: Backup dump is unavailable at ${mount_path}/dump." >&2; return 1; }
  resources=$(pvesh get /cluster/resources --type vm --output-format json)
  now=$(date +%s)
  while IFS=$'\t' read -r vmid name; do
    archive=$(find "${mount_path}/dump" -maxdepth 1 -type f -name "vzdump-qemu-${vmid}-*.vma.zst" -print | sort -r | head -n 1 || true)
    if [[ -z "$archive" ]]; then
      echo "MISSING VM ${vmid} (${name}): no zstd VMA archive"
      failed=true
      continue
    fi
    age_seconds=$((now - $(stat -c %Y "$archive")))
    if (( age_seconds > 93600 )); then
      echo "STALE VM ${vmid} (${name}): archive is $((age_seconds / 3600))h old"
      failed=true
    else
      echo "OK VM ${vmid} (${name}): $(basename "$archive")"
    fi
  done < <(jq -r --argjson excluded "$(backup_effective_exclude_tags)" '.[]
    | select(.type == "qemu")
    | select(((.tags // "") | split(";")) as $tags
        | all($excluded[]; . as $tag | ($tags | index($tag)) == null))
    | [.vmid, .name] | @tsv' <<<"$resources" | sort -n)
  [[ "$failed" == false ]]
}

isolate_vm_nics() {
  local node="$1" vmid="$2" bridge="$3"
  bridge_policy_reconcile_guest "$node" VM "$vmid" "$bridge" false true
}

validate_vm_volumes() {
  local node="$1" vmid="$2" config key value volume
  config=$(run_on_node "$node" qm config "$vmid") || return 1
  while IFS=': ' read -r key value; do
    [[ "$key" =~ ^(efidisk|tpmstate|ide|sata|scsi|virtio)[0-9]+$ ]] || continue
    [[ "$value" == *"media=cdrom"* ]] && continue
    volume=${value%%,*}
    [[ -n "$volume" && "$volume" != none ]] || continue
    run_on_node "$node" pvesm path "$volume" >/dev/null || {
      echo "ERROR: Restored volume ${key}=${volume} is unavailable on ${node}." >&2
      return 1
    }
  done <<<"$config"
}

restore_failure() {
  local exit_code=$?
  if [[ "$RESTORE_CREATED" == true ]]; then
    run_on_node "${RESTORE_NODE:-$SOURCE_NODE}" qm stop "$RESTORE_ID" --skiplock 1 >/dev/null 2>&1 || true
    echo "ERROR: Restore test failed. VM ${RESTORE_ID} remains stopped for inspection." >&2
    echo "Cleanup when ready: qm destroy ${RESTORE_ID} --destroy-unreferenced-disks 1 --purge 1" >&2
  fi
  return "$exit_code"
}

restore_test() {
  local source="$1" mount_path archive resources node reply status attempts agent restore_bridge restore_reason
  [[ "$RESTORE_ID" =~ ^[1-9][0-9]+$ ]] || { echo "ERROR: --restore-id with an unused numeric VMID is required." >&2; return 1; }
  resolve_cluster_vm "$source"
  resources=$(pvesh get /cluster/resources --type vm --output-format json)
  [[ "$(jq --argjson id "$RESTORE_ID" '[.[] | select(.vmid == $id)] | length' <<<"$resources")" == 0 ]] || {
    echo "ERROR: Restore VMID ${RESTORE_ID} already exists." >&2
    return 1
  }
  mount_path=$(backup_storage_mount)
  archive=$(find "${mount_path}/dump" -maxdepth 1 -type f -name "vzdump-qemu-${VMID}-*.vma.zst" -print | sort -r | head -n 1 || true)
  [[ -n "$archive" ]] || { echo "ERROR: No zstd VMA archive exists for VM ${VMID}." >&2; return 1; }
  node="${RESTORE_NODE:-$SOURCE_NODE}"
  if ! online_nodes | grep -Fxq "$node"; then
    echo "ERROR: Restore node ${node} is not online." >&2
    return 1
  fi
  bridge_policy_resolve "$node" VM "$RESTORE_ID" "$VM_NAME" || return 1
  restore_bridge="$BRIDGE_POLICY_SELECTED"
  restore_reason="$BRIDGE_POLICY_REASON"

  echo "Restore test plan:"
  echo "  Source: VM ${VMID} (${VM_NAME})"
  echo "  Archive: $(basename "$archive")"
  echo "  Target: VM ${RESTORE_ID} on ${node}, bridge ${restore_bridge} (${restore_reason}), unique identity, all NICs link down"
  if [[ "$DRY_RUN" == true ]]; then
    echo "[dry-run] Would restore, isolate, validate volumes, boot briefly, stop, and retain VM ${RESTORE_ID}."
    return 0
  fi
  if [[ "$FORCE" != true ]]; then
    read -rp "Create this isolated VM restore test? [y/N]: " reply
    [[ "$reply" =~ ^[Yy]$ ]] || { echo "Aborted."; return 0; }
  fi

  RESTORE_NODE="$node"
  trap restore_failure ERR
  run_on_node "$node" qmrestore "$archive" "$RESTORE_ID" --storage "$(config_get_backup_vm_restore_storage)" --unique 1 --start 0
  RESTORE_CREATED=true
  run_on_node "$node" qm set "$RESTORE_ID" --tags backup-restore-test --onboot 0
  isolate_vm_nics "$node" "$RESTORE_ID" "$restore_bridge"
  validate_vm_volumes "$node" "$RESTORE_ID"
  run_on_node "$node" qm start "$RESTORE_ID"
  status=""
  for ((attempts = 0; attempts < 30; attempts++)); do
    status=$(run_on_node "$node" qm status "$RESTORE_ID" 2>/dev/null | awk '{print $2}' || true)
    [[ "$status" == running ]] && break
    sleep 2
  done
  [[ "$status" == running ]] || { echo "ERROR: Restored VM did not reach running state." >&2; return 1; }
  agent=$(run_on_node "$node" qm config "$RESTORE_ID" | awk -F': ' '$1 == "agent" {print $2}' || true)
  if [[ "$agent" == 1* ]]; then
    run_on_node "$node" qm agent "$RESTORE_ID" ping >/dev/null 2>&1 || echo "WARNING: VM is running but its configured guest agent did not answer."
  fi
  run_on_node "$node" qm stop "$RESTORE_ID"
  trap - ERR
  RESTORE_CREATED=false
  echo "Restore test passed. VM ${RESTORE_ID} is stopped, tagged, and network-isolated for inspection."
}

main() {
  lifecycle_log_init "${BASH_SOURCE[0]}" "$@"
  [[ $# -gt 0 ]] || { usage; return 1; }
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --configure-job|--reconcile-job|--verify)
        [[ -z "$ACTION" ]] || { echo "ERROR: Specify one action." >&2; return 1; }
        ACTION="$1"; shift ;;
      --run|--restore-test)
        [[ -z "$ACTION" ]] || { echo "ERROR: Specify one action." >&2; return 1; }
        ACTION="$1"; RUN_TARGET="${2:-}"; [[ -n "$RUN_TARGET" ]] || { echo "ERROR: $1 requires a VM or all." >&2; return 1; }; shift 2 ;;
      --restore-id) [[ -n "${2:-}" ]] || { echo "ERROR: --restore-id requires a VMID." >&2; return 1; }; RESTORE_ID="$2"; shift 2 ;;
      --node) [[ -n "${2:-}" ]] || { echo "ERROR: --node requires a node." >&2; return 1; }; RESTORE_NODE="$2"; shift 2 ;;
      --force) FORCE=true; shift ;;
      --dry-run) DRY_RUN=true; shift ;;
      -h|--help) usage; return 0 ;;
      *) echo "ERROR: Unknown option: $1" >&2; usage; return 1 ;;
    esac
  done
  validate_backup_config
  case "$ACTION" in
    --configure-job) configure_job ;;
    --reconcile-job) reconcile_job ;;
    --run) run_backup "$RUN_TARGET" ;;
    --verify) verify_archives ;;
    --restore-test) restore_test "$RUN_TARGET" ;;
    *) usage; return 1 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
