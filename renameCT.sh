#!/usr/bin/env bash
#
# renameCT.sh - Rename a Proxmox LXC container end-to-end
# Documentation: renameCT.md
#
# DESCRIPTION:
#   Renames an existing CT from one hostname to another, keeping every piece of
#   derived state in sync:
#     - the Proxmox CT hostname (pct set -hostname)
#     - the per-CT bind-mount source folders
#         /mnt/docker/<old>      -> /mnt/docker/<new>
#         /mnt/docker-data/<old> -> /mnt/docker-data/<new>
#     - the CT mount points (mp0/mp1) pointing at the new folders
#     - the UDM Pro client alias + local DNS record (reuses udmpro_make_static)
#     - commonCT.json (textual replace of every old-hostname occurrence)
#     - every /mnt/docker/*/.env (textual replace of every old-hostname occurrence)
#
#   After the rename the target CT is started, then refreshCT.sh is run for the
#   renamed CT first (so its Compose stack is re-applied under the new identity and
#   re-issues its TLS cert) and afterwards for every other container so they pick up
#   the commonCT.json/.env changes.
#
# USAGE:
#   ./renameCT.sh <old-hostname> <new-hostname> [--force] [--dry-run]
#
# EXAMPLES:
#   ./renameCT.sh app.thesaints.home web.thesaints.home
#   ./renameCT.sh app.thesaints.home web.thesaints.home --force
#
# VALIDATION (no changes are made unless all pass):
#   - Neither argument may be a CTID (numeric); both must be hostnames.
#   - The OLD hostname must resolve to exactly one existing CT.
#   - The NEW hostname must NOT already exist (and its target folders must be absent).
#   - Both hostnames' domains must be configured in commonCT.json.
#
# OPTIONS:
#   --force     Skip the confirmation prompt.
#
# REQUIREMENTS:
#   - Run on the Proxmox VE host as root.
#
# SEE ALSO:
#   createCT.sh   refreshCT.sh   deleteCT.sh   commonCT.sh
#
set -euo pipefail

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/commonCT.sh"

# -----------------------------
# GLOBAL VARIABLES
# -----------------------------

FORCE=false
DRY_RUN=false
OLD_HOSTNAME=""
NEW_HOSTNAME=""
CTID=""
CT_MAC=""
CT_IP=""
OLD_DOCKER=""
OLD_DATA=""
NEW_DOCKER=""
NEW_DATA=""
OLD_BACKUP_HISTORY=""
NEW_BACKUP_HISTORY=""
ORIGINAL_STATUS=""
ORIGINAL_MOUNTS=""
RENAME_BRIDGE=""
RENAME_BRIDGE_REASON=""
COMMONCT_OCCURRENCES=0
declare -a RENAME_ENV_FILES=()
declare -a RENAME_ENV_COUNTS=()
declare -a REFRESH_HOSTS=()

# -----------------------------
# FUNCTIONS
# -----------------------------

usage() {
  cat <<'EOF'
Usage: renameCT.sh <old-hostname> <new-hostname> [--force] [--dry-run]

Renames an existing CT (hostname, folders, mounts, UDM alias, commonCT.json and
all .env files), restarts it, then refreshes every other CT.

Arguments:
  <old-hostname>   Current hostname of the CT to rename (must exist; not a CTID).
  <new-hostname>   New hostname (must NOT exist; not a CTID).

Options:
  --force          Skip the confirmation prompt.
  --dry-run        Validate and preview every rename mutation without changes.
  -h, --help       Show this help and exit.
EOF
}

ensure_jq() {
  command -v jq &>/dev/null && return 0
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "ERROR: jq is required for rename validation; dry-run will not install it." >&2
    return 1
  fi
  echo "Installing jq on Proxmox host..."
  apt-get update -qq
  apt-get install -y -qq jq
}

