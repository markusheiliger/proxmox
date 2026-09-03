#!/usr/bin/env bash
#
# deleteCT.sh - Delete a Proxmox LXC container
# Documentation: deleteCT.md
#
# DESCRIPTION:
#   Destroys an existing LXC container on Proxmox VE with options to:
#   - Select container interactively from a list
#   - Specify container by CTID or hostname
#   - Optionally delete related data folders
#
# USAGE:
#   ./deleteCT.sh [CTID or hostname] [--force] [--dry-run]
#
# OPTIONS:
#   --force     Skip all confirmation prompts and delete container + folders
#   --dry-run   Validate and preview the selected deletion without changes
#
# EXAMPLES:
#   ./deleteCT.sh                      # Interactive selection with confirmations
#   ./deleteCT.sh 2100                 # Delete by CTID with confirmations
#   ./deleteCT.sh app.thesaints.home   # Delete by hostname with confirmations
#   ./deleteCT.sh 2100 --force         # Delete by CTID, skip confirmations
#   ./deleteCT.sh app.thesaints.home --force   # Delete by hostname, skip confirmations
#   ./deleteCT.sh --force              # Interactive selection, skip confirmations
#
# BEHAVIOR:
#   - Without arguments: displays list of containers to choose from
#   - With CTID/hostname: looks up container by CTID (numeric) or hostname
#   - Without --force: asks for confirmation before destroying and before deleting folders
#   - With --force: skips all prompts, automatically deletes container and related folders
#
# REQUIREMENTS:
#   - Run on Proxmox VE host as root
#
# SEE ALSO:
#   createCT.sh      Create a new container with Docker
#   refreshCT.sh     Refresh/update container configuration
#   commonCT.sh      Shared functions
#
set -euo pipefail

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/commonCT.sh"

# Global flags
FORCE=false
DRY_RUN=false
DELETE_FOLDERS=false
DIR_DOCKER=""
DIR_DOCKER_DATA=""

# -----------------------------
# FUNCTIONS
# -----------------------------

# Confirm destruction with user
confirm_destruction() {
  echo ""
  echo "Selected: CT ${CTID} (${CT_HOSTNAME})"
  echo ""
  echo "WARNING: This will destroy CT ${CTID} including all attached drives."
  
  if [[ "$FORCE" == "true" ]]; then
    echo "--force flag set; proceeding without confirmation."
    return
  fi
  
  read -p "Are you sure you want to proceed? [y/N]: " CONFIRM
  
  if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
  fi
}

usage() {
  cat <<'EOF'
Usage: deleteCT.sh [CTID|hostname] [--force] [--dry-run]

  --force    Skip confirmation and select related folders for deletion
  --dry-run  Validate and preview the exact deletion without changes
  -h, --help Show this help
EOF
}

validate_cleanup_path() {
  local path="$1" expected="$2" canonical
  [[ -e "$path" ]] || return 0
  [[ ! -L "$path" ]] || { echo "ERROR: Refusing symlink cleanup path '${path}'." >&2; return 1; }
  canonical=$(realpath -e "$path") || return 1
  [[ "$canonical" == "$expected" ]] || {
    echo "ERROR: Cleanup path drifted: expected '${expected}', found '${canonical}'." >&2
    return 1
  }
}

select_folder_cleanup() {
  get_ct_dirs "$CT_HOSTNAME"

  if [[ ! -d "$DIR_DOCKER" && ! -d "$DIR_DOCKER_DATA" ]]; then
    echo "No related folders found."
    DELETE_FOLDERS=false
    return 0
  fi

  echo ""
  echo "Related folders found:"
  [[ -d "$DIR_DOCKER" ]] && echo "  $DIR_DOCKER"
  [[ -d "$DIR_DOCKER_DATA" ]] && echo "  $DIR_DOCKER_DATA"

  if [[ "$FORCE" == "true" ]]; then
    DELETE_FOLDERS=true
    return 0
  fi

  local reply
  read -rp "Delete these folders? [y/N]: " reply
  [[ "$reply" =~ ^[Yy]$ ]] && DELETE_FOLDERS=true || DELETE_FOLDERS=false
}

print_delete_plan() {
  local volumes folder size
  volumes=$(pct config "$CTID" 2>/dev/null | grep -E '^(rootfs|mp[0-9]+):' || true)

  echo ""
  echo "Deletion plan:"
  echo "  CT:       ${CTID} (${CT_HOSTNAME}) [$(get_ct_status "$CTID")]"
  echo "  Volumes:"
  if [[ -n "$volumes" ]]; then
    while IFS= read -r volume; do echo "    $volume"; done <<< "$volumes"
  else
    echo "    none detected"
  fi
  echo "  Split DNS: would reconcile before CT destruction"

  for folder in "$DIR_DOCKER" "$DIR_DOCKER_DATA"; do
    [[ -e "$folder" ]] || continue
    size=$(du -sh -- "$folder" 2>/dev/null | awk '{print $1}' || true)
    if [[ "$DELETE_FOLDERS" == "true" ]]; then
      echo "  Data:     delete ${folder} (${size:-unknown size})"
    else
      echo "  Data:     retain ${folder} (${size:-unknown size})"
    fi
  done
}

# Destroy the container
destroy_ct() {
  echo "Destroying CT ${CTID}..."

  # Reconcile split DNS before deleting non-primary domain CTs.
  if [[ -x "${SCRIPT_DIR}/forwardDNSCT.sh" ]]; then
    "${SCRIPT_DIR}/forwardDNSCT.sh" >/dev/null 2>&1 || true
  fi

  pct destroy "$CTID" --purge --force
  echo "CT ${CTID} destroyed."
}

# Offer to clean up related data folders
cleanup_folders() {
  if [[ "$DELETE_FOLDERS" != "true" ]]; then
    echo "Folders kept."
    return 0
  fi

  [[ -d "$DIR_DOCKER" ]] && rm -rf --one-file-system -- "$DIR_DOCKER" && echo "Deleted: $DIR_DOCKER"
  [[ -d "$DIR_DOCKER_DATA" ]] && rm -rf --one-file-system -- "$DIR_DOCKER_DATA" && echo "Deleted: $DIR_DOCKER_DATA"
}

# -----------------------------
# MAIN
# -----------------------------
main() {
  lifecycle_log_init "${BASH_SOURCE[0]}" "$@"
  local container_arg=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force) FORCE=true; shift ;;
      --dry-run) DRY_RUN=true; shift ;;
      -h|--help) usage; exit 0 ;;
      -*) echo "ERROR: unknown option: $1" >&2; usage; exit 1 ;;
      *)
        [[ -z "$container_arg" ]] || { echo "ERROR: only one CT may be deleted." >&2; exit 1; }
        container_arg="$1"
        shift
        ;;
    esac
  done
  
  build_ct_list
  
  if [[ ${#CT_LIST[@]} -eq 0 ]]; then
    echo "No containers found."
    exit 0
  fi
  
  if [[ -z "$container_arg" ]]; then
    select_ct_interactive_single "delete" || exit 1
  else
    resolve_ct_from_input "$container_arg" || exit 1
  fi

  validate_node_storage_contract || exit 1

  confirm_destruction
  select_folder_cleanup
  if [[ "$DELETE_FOLDERS" == "true" ]]; then
    validate_cleanup_path "$DIR_DOCKER" "/mnt/docker/${CT_HOSTNAME}"
    validate_cleanup_path "$DIR_DOCKER_DATA" "/mnt/docker-data/${CT_HOSTNAME}"
  fi
  print_delete_plan

  if [[ "$DRY_RUN" == "true" ]]; then
    echo ""
    echo "[dry-run] No changes made."
    exit 0
  fi
  
  status_bar_init
  
  status_update "Destroying CT ${CTID}..."
  destroy_ct
  
  status_update "Cleaning up folders..."
  cleanup_folders
  reconcile_backup_job_selections || echo "  [!] Could not refresh managed backup job membership."
  
  status_bar_cleanup
  
  echo ""
  echo "Done."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
