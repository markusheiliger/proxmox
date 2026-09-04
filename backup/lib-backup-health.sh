#!/usr/bin/env bash

BACKUP_MAX_AGE_SECONDS="${BACKUP_MAX_AGE_SECONDS:-93600}"
BACKUP_EXCLUDE_TAGS="${BACKUP_EXCLUDE_TAGS:-no-backup,backup-restore-test}"

backup_node_has_active_vzdump() {
  local node="$1" tasks
  tasks=$(pvesh get "/nodes/${node}/tasks" --source active --typefilter vzdump --output-format json 2>/dev/null) || {
    echo "ERROR: Cannot inspect active backup tasks on ${node}; refusing to classify backup locks." >&2
    return 2
  }
  jq -e 'any(.[]; .type == "vzdump")' <<<"$tasks" >/dev/null
}

latest_complete_ct_pair_epoch() {
  local mount_path="$1" ctid="$2" hostname="$3" archive generation
  while IFS= read -r archive; do
    generation="${mount_path}/workloads/${hostname}/$(basename "${archive%.tar.zst}")"
    if [[ -d "${generation}/docker" && -d "${generation}/docker-data" ]]; then
      stat -c %Y "$archive"
      return 0
    fi
  done < <(find "${mount_path}/dump" -maxdepth 1 -type f -name "vzdump-lxc-${ctid}-*.tar.zst" -print 2>/dev/null | sort -r)
  return 1
}

check_stale_backup_locks() {
  local resources="$1" mount_path="$2" now failed=false
  local ctid hostname node config lock pair_epoch age_seconds active_status
  now=$(date +%s)
  while IFS=$'\t' read -r ctid hostname node; do
    config=$(pvesh get "/nodes/${node}/lxc/${ctid}/config" --output-format json 2>/dev/null) || {
      echo "ERROR: Cannot inspect CT ${ctid} configuration on ${node}." >&2
      failed=true
      continue
    }
    lock=$(jq -r '.lock // ""' <<<"$config")
    [[ "$lock" == backup ]] || continue

    active_status=0
    backup_node_has_active_vzdump "$node" || active_status=$?
    if (( active_status == 0 )); then
      echo "ACTIVE LOCK CT ${ctid} (${hostname}): backup task is running on ${node}"
      continue
    elif (( active_status == 2 )); then
      failed=true
      continue
    fi

    pair_epoch=$(latest_complete_ct_pair_epoch "$mount_path" "$ctid" "$hostname" || true)
    if [[ -n "$pair_epoch" ]]; then
      age_seconds=$((now - pair_epoch))
      if (( age_seconds <= BACKUP_MAX_AGE_SECONDS )); then
        echo "RECENT LOCK CT ${ctid} (${hostname}): no active backup task; newest complete pair is $((age_seconds / 3600))h old"
        continue
      fi
      echo "STALE LOCK CT ${ctid} (${hostname}): no active backup task on ${node}; newest complete pair is $((age_seconds / 3600))h old; inspect tasks, then run pct unlock ${ctid}" >&2
    else
      echo "STALE LOCK CT ${ctid} (${hostname}): no active backup task on ${node} and no complete pair; inspect tasks, then run pct unlock ${ctid}" >&2
    fi
    failed=true
  done < <(jq -r --arg excluded ",${BACKUP_EXCLUDE_TAGS}," '.[]
    | select(.type == "lxc")
    | select((.tags // "") as $tags
        | all(($tags | split(";")[]); . as $tag | ($excluded | contains("," + $tag + ",") | not)))
    | [.vmid, .name, .node] | @tsv' <<<"$resources" | sort -n)
  [[ "$failed" == false ]]
}