# Validate both hostnames and resolve the target CTID. Captures MAC + IP while the
# CT is still running (needed for the UDM Pro alias update after it is stopped).
validate_inputs() {
  # a) Neither argument may be a CTID.
  if [[ "$OLD_HOSTNAME" =~ ^[0-9]+$ ]]; then
    echo "ERROR: first argument must be a hostname, not a CTID."
    exit 1
  fi
  if [[ "$NEW_HOSTNAME" =~ ^[0-9]+$ ]]; then
    echo "ERROR: second argument must be a hostname, not a CTID."
    exit 1
  fi
  if [[ "$OLD_HOSTNAME" == "$NEW_HOSTNAME" ]]; then
    echo "ERROR: old and new hostnames are identical."
    exit 1
  fi

  if ! config_exists; then
    echo "ERROR: commonCT.json not found at ${CONFIG_FILE}"
    exit 1
  fi

  # d) Both domains must be configured in commonCT.json.
  local old_domain new_domain
  old_domain=$(extract_domain_from_hostname "$OLD_HOSTNAME")
  new_domain=$(extract_domain_from_hostname "$NEW_HOSTNAME")
  if ! config_domain_exists "$old_domain"; then
    echo "ERROR: domain '${old_domain}' (from ${OLD_HOSTNAME}) is not configured in commonCT.json"
    exit 1
  fi
  if ! config_domain_exists "$new_domain"; then
    echo "ERROR: domain '${new_domain}' (from ${NEW_HOSTNAME}) is not configured in commonCT.json"
    exit 1
  fi

  # b) OLD must resolve to exactly one existing CT.
  build_ct_list
  CTID=""
  local id
  for id in "${CT_LIST[@]}"; do
    if [[ "${CT_MAP[$id]}" == "$OLD_HOSTNAME" ]]; then
      CTID="$id"
      break
    fi
  done
  if [[ -z "$CTID" ]]; then
    echo "ERROR: no CT found with hostname '${OLD_HOSTNAME}'."
    exit 1
  fi

  # c) NEW must not already exist.
  for id in "${CT_LIST[@]}"; do
    if [[ "${CT_MAP[$id]}" == "$NEW_HOSTNAME" ]]; then
      echo "ERROR: a CT with hostname '${NEW_HOSTNAME}' already exists (CTID ${id})."
      exit 1
    fi
  done

  # Resolve folder paths and ensure the NEW folders are absent.
  get_ct_dirs "$OLD_HOSTNAME"
  OLD_DOCKER="$DIR_DOCKER"
  OLD_DATA="$DIR_DOCKER_DATA"
  get_ct_dirs "$NEW_HOSTNAME"
  NEW_DOCKER="$DIR_DOCKER"
  NEW_DATA="$DIR_DOCKER_DATA"
  if [[ -e "$NEW_DOCKER" || -e "$NEW_DATA" ]]; then
    echo "ERROR: target folders already exist:"
    [[ -e "$NEW_DOCKER" ]] && echo "  $NEW_DOCKER"
    [[ -e "$NEW_DATA" ]] && echo "  $NEW_DATA"
    exit 1
  fi

  if validate_backup_config >/dev/null 2>&1; then
    local backup_mount
    backup_mount="/mnt/pve/$(config_get_backup_storage)"
    OLD_BACKUP_HISTORY="${backup_mount}/workloads/${OLD_HOSTNAME}"
    NEW_BACKUP_HISTORY="${backup_mount}/workloads/${NEW_HOSTNAME}"
    if [[ -e "$NEW_BACKUP_HISTORY" ]]; then
      echo "ERROR: target backup history already exists: ${NEW_BACKUP_HISTORY}" >&2
      exit 1
    fi
  fi

  # Capture MAC + IP now (CT is running). The UDM Pro alias update in step (e)
  # needs them, and a stopped CT exposes no IP.
  CT_MAC=$(pct config "$CTID" 2>/dev/null | grep -oP 'hwaddr=\K[^,]+' | tr '[:upper:]' '[:lower:]' || true)
  CT_IP=$(ct_exec --timeout 15 "$CTID" 'ip -4 addr show eth0 2>/dev/null | grep "inet " | tr -s " " | cut -d" " -f3 | cut -d"/" -f1' 2>/dev/null || true)
}

