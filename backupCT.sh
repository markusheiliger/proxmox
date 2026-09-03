#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/commonCT.sh"

DRY_RUN=false
ACTION=""
RUN_TARGET=""
RESTORE_ID=""
RESTORE_NODE=""
FORCE=false
HOOK_SOURCE="${SCRIPT_DIR}/backup/pve-workload-backup-hook"
TEMP_PROVISIONER="${SCRIPT_DIR}/backup/provision-temp-storage"
HOOK_CONFIG="/etc/pve-workload-backup.conf"
RECONCILER_SOURCE="${SCRIPT_DIR}/backup/reconcile-backup-jobs"
RECONCILER_SERVICE="${SCRIPT_DIR}/backup/reconcile-backup-jobs.service"
RECONCILER_TIMER="${SCRIPT_DIR}/backup/reconcile-backup-jobs.timer"

usage() {
  cat <<'EOF'
Usage: backupCT.sh ACTION [options]

  --audit                 Audit snapshot and NFS capabilities on every online node
  --install-prerequisites Install package-backed hook dependencies on every node
  --provision-temp        Reconcile dedicated TEMP storage on every online node
  --install-hook          Install and verify the PVE hook on every online node
  --configure-job         Reconcile the cluster vzdump job (not enabled until audit passes)
  --run <CTID|hostname|all>  Run an immediate suspend backup
  --verify                Report archive/workload pair completeness
  --restore-test <CT>     Restore the newest complete pair into an isolated CT
  --restore-id <unused>   Required unused CTID for --restore-test
  --node <node>           Restore-test node (defaults to source CT node)
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

export_hook_policy() {
  export BACKUP_STORAGE BACKUP_TMPDIR BACKUP_STATE_DIR BACKUP_HEADROOM_PERCENT
  export BACKUP_TEMP_DEVICE BACKUP_TEMP_FILESYSTEM BACKUP_TEMP_SIZE_MULTIPLIER
  BACKUP_STORAGE=$(config_get_backup_storage)
  BACKUP_TMPDIR=$(config_get_backup_tmpdir)
  BACKUP_TEMP_DEVICE="/dev/$(config_get_backup_temp_vg)/$(config_get_backup_temp_lv)"
  BACKUP_TEMP_FILESYSTEM=$(config_get_backup_temp_filesystem)
  BACKUP_TEMP_SIZE_MULTIPLIER=$(config_get_backup_temp_size_multiplier)
  BACKUP_STATE_DIR=$(config_get_backup_state_dir)
  BACKUP_HEADROOM_PERCENT=$(config_get_backup_snapshot_headroom_percent)
}

hook_policy_content() {
  local backup_ct_job_id backup_vm_job_id backup_vm_enabled backup_exclude_tags backup_prune_policy
  export_hook_policy
  backup_ct_job_id=$(config_get_backup_job_id)
  backup_vm_job_id=$(config_get_backup_vm_job_id)
  backup_vm_enabled=$(config_get_backup_vm_enabled)
  backup_exclude_tags=$(config_get_backup_exclude_tags | jq -r 'join(",")')
  backup_prune_policy=$(config_get_backup_prune_policy)
  printf 'BACKUP_STORAGE=${BACKUP_STORAGE:-%q}\n' "$BACKUP_STORAGE"
  printf 'BACKUP_TMPDIR=${BACKUP_TMPDIR:-%q}\n' "$BACKUP_TMPDIR"
  printf 'BACKUP_TEMP_DEVICE=${BACKUP_TEMP_DEVICE:-%q}\n' "$BACKUP_TEMP_DEVICE"
  printf 'BACKUP_TEMP_FILESYSTEM=${BACKUP_TEMP_FILESYSTEM:-%q}\n' "$BACKUP_TEMP_FILESYSTEM"
  printf 'BACKUP_TEMP_SIZE_MULTIPLIER=${BACKUP_TEMP_SIZE_MULTIPLIER:-%q}\n' "$BACKUP_TEMP_SIZE_MULTIPLIER"
  printf 'BACKUP_STATE_DIR=${BACKUP_STATE_DIR:-%q}\n' "$BACKUP_STATE_DIR"
  printf 'BACKUP_HEADROOM_PERCENT=${BACKUP_HEADROOM_PERCENT:-%q}\n' "$BACKUP_HEADROOM_PERCENT"
  printf 'BACKUP_CT_JOB_ID=${BACKUP_CT_JOB_ID:-%q}\n' "$backup_ct_job_id"
  printf 'BACKUP_VM_JOB_ID=${BACKUP_VM_JOB_ID:-%q}\n' "$backup_vm_job_id"
  printf 'BACKUP_VM_ENABLED=${BACKUP_VM_ENABLED:-%q}\n' "$backup_vm_enabled"
  printf 'BACKUP_EXCLUDE_TAGS=${BACKUP_EXCLUDE_TAGS:-%q}\n' "$backup_exclude_tags"
  printf 'BACKUP_PRUNE_POLICY=${BACKUP_PRUNE_POLICY:-%q}\n' "$backup_prune_policy"
}

audit_cluster() {
  local node failed=false
  export_hook_policy
  while IFS= read -r node; do
    echo "Auditing ${node}..."
    if [[ "$node" == "$(hostname -s)" ]]; then
      if ! "$HOOK_SOURCE" audit-node; then failed=true; fi
    elif ! ssh -o BatchMode=yes -o ConnectTimeout=10 "$node" \
      "BACKUP_STORAGE='$BACKUP_STORAGE' BACKUP_TMPDIR='$BACKUP_TMPDIR' BACKUP_TEMP_DEVICE='$BACKUP_TEMP_DEVICE' BACKUP_TEMP_FILESYSTEM='$BACKUP_TEMP_FILESYSTEM' BACKUP_TEMP_SIZE_MULTIPLIER='$BACKUP_TEMP_SIZE_MULTIPLIER' BACKUP_STATE_DIR='$BACKUP_STATE_DIR' BACKUP_HEADROOM_PERCENT='$BACKUP_HEADROOM_PERCENT' bash -s -- audit-node" <"$HOOK_SOURCE"; then
      failed=true
    fi
  done < <(online_nodes)
  [[ "$failed" == false ]]
}

prepare_backup_tmpdir_cluster() {
  local node tmpdir tmpdir_parent expected_device mount_info mounted_source mounted_type
  tmpdir=$(config_get_backup_tmpdir)
  tmpdir_parent=${tmpdir%/*}
  expected_device="/dev/$(config_get_backup_temp_vg)/$(config_get_backup_temp_lv)"
  while IFS= read -r node; do
    if [[ "$DRY_RUN" == true ]]; then
      echo "Would verify dedicated TEMP storage on ${node}:${tmpdir_parent}"
      echo "Would prepare node-local vzdump staging on ${node}:${tmpdir}"
    else
      if ! run_on_node "$node" test -d "$tmpdir_parent"; then
        echo "ERROR: Dedicated TEMP storage is not provisioned on ${node}; run backupCT.sh --provision-temp." >&2
        return 1
      fi
      mount_info=$(run_on_node "$node" findmnt -rn -o SOURCE,FSTYPE --target "$tmpdir_parent" 2>/dev/null || true)
      read -r mounted_source mounted_type <<<"$mount_info"
      if [[ "$mounted_type" != "$(config_get_backup_temp_filesystem)" ]] || \
        ! run_on_node "$node" sh -c "test \"\$(readlink -f '$mounted_source')\" = \"\$(readlink -f '$expected_device')\""; then
        echo "ERROR: ${node}:${tmpdir_parent} is not the managed ${expected_device} TEMP volume; run backupCT.sh --provision-temp." >&2
        return 1
      fi
      run_on_node "$node" install -d -o root -g root -m 1777 "$tmpdir"
      run_on_node "$node" chmod 1777 "$tmpdir"
      echo "Prepared node-local vzdump staging on ${node}:${tmpdir}."
    fi
  done < <(online_nodes)
}

install_prerequisites_cluster() {
  local node missing package
  local commands=(jq rsync)
  local packages=()
  while IFS= read -r node; do
    missing=""
    for package in "${commands[@]}"; do
      if ! run_on_node "$node" sh -c "command -v '$package' >/dev/null 2>&1"; then
        missing+=" ${package}"
      fi
    done
    if [[ -z "$missing" ]]; then
      echo "Backup prerequisites already installed on ${node}."
      continue
    fi
    read -r -a packages <<<"${missing# }"
    if [[ "$DRY_RUN" == true ]]; then
      echo "Would install on ${node}:${missing}"
      continue
    fi
    echo "Installing on ${node}:${missing}..."
    run_on_node "$node" env DEBIAN_FRONTEND=noninteractive apt-get update -qq
    run_on_node "$node" env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${packages[@]}"
    for package in "${commands[@]}"; do
      run_on_node "$node" sh -c "command -v '$package' >/dev/null 2>&1" || {
        echo "ERROR: ${package} is still unavailable on ${node}." >&2
        return 1
      }
    done
    echo "Backup prerequisites installed on ${node}."
  done < <(online_nodes)
}

install_hook_cluster() {
  local node hook_path checksum installed_checksum temporary policy policy_checksum installed_policy_checksum policy_temporary
  install_prerequisites_cluster
  prepare_backup_tmpdir_cluster
  hook_path=$(config_get_backup_hook_path)
  checksum=$(sha256sum "$HOOK_SOURCE" | awk '{print $1}')
  policy=$(hook_policy_content)
  policy_checksum=$(printf '%s\n' "$policy" | sha256sum | awk '{print $1}')
  while IFS= read -r node; do
    if [[ "$DRY_RUN" == true ]]; then
      echo "Would install the workload hook, backup policy, and job reconciler on ${node}."
      continue
    fi
    if [[ "$node" == "$(hostname -s)" ]]; then
      install -D -o root -g root -m 0755 "$HOOK_SOURCE" "$hook_path"
      install -D -o root -g root -m 0755 "$RECONCILER_SOURCE" /usr/local/sbin/reconcile-backup-jobs
      install -D -o root -g root -m 0644 "$RECONCILER_SERVICE" /etc/systemd/system/reconcile-backup-jobs.service
      install -D -o root -g root -m 0644 "$RECONCILER_TIMER" /etc/systemd/system/reconcile-backup-jobs.timer
      policy_temporary=$(mktemp)
      printf '%s\n' "$policy" >"$policy_temporary"
      install -D -o root -g root -m 0600 "$policy_temporary" "$HOOK_CONFIG"
      rm -f "$policy_temporary"
      installed_checksum=$(sha256sum "$hook_path" | awk '{print $1}')
      installed_policy_checksum=$(sha256sum "$HOOK_CONFIG" | awk '{print $1}')
      systemctl daemon-reload
      systemctl enable --now reconcile-backup-jobs.timer
    else
      temporary="${hook_path}.tmp.$$"
      policy_temporary="${HOOK_CONFIG}.tmp.$$"
      ssh -o BatchMode=yes -o ConnectTimeout=10 "$node" "umask 077; cat >'$temporary'; install -D -o root -g root -m 0755 '$temporary' '$hook_path'; rm -f '$temporary'" <"$HOOK_SOURCE"
      printf '%s\n' "$policy" | ssh -o BatchMode=yes -o ConnectTimeout=10 "$node" "umask 077; cat >'$policy_temporary'; install -D -o root -g root -m 0600 '$policy_temporary' '$HOOK_CONFIG'; rm -f '$policy_temporary'"
      ssh -o BatchMode=yes -o ConnectTimeout=10 "$node" "install -D -o root -g root -m 0755 /dev/stdin /usr/local/sbin/reconcile-backup-jobs" <"$RECONCILER_SOURCE"
      ssh -o BatchMode=yes -o ConnectTimeout=10 "$node" "install -D -o root -g root -m 0644 /dev/stdin /etc/systemd/system/reconcile-backup-jobs.service" <"$RECONCILER_SERVICE"
      ssh -o BatchMode=yes -o ConnectTimeout=10 "$node" "install -D -o root -g root -m 0644 /dev/stdin /etc/systemd/system/reconcile-backup-jobs.timer" <"$RECONCILER_TIMER"
      installed_checksum=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$node" "sha256sum '$hook_path' | cut -d ' ' -f 1")
      installed_policy_checksum=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$node" "sha256sum '$HOOK_CONFIG' | cut -d ' ' -f 1")
      ssh -o BatchMode=yes -o ConnectTimeout=10 "$node" "systemctl daemon-reload && systemctl enable --now reconcile-backup-jobs.timer"
    fi
    [[ "$installed_checksum" == "$checksum" ]] || { echo "ERROR: Hook checksum mismatch on ${node}." >&2; return 1; }
    [[ "$installed_policy_checksum" == "$policy_checksum" ]] || { echo "ERROR: Hook policy checksum mismatch on ${node}." >&2; return 1; }
    echo "Installed and verified hook on ${node}."
  done < <(online_nodes)
}

verify_hook_cluster() {
  local node hook_path expected actual policy expected_policy actual_policy
  hook_path=$(config_get_backup_hook_path)
  expected=$(sha256sum "$HOOK_SOURCE" | awk '{print $1}')
  policy=$(hook_policy_content)
  expected_policy=$(printf '%s\n' "$policy" | sha256sum | awk '{print $1}')
  while IFS= read -r node; do
    if [[ "$node" == "$(hostname -s)" ]]; then
      actual=$(sha256sum "$hook_path" 2>/dev/null | awk '{print $1}' || true)
      actual_policy=$(sha256sum "$HOOK_CONFIG" 2>/dev/null | awk '{print $1}' || true)
      [[ -x "$hook_path" ]] || actual=""
    else
      actual=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$node" \
        "test -x '$hook_path' && sha256sum '$hook_path' | cut -d ' ' -f 1" 2>/dev/null || true)
      actual_policy=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$node" \
        "test -r '$HOOK_CONFIG' && sha256sum '$HOOK_CONFIG' | cut -d ' ' -f 1" 2>/dev/null || true)
    fi
    [[ "$actual" == "$expected" ]] || { echo "ERROR: Hook is missing or differs on ${node}." >&2; return 1; }
    [[ "$actual_policy" == "$expected_policy" ]] || { echo "ERROR: Hook policy is missing or differs on ${node}." >&2; return 1; }
  done < <(online_nodes)
}

cluster_lxc_ids() {
  backup_resource_ids lxc
}

calculate_temp_size_gib() {
  local resources="${1:-}" multiplier maximum_bytes exclude_tags
  [[ -n "$resources" ]] || resources=$(pvesh get /cluster/resources --type vm --output-format json)
  multiplier=$(config_get_backup_temp_size_multiplier)
  exclude_tags=$(config_get_backup_exclude_tags)
  maximum_bytes=$(jq -er --argjson excluded "$exclude_tags" '[.[]
    | select(.type == "lxc")
    | select(((.tags // "") | split(";")) as $tags
        | all($excluded[]; . as $tag | ($tags | index($tag)) == null))
    | .maxdisk
    | select(type == "number" and . > 0)]
    | max' <<<"$resources") || {
      echo "ERROR: Cannot determine the largest production CT rootfs." >&2
      return 1
    }
    printf '%s\n' "$(( (maximum_bytes * multiplier + 1073741823) / 1073741824 ))"
}

reconcile_temp_pve_storage() {
  local storage_id="$1" mountpoint="$2" nodes="$3" existing type path
  if existing=$(pvesh get "/storage/${storage_id}" --output-format json 2>/dev/null); then
    type=$(jq -r '.type // ""' <<<"$existing")
    path=$(jq -r '.path // ""' <<<"$existing")
    [[ "$type" == dir && "$path" == "$mountpoint" ]] || {
      echo "ERROR: Existing PVE storage ${storage_id} is ${type}:${path}, expected dir:${mountpoint}." >&2
      return 1
    }
    if [[ "$DRY_RUN" == true ]]; then
      echo "Would update PVE storage ${storage_id}: nodes=${nodes}, content=snippets, is_mountpoint=1."
    else
      pvesh set "/storage/${storage_id}" --nodes "$nodes" --content snippets --is_mountpoint 1 --disable 0
      echo "Updated visible PVE storage ${storage_id}."
    fi
  elif [[ "$DRY_RUN" == true ]]; then
    echo "Would register PVE directory storage ${storage_id} at ${mountpoint}: nodes=${nodes}, content=snippets, is_mountpoint=1."
  else
    pvesh create /storage --storage "$storage_id" --type dir --path "$mountpoint" \
      --nodes "$nodes" --content snippets --is_mountpoint 1
    echo "Registered visible PVE storage ${storage_id}."
  fi
}

provision_temp_cluster() {
  local resources target_gib node failed=false nodes_csv
  local storage_id vg thin_pool lv filesystem headroom mountpoint
  resources=$(pvesh get /cluster/resources --type vm --output-format json)
  target_gib=$(calculate_temp_size_gib "$resources")
  storage_id=$(config_get_backup_temp_storage_id)
  vg=$(config_get_backup_temp_vg)
  thin_pool=$(config_get_backup_temp_thin_pool)
  lv=$(config_get_backup_temp_lv)
  filesystem=$(config_get_backup_temp_filesystem)
  headroom=$(config_get_backup_temp_headroom_percent)
  mountpoint=$(dirname "$(config_get_backup_tmpdir)")
  echo "TEMP target: ${target_gib} GiB (twice the largest production CT rootfs)."
  nodes_csv=$(online_nodes | paste -sd,)
  [[ -n "$nodes_csv" ]] || { echo "ERROR: No online PVE nodes found." >&2; return 1; }
  while IFS= read -r node; do
    echo "Reconciling TEMP storage on ${node}..."
    if [[ "$node" == "$(hostname -s)" ]]; then
      if ! TEMP_VG="$vg" TEMP_THIN_POOL="$thin_pool" TEMP_LV="$lv" TEMP_FILESYSTEM="$filesystem" \
        TEMP_HEADROOM_PERCENT="$headroom" TEMP_MOUNTPOINT="$mountpoint" TEMP_TARGET_GIB="$target_gib" \
        TEMP_DRY_RUN="$DRY_RUN" "$TEMP_PROVISIONER"; then
        failed=true
      fi
    elif ! ssh -o BatchMode=yes -o ConnectTimeout=10 "$node" \
      "TEMP_VG='$vg' TEMP_THIN_POOL='$thin_pool' TEMP_LV='$lv' TEMP_FILESYSTEM='$filesystem' TEMP_HEADROOM_PERCENT='$headroom' TEMP_MOUNTPOINT='$mountpoint' TEMP_TARGET_GIB='$target_gib' TEMP_DRY_RUN='$DRY_RUN' bash -s" \
      <"$TEMP_PROVISIONER"; then
      failed=true
    fi
  done < <(tr ',' '\n' <<<"$nodes_csv")
  [[ "$failed" == false ]] || return 1
  reconcile_temp_pve_storage "$storage_id" "$mountpoint" "$nodes_csv"
}

configure_job() {
  local job_id storage schedule repeat_missed compress prune_policy
  local bwlimit ionice notification_mode hook_path tmpdir vmids enabled_value repeat_value
  prepare_backup_tmpdir_cluster
  audit_cluster
  verify_hook_cluster
  job_id=$(config_get_backup_job_id)
  storage=$(config_get_backup_storage)
  schedule=$(config_get_backup_schedule)
  repeat_missed=$(config_get_backup_repeat_missed)
  compress=$(config_get_backup_compress)
  prune_policy=$(config_get_backup_prune_policy)
  bwlimit=$(config_get_backup_bwlimit_kib)
  ionice=$(config_get_backup_ionice)
  notification_mode=$(config_get_backup_notification_mode)
  hook_path=$(config_get_backup_hook_path)
  tmpdir=$(config_get_backup_tmpdir)
  vmids=$(cluster_lxc_ids)
  [[ -n "$vmids" ]] || { echo "ERROR: No LXCs found for the backup job." >&2; return 1; }
  [[ "$repeat_missed" == true ]] && repeat_value=1 || repeat_value=0
  enabled_value=1
  local arguments=(--storage "$storage" --mode suspend --compress "$compress" --schedule "$schedule"
    --repeat-missed "$repeat_value" --enabled "$enabled_value" --vmid "$vmids" --script "$hook_path"
    --tmpdir "$tmpdir"
    --prune-backups "$prune_policy"
    --ionice "$ionice" --notification-mode "$notification_mode")
  (( bwlimit == 0 )) || arguments+=(--bwlimit "$bwlimit")
  if [[ "$DRY_RUN" == true ]]; then
    printf 'Would reconcile /cluster/backup/%s with:' "$job_id"
    printf ' %q' "${arguments[@]}"
    printf '\n'
  elif pvesh get "/cluster/backup/${job_id}" >/dev/null 2>&1; then
    pvesh set "/cluster/backup/${job_id}" "${arguments[@]}"
    echo "Updated cluster backup job ${job_id}."
  else
    pvesh create /cluster/backup --id "$job_id" "${arguments[@]}"
    echo "Created cluster backup job ${job_id}."
  fi
}

verify_pairs() {
  local storage mount_path resources ctid hostname archive generation age_seconds failed=false now
  storage=$(config_get_backup_storage)
  mount_path="/mnt/pve/${storage}"
  [[ -d "${mount_path}/dump" ]] || { echo "ERROR: Backup dump is unavailable at ${mount_path}/dump." >&2; return 1; }
  resources=$(pvesh get /cluster/resources --type vm --output-format json)
  now=$(date +%s)
  while IFS=$'\t' read -r ctid hostname; do
    archive=$(find "${mount_path}/dump" -maxdepth 1 -type f -name "vzdump-lxc-${ctid}-*.tar.zst" -print | sort -r | head -n 1 || true)
    if [[ -z "$archive" ]]; then
      echo "MISSING CT ${ctid} (${hostname}): no zstd archive"
      failed=true
      continue
    fi
    generation="${mount_path}/workloads/${hostname}/$(basename "${archive%.tar.zst}")"
    if [[ ! -d "${generation}/docker" || ! -d "${generation}/docker-data" ]]; then
      echo "INCOMPLETE CT ${ctid} (${hostname}): $(basename "$archive") has no matching workload generation"
      failed=true
      continue
    fi
    age_seconds=$((now - $(stat -c %Y "$archive")))
    if (( age_seconds > 93600 )); then
      echo "STALE CT ${ctid} (${hostname}): complete pair is $((age_seconds / 3600))h old"
      failed=true
    else
      echo "OK CT ${ctid} (${hostname}): $(basename "$archive")"
    fi
  done < <(jq -r '.[] | select(.type == "lxc" and (((.tags // "") | split(";")) | index("backup-restore-test") | not)) | [.vmid, .name] | @tsv' <<<"$resources" | sort -n)
  [[ "$failed" == false ]]
}

resolve_cluster_ct() {
  local input="$1" resources match_count
  resources=$(pvesh get /cluster/resources --type vm --output-format json)
  if [[ "$input" =~ ^[0-9]+$ ]]; then
    match_count=$(jq --argjson id "$input" '[.[] | select(.type == "lxc" and .vmid == $id)] | length' <<<"$resources")
    [[ "$match_count" == 1 ]] || { echo "ERROR: CT ${input} was not found exactly once." >&2; return 1; }
    CTID="$input"
  else
    match_count=$(jq --arg name "$input" '[.[] | select(.type == "lxc" and .name == $name)] | length' <<<"$resources")
    [[ "$match_count" == 1 ]] || { echo "ERROR: Hostname ${input} was not found exactly once." >&2; return 1; }
    CTID=$(jq -r --arg name "$input" '.[] | select(.type == "lxc" and .name == $name) | .vmid' <<<"$resources")
  fi
  CT_HOSTNAME=$(jq -r --argjson id "$CTID" '.[] | select(.type == "lxc" and .vmid == $id) | .name' <<<"$resources")
  SOURCE_NODE=$(jq -r --argjson id "$CTID" '.[] | select(.type == "lxc" and .vmid == $id) | .node' <<<"$resources")
}

run_node_shell() {
  local node="$1" command="$2"
  if [[ "$node" == "$(hostname -s)" ]]; then sh -c "$command"; else ssh -o BatchMode=yes -o ConnectTimeout=10 "$node" "$command"; fi
}

restore_test() {
  local source="$1" storage mount_path archive stem generation node docker_temp data_temp resources command reply restore_bridge restore_reason
  [[ "$RESTORE_ID" =~ ^[1-9][0-9]+$ ]] || { echo "ERROR: --restore-id with an unused numeric CTID is required." >&2; return 1; }
  resolve_cluster_ct "$source"
  resources=$(pvesh get /cluster/resources --type vm --output-format json)
  [[ "$(jq --argjson id "$RESTORE_ID" '[.[] | select(.vmid == $id)] | length' <<<"$resources")" == 0 ]] || {
    echo "ERROR: Restore CTID ${RESTORE_ID} already exists." >&2
    return 1
  }
  storage=$(config_get_backup_storage)
  mount_path="/mnt/pve/${storage}"
  archive=$(find "${mount_path}/dump" -maxdepth 1 -type f -name "vzdump-lxc-${CTID}-*.tar.zst" -print | sort -r | head -n 1 || true)
  [[ -n "$archive" ]] || { echo "ERROR: No zstd archive exists for CT ${CTID}." >&2; return 1; }
  stem=$(basename "${archive%.tar.zst}")
  generation="${mount_path}/workloads/${CT_HOSTNAME}/${stem}"
  [[ -d "${generation}/docker" && -d "${generation}/docker-data" ]] || {
    echo "ERROR: Archive ${archive} has no complete workload generation." >&2
    return 1
  }
  node="${RESTORE_NODE:-$SOURCE_NODE}"
  if ! online_nodes | grep -Fxq "$node"; then
    echo "ERROR: Restore node ${node} is not online." >&2
    return 1
  fi
  bridge_policy_resolve "$node" CT "$RESTORE_ID" "$CT_HOSTNAME" || return 1
  restore_bridge="$BRIDGE_POLICY_SELECTED"
  restore_reason="$BRIDGE_POLICY_REASON"
  docker_temp="/mnt/docker/.restore-${RESTORE_ID}-${CT_HOSTNAME}"
  data_temp="/mnt/docker-data/.restore-${RESTORE_ID}-${CT_HOSTNAME}"
  command="test ! -e '$docker_temp' && test ! -e '$data_temp'"
  run_node_shell "$node" "$command" || { echo "ERROR: Restore staging paths already exist on ${node}." >&2; return 1; }

  echo "Restore test plan:"
  echo "  Source: CT ${CTID} (${CT_HOSTNAME})"
  echo "  Pair:   $(basename "$archive")"
  echo "  Target: CT ${RESTORE_ID} on ${node}, bridge ${restore_bridge} (${restore_reason}), all NICs link down"
  echo "  Data:   ${docker_temp} and ${data_temp}"
  if [[ "$DRY_RUN" == true ]]; then
    echo "[dry-run] Would stage both workload trees, restore the rootfs, replace bind mounts, validate Compose, and stop CT ${RESTORE_ID}."
    return 0
  fi
  if [[ "$FORCE" != true ]]; then
    read -rp "Create this isolated restore test? [y/N]: " reply
    [[ "$reply" =~ ^[Yy]$ ]] || { echo "Aborted."; return 0; }
  fi

  run_node_shell "$node" "mkdir '$docker_temp' '$data_temp'"
  if ! run_node_shell "$node" "rsync -aHAXS --numeric-ids --delete '${generation}/docker/' '${docker_temp}/' && rsync -aHAXS --numeric-ids --delete '${generation}/docker-data/' '${data_temp}/'"; then
    run_node_shell "$node" "rm -rf --one-file-system '$docker_temp' '$data_temp'" || true
    return 1
  fi
  run_node_shell "$node" "test -z \"\$(rsync -aHAXSni --numeric-ids --delete '${generation}/docker/' '${docker_temp}/')\" && test -z \"\$(rsync -aHAXSni --numeric-ids --delete '${generation}/docker-data/' '${data_temp}/')\"" || return 1
  if ! run_on_node "$node" pct restore "$RESTORE_ID" "$archive" --storage DATA --unprivileged 1; then
    run_node_shell "$node" "rm -rf --one-file-system '$docker_temp' '$data_temp'" || true
    return 1
  fi
  run_on_node "$node" pct set "$RESTORE_ID" -tags backup-restore-test
  command="for mp in \$(pct config '$RESTORE_ID' | awk -F: '/^mp[0-9]+:/ {print \$1}'); do pct set '$RESTORE_ID' -delete \"\$mp\"; done"
  run_node_shell "$node" "$command"
  run_on_node "$node" pct set "$RESTORE_ID" -mp0 "${docker_temp},mp=/mnt/docker" -mp1 "${data_temp},mp=/mnt/docker-data"
  bridge_policy_reconcile_guest "$node" CT "$RESTORE_ID" "$restore_bridge" false true
  run_on_node "$node" pct start "$RESTORE_ID"
  if ! run_node_shell "$node" "pct exec '$RESTORE_ID' -- sh -c 'cd /mnt/docker && docker compose config --quiet'"; then
    run_on_node "$node" pct stop "$RESTORE_ID" || true
    echo "ERROR: Restored Compose configuration is invalid; CT ${RESTORE_ID} remains stopped for inspection." >&2
    return 1
  fi
  run_on_node "$node" pct stop "$RESTORE_ID"
  echo "Restore test passed. CT ${RESTORE_ID} is stopped with network disabled and isolated data staged for inspection."
}

run_backup() {
  local target="$1" storage hook_path tmpdir mode compress bwlimit ionice ctid node resources vmids
  storage=$(config_get_backup_storage)
  hook_path=$(config_get_backup_hook_path)
  tmpdir=$(config_get_backup_tmpdir)
  mode=$(config_get_backup_mode)
  compress=$(config_get_backup_compress)
  bwlimit=$(config_get_backup_bwlimit_kib)
  ionice=$(config_get_backup_ionice)
  local ctids=()
  resources=$(pvesh get /cluster/resources --type vm --output-format json)
  if [[ "$target" == all ]]; then
    vmids=$(jq -r '.[] | select(.type == "lxc" and (((.tags // "") | split(";")) | index("backup-restore-test") | not)) | .vmid' <<<"$resources" | sort -n)
    mapfile -t ctids <<<"$vmids"
  else
    resolve_cluster_ct "$target"
    ctids=("$CTID")
  fi
  for ctid in "${ctids[@]}"; do
    node=$(jq -r --argjson id "$ctid" '.[] | select(.vmid == $id and .type == "lxc") | .node' <<<"$resources")
    [[ -n "$node" ]] || { echo "ERROR: Cannot resolve node for CT ${ctid}." >&2; return 1; }
    if [[ "$DRY_RUN" != true ]]; then
      run_on_node "$node" install -d -o root -g root -m 1777 "$tmpdir"
      run_on_node "$node" chmod 1777 "$tmpdir"
    fi
    local command=(vzdump "$ctid" --storage "$storage" --tmpdir "$tmpdir" --mode "$mode" --compress "$compress" --script "$hook_path" --ionice "$ionice")
    (( bwlimit == 0 )) || command+=(--bwlimit "$bwlimit")
    if [[ "$DRY_RUN" == true ]]; then
      printf 'Would run on %s:' "$node"
      printf ' %q' "${command[@]}"
      printf '\n'
    else
      echo "Starting Proxmox suspend backup for CT ${ctid} on ${node}; the first workload generation is a full NFS transfer."
      run_on_node "$node" "${command[@]}"
    fi
  done
}

main() {
  lifecycle_log_init "${BASH_SOURCE[0]}" "$@"
  [[ $# -gt 0 ]] || { usage; return 1; }
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --audit|--install-prerequisites|--provision-temp|--install-hook|--configure-job|--verify) [[ -z "$ACTION" ]] || { echo "ERROR: Specify one action." >&2; return 1; }; ACTION="$1"; shift ;;
      --run|--restore-test) [[ -z "$ACTION" ]] || { echo "ERROR: Specify one action." >&2; return 1; }; ACTION="$1"; RUN_TARGET="${2:-}"; [[ -n "$RUN_TARGET" ]] || { echo "ERROR: $1 requires a CT or all." >&2; return 1; }; shift 2 ;;
      --restore-id) [[ -n "${2:-}" ]] || { echo "ERROR: --restore-id requires a CTID." >&2; return 1; }; RESTORE_ID="$2"; shift 2 ;;
      --node) [[ -n "${2:-}" ]] || { echo "ERROR: --node requires a node." >&2; return 1; }; RESTORE_NODE="$2"; shift 2 ;;
      --force) FORCE=true; shift ;;
      --dry-run) DRY_RUN=true; shift ;;
      -h|--help) usage; return 0 ;;
      *) echo "ERROR: Unknown option: $1" >&2; usage; return 1 ;;
    esac
  done
  validate_backup_config
  [[ -f "$HOOK_SOURCE" ]] || { echo "ERROR: Hook source is missing: ${HOOK_SOURCE}" >&2; return 1; }
  [[ -f "$TEMP_PROVISIONER" ]] || { echo "ERROR: TEMP provisioner is missing: ${TEMP_PROVISIONER}" >&2; return 1; }
  case "$ACTION" in
    --audit) audit_cluster ;;
    --install-prerequisites) install_prerequisites_cluster ;;
    --provision-temp) provision_temp_cluster ;;
    --install-hook) install_hook_cluster ;;
    --run) run_backup "$RUN_TARGET" ;;
    --configure-job) configure_job ;;
    --verify) verify_pairs ;;
    --restore-test) restore_test "$RUN_TARGET" ;;
    *) usage; return 1 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi