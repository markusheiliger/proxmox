#!/usr/bin/env bash
#
# deleteCT.sh - Delete a Proxmox LXC container
#
# DESCRIPTION:
#   Destroys an existing LXC container on Proxmox VE with options to:
#   - Select container interactively from a list
#   - Specify container by CTID or hostname
#   - Optionally delete related data folders
#
# USAGE:
#   ./deleteCT.sh [CTID or hostname]
#
# EXAMPLES:
#   ./deleteCT.sh                      # Interactive selection
#   ./deleteCT.sh 2100                 # Delete by CTID
#   ./deleteCT.sh app.thesaints.home   # Delete by hostname
#
# BEHAVIOR:
#   - Without arguments: displays list of containers to choose from
#   - With argument: looks up container by CTID (numeric) or hostname
#   - Always asks for confirmation before destroying
#   - Offers to delete /mnt/docker/<hostname> and /mnt/docker-data/<hostname>
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

# -----------------------------
# FUNCTIONS
# -----------------------------

# Confirm destruction with user
confirm_destruction() {
  echo ""
  echo "Selected: CT ${CTID} (${CT_HOSTNAME})"
  echo ""
  echo "WARNING: This will destroy CT ${CTID} including all attached drives."
  read -p "Are you sure you want to proceed? [y/N]: " CONFIRM
  
  if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
  fi
}

# Destroy the container
destroy_ct() {
  echo "Destroying CT ${CTID}..."
  pct destroy "$CTID" --purge --force
  echo "CT ${CTID} destroyed."
}

# Offer to clean up related data folders
cleanup_folders() {
  get_ct_dirs "$CT_HOSTNAME"
  
  local folders_exist=false
  [[ -d "$DIR_DOCKER" ]] && folders_exist=true
  [[ -d "$DIR_DOCKER_DATA" ]] && folders_exist=true
  
  if [[ "$folders_exist" == "true" ]]; then
    echo ""
    echo "Related folders found:"
    [[ -d "$DIR_DOCKER" ]] && echo "  $DIR_DOCKER"
    [[ -d "$DIR_DOCKER_DATA" ]] && echo "  $DIR_DOCKER_DATA"
    echo ""
    read -p "Delete these folders? [y/N]: " REPLY
    
    if [[ "$REPLY" =~ ^[Yy]$ ]]; then
      [[ -d "$DIR_DOCKER" ]] && rm -rf "$DIR_DOCKER" && echo "Deleted: $DIR_DOCKER"
      [[ -d "$DIR_DOCKER_DATA" ]] && rm -rf "$DIR_DOCKER_DATA" && echo "Deleted: $DIR_DOCKER_DATA"
    else
      echo "Folders kept."
    fi
  else
    echo "No related folders found."
  fi
}

# -----------------------------
# MAIN
# -----------------------------
main() {
  build_ct_list
  
  if [[ ${#CT_LIST[@]} -eq 0 ]]; then
    echo "No containers found."
    exit 0
  fi
  
  if [[ $# -lt 1 ]]; then
    select_ct_interactive_single "delete" || exit 1
  else
    resolve_ct_from_input "$1" || exit 1
  fi
  
  confirm_destruction
  
  status_bar_init
  
  status_update "Destroying CT ${CTID}..."
  destroy_ct
  
  status_update "Cleaning up folders..."
  cleanup_folders
  
  status_bar_cleanup
  
  echo ""
  echo "Done."
}

main "$@"