build_rename_plan() {
  local file count id host
  ORIGINAL_STATUS=$(get_ct_status "$CTID")
  ORIGINAL_MOUNTS=$(pct config "$CTID" 2>/dev/null | grep -E '^mp[0-9]+:' || true)
  COMMONCT_OCCURRENCES=$(grep -Fo "$OLD_HOSTNAME" "$CONFIG_FILE" 2>/dev/null | wc -l | tr -d ' ' || true)
  RENAME_ENV_FILES=()
  RENAME_ENV_COUNTS=()
  REFRESH_HOSTS=("$NEW_HOSTNAME")

  for file in /mnt/docker/*/.env; do
    [[ -f "$file" ]] || continue
    count=$(grep -Fo "$OLD_HOSTNAME" "$file" 2>/dev/null | wc -l | tr -d ' ' || true)
    if [[ "${count:-0}" -gt 0 ]]; then
      RENAME_ENV_FILES+=("$file")
      RENAME_ENV_COUNTS+=("$count")
    fi
  done

  for id in "${CT_LIST[@]}"; do
    host="${CT_MAP[$id]}"
    [[ "$id" == "$CTID" ]] && continue
    REFRESH_HOSTS+=("$host")
  done
}

prepare_rename_bridge() {
  bridge_policy_resolve "$(hostname -s)" CT "$CTID" "$NEW_HOSTNAME" || return 1
  RENAME_BRIDGE="$BRIDGE_POLICY_SELECTED"
  RENAME_BRIDGE_REASON="$BRIDGE_POLICY_REASON"
}

# Print the planned changes and confirm (unless --force).
confirm_rename() {
  local index size mounts
  echo ""
  echo "Rename plan:"
  echo "  CT:           ${CTID} [${ORIGINAL_STATUS}] (would stop, rename, then start)"
  echo "  Hostname:     ${OLD_HOSTNAME}  ->  ${NEW_HOSTNAME}"
  echo "  Bridge:       all NICs -> ${RENAME_BRIDGE} (${RENAME_BRIDGE_REASON})"
  bridge_policy_reconcile_guest "$(hostname -s)" CT "$CTID" "$RENAME_BRIDGE" true
  size=$(du -sh -- "$OLD_DOCKER" 2>/dev/null | awk '{print $1}' || true)
  echo "  Docker dir:   ${OLD_DOCKER}  ->  ${NEW_DOCKER} (${size:-unknown size})"
  size=$(du -sh -- "$OLD_DATA" 2>/dev/null | awk '{print $1}' || true)
  echo "  Data dir:     ${OLD_DATA}  ->  ${NEW_DATA} (${size:-unknown size})"
  if [[ -d "$OLD_BACKUP_HISTORY" ]]; then
    echo "  Backups:      ${OLD_BACKUP_HISTORY} -> ${NEW_BACKUP_HISTORY}"
  else
    echo "  Backups:      no workload history to move"
  fi
  echo "  Mounts:"
  mounts="${ORIGINAL_MOUNTS:-none detected}"
  while IFS= read -r mount; do echo "    current: $mount"; done <<< "$mounts"
  echo "    target:  mp0: ${NEW_DOCKER},mp=/mnt/docker"
  echo "    target:  mp1: ${NEW_DATA},mp=/mnt/docker-data"
  if ! config_udmpro_configured; then
    echo "  UDM alias:    skip (UDM Pro not configured)"
  elif [[ -z "$CT_MAC" || -z "$CT_IP" ]]; then
    echo "  UDM alias:    skip (missing MAC or IP)"
  else
    echo "  UDM alias:    ${OLD_HOSTNAME} -> ${NEW_HOSTNAME} (MAC: ${CT_MAC}, IP: ${CT_IP})"
  fi
  echo "  Config:       commonCT.json (${COMMONCT_OCCURRENCES} replacement(s))"
  if [[ ${#RENAME_ENV_FILES[@]} -eq 0 ]]; then
    echo "  Env files:    none"
  else
    echo "  Env files:"
    for index in "${!RENAME_ENV_FILES[@]}"; do
      echo "    ${RENAME_ENV_FILES[$index]} (${RENAME_ENV_COUNTS[$index]} replacement(s))"
    done
  fi
  echo "  Refresh order:"
  for host in "${REFRESH_HOSTS[@]}"; do echo "    refreshCT.sh ${host}"; done
  echo ""

  if [[ "$DRY_RUN" == "true" ]]; then
    return 0
  fi

  if [[ "$FORCE" == "true" ]]; then
    echo "--force set; proceeding without confirmation."
    return
  fi

  read -p "Proceed with the rename? [y/N]: " reply
  if [[ ! "$reply" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
  fi
}

recheck_rename_preconditions() {
  local lock
  if [[ -e "$NEW_DOCKER" || -e "$NEW_DATA" ]]; then
    echo "ERROR: target folders appeared after planning; aborting." >&2
    return 1
  fi
  if [[ -e "$NEW_BACKUP_HISTORY" ]]; then
    echo "ERROR: target backup history appeared after planning; aborting." >&2
    return 1
  fi
  lock=$(pct config "$CTID" 2>/dev/null | sed -n 's/^lock:[[:space:]]*//p' || true)
  if [[ -n "$lock" ]]; then
    echo "ERROR: CT ${CTID} is locked (${lock}); aborting." >&2
    return 1
  fi
}

# Stop the target CT and wait until it is fully stopped.
stop_ct() {
  echo "Stopping CT ${CTID}..."
  pct stop "$CTID"
  local waited=0
  while [[ "$(pct status "$CTID" 2>/dev/null | awk '{print $2}')" != "stopped" ]]; do
    sleep 2
    waited=$((waited + 2))
    if [[ $waited -ge 120 ]]; then
      echo "ERROR: CT ${CTID} did not stop within 120s."
      exit 1
    fi
  done
  echo "  CT ${CTID} stopped."
}

# Re-point the CT bind mounts at the new folders (CT must be stopped).
update_mounts() {
  echo "Updating mount points..."
  local config_output mp
  config_output=$(pct config "$CTID" 2>/dev/null)
  for mp in $(echo "$config_output" | awk -F: '/^mp[0-9]+/ {print $1}'); do
    echo "  deleting $mp"
    pct set "$CTID" -delete "$mp"
  done
  pct set "$CTID" -mp0 "${NEW_DOCKER},mp=/mnt/docker"
  pct set "$CTID" -mp1 "${NEW_DATA},mp=/mnt/docker-data"
  echo "  mp0 -> ${NEW_DOCKER}"
  echo "  mp1 -> ${NEW_DATA}"
}

# Update the UDM Pro client alias + local DNS record to the new hostname.
update_udm_alias() {
  echo "Updating UDM Pro client alias..."
  if ! config_udmpro_configured; then
    echo "  [i] UDM Pro not configured; skipping alias update."
    return 0
  fi
  if [[ -z "$CT_MAC" || -z "$CT_IP" ]]; then
    echo "  [!] Missing CT MAC/IP; skipping UDM Pro alias update."
    return 0
  fi
  udmpro_make_static "$CT_MAC" "$CT_IP" "$NEW_HOSTNAME" || \
    echo "  [!] UDM Pro alias update failed (continuing)."
}

# Build a BRE-safe pattern from the old hostname (only '.' needs escaping for the
# restricted hostname charset). Used as the sed search pattern.
escape_old_hostname() {
  printf '%s' "$OLD_HOSTNAME" | sed 's/\./\\./g'
}

# Textual replace old -> new in commonCT.json, with backup + JSON validation.
patch_commonct_json() {
  echo "Patching commonCT.json..."
  local esc_old count
  esc_old=$(escape_old_hostname)
  count=$(grep -Fc "$OLD_HOSTNAME" "$CONFIG_FILE" 2>/dev/null || true)
  if [[ "${count:-0}" -eq 0 ]]; then
    echo "  [i] No occurrences of '${OLD_HOSTNAME}' in commonCT.json."
    return 0
  fi
  cp -a "$CONFIG_FILE" "${CONFIG_FILE}.bak"
  sed -i "s/${esc_old}/${NEW_HOSTNAME}/g" "$CONFIG_FILE"
  if ! jq empty "$CONFIG_FILE" >/dev/null 2>&1; then
    echo "ERROR: commonCT.json became invalid after replacement; restoring backup."
    mv "${CONFIG_FILE}.bak" "$CONFIG_FILE"
    exit 1
  fi
  rm -f "${CONFIG_FILE}.bak"
  echo "  [~] Replaced ${count} occurrence(s)."
}

# Textual replace old -> new in every /mnt/docker/*/.env (includes the renamed
# target's own .env at its new path).
patch_env_files() {
  echo "Patching .env files..."
  local esc_old f patched=0
  esc_old=$(escape_old_hostname)
  for f in /mnt/docker/*/.env; do
    [[ -f "$f" ]] || continue
    if grep -Fq "$OLD_HOSTNAME" "$f"; then
      sed -i "s/${esc_old}/${NEW_HOSTNAME}/g" "$f"
      echo "  [~] $f"
      patched=$((patched + 1))
    fi
  done
  echo "  [i] Patched ${patched} .env file(s)."
}

# Start the target CT.
start_ct() {
  echo "Starting CT ${CTID}..."
  pct start "$CTID"
  echo "  CT ${CTID} started."
}

# Perform the rename (after validation + confirmation).
do_rename() {
  # a) stop
  stop_ct
  # b) rename the CT hostname
  echo "Setting CT ${CTID} hostname to ${NEW_HOSTNAME}..."
  pct set "$CTID" -hostname "$NEW_HOSTNAME"
  echo "Reconciling all CT NICs to ${RENAME_BRIDGE}..."
  bridge_policy_reconcile_guest "$(hostname -s)" CT "$CTID" "$RENAME_BRIDGE"
  # c) move the per-CT folders
  echo "Moving folders..."
  mv "$OLD_DOCKER" "$NEW_DOCKER"
  echo "  ${OLD_DOCKER} -> ${NEW_DOCKER}"
  mv "$OLD_DATA" "$NEW_DATA"
  echo "  ${OLD_DATA} -> ${NEW_DATA}"
  if [[ -d "$OLD_BACKUP_HISTORY" ]]; then
    mv "$OLD_BACKUP_HISTORY" "$NEW_BACKUP_HISTORY"
    echo "  ${OLD_BACKUP_HISTORY} -> ${NEW_BACKUP_HISTORY}"
  fi
  # d) re-point mounts
  update_mounts
  # e) UDM Pro alias
  update_udm_alias
  # f) commonCT.json
  patch_commonct_json
  # f2) all .env files (before starting the CT)
  patch_env_files
  # g) start
  start_ct
}

# Refresh the renamed CT first, then every other CT. The renamed CT MUST be refreshed:
# `pct start` only resumes the pre-rename containers (Docker bakes env/labels at create
# time), so without a `docker compose` re-apply Caddy keeps serving the OLD hostname and
# has no cert for the new one. Refreshing it first also ensures the Authentik IdP (a common
# rename target) is reachable under the new host before dependents re-register their OIDC.
refresh_cts() {
  echo ""
  echo "Refreshing the renamed CT and all others..."
  local host failures=0

  for host in "${REFRESH_HOSTS[@]}"; do
    echo ""
    echo "=== refreshCT.sh ${host} ==="
    if ! "${SCRIPT_DIR}/refreshCT.sh" "$host"; then
      echo "  [!] refreshCT.sh failed for ${host}"
      failures=$((failures + 1))
    fi
  done
  if [[ $failures -gt 0 ]]; then
    echo ""
    echo "[!] ${failures} CT refresh(es) failed."
    return 1
  fi
}

# -----------------------------
# MAIN
# -----------------------------
main() {
  lifecycle_log_init "${BASH_SOURCE[0]}" "$@"
  local positional=()
  local arg
  for arg in "$@"; do
    case "$arg" in
      --force) FORCE=true ;;
      --dry-run) DRY_RUN=true ;;
      -h|--help) usage; exit 0 ;;
      --*) echo "ERROR: unknown option: $arg"; usage; exit 1 ;;
      *) positional+=("$arg") ;;
    esac
  done

  if [[ ${#positional[@]} -ne 2 ]]; then
    echo "ERROR: exactly two hostnames are required."
    usage
    exit 1
  fi

  OLD_HOSTNAME=$(echo "${positional[0]}" | tr '[:upper:]' '[:lower:]')
  NEW_HOSTNAME=$(echo "${positional[1]}" | tr '[:upper:]' '[:lower:]')

  ensure_jq
  validate_node_storage_contract || exit 1
  validate_inputs
  prepare_rename_bridge || exit 1
  build_rename_plan
  confirm_rename
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[dry-run] No changes made."
    exit 0
  fi
  recheck_rename_preconditions
  do_rename
  refresh_cts

  echo ""
  echo "Done. ${OLD_HOSTNAME} renamed to ${NEW_HOSTNAME} (CTID ${CTID})."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
