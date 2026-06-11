#!/usr/bin/env bash
#
# forwardAuthCT.sh - Enable or disable Caddy forward auth via Authentik
#
# DESCRIPTION:
#   Manages Caddy forward auth labels in docker-compose.yaml files for
#   Proxmox LXC containers. When enabled, Caddy will authenticate requests
#   via the domain-level Authentik forward auth provider before proxying
#   to the backend service.
#
#   The labels are added to services that already have a caddy.reverse_proxy
#   label. After modifying the compose file, the CT is rebooted to apply
#   the changes.
#
#   Also ensures the domain-level Authentik application/provider exists
#   (idempotent - shared across all services on the domain).
#
# USAGE:
#   ./forwardAuthCT.sh [CTID or hostname]           # Enable forward auth
#   ./forwardAuthCT.sh [CTID or hostname] --remove   # Disable forward auth
#
# EXAMPLES:
#   ./forwardAuthCT.sh                        # Interactive multi-select, enable
#   ./forwardAuthCT.sh --remove               # Interactive multi-select, disable
#   ./forwardAuthCT.sh 3200                   # Enable on CT 3200
#   ./forwardAuthCT.sh 3200 --remove          # Disable on CT 3200
#   ./forwardAuthCT.sh rust.thesaints.home    # Enable by hostname
#
# REQUIREMENTS:
#   - Run on Proxmox VE host as root
#   - Container must be running
#   - Authentik must be configured in commonCT.json
#   - docker-compose.yaml must have caddy.reverse_proxy labels
#
# SEE ALSO:
#   createCT.sh      Create a new container with Docker
#   refreshCT.sh     Refresh and update a container
#   commonCT.sh      Shared idempotent configuration functions
#
set -euo pipefail

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/commonCT.sh"

# Global flags
REMOVE_MODE=false

# Forward auth label lines (indented for YAML labels block)
# AUTHENTIK_HOST is replaced with the actual host at insertion time.
# This array is the single source of truth — add new labels here.
FORWARD_AUTH_LABELS=(
  'caddy.forward_auth: "https://AUTHENTIK_HOST"'
  'caddy.forward_auth.uri: "/outpost.goauthentik.io/auth/caddy"'
  'caddy.forward_auth.header_up: "Host AUTHENTIK_HOST"'
  'caddy.forward_auth.copy_headers: "X-Authentik-Username X-Authentik-Groups X-Authentik-Email X-Authentik-Name X-Authentik-Uid"'
  'caddy.forward_auth.trusted_proxies: private_ranges'
)

# Extract the label key from a "key: value" string (everything before the first ': ')
_label_key() {
  echo "${1%%:*}"
}

# Add forward auth labels to a compose file
# Idempotent: removes any existing forward_auth labels, then inserts the
# canonical set from FORWARD_AUTH_LABELS.  This ensures values are always
# up-to-date with the single source of truth defined in this script.
# Works with both simple (caddy.reverse_proxy) and handle-based (caddy.N_handle.reverse_proxy) routing.
add_forward_auth_labels() {
  local compose_file="$1"
  local ak_host="$2"

  # Match 'caddy:' as a standalone label key (site address), not 'caddy.something:'
  if ! grep -qP '^\s+caddy:\s' "$compose_file" 2>/dev/null; then
    echo "  [!] No caddy site labels found, skipping"
    return 0
  fi

  # Build the canonical label block with placeholder replaced
  local canonical_labels=()
  for label_template in "${FORWARD_AUTH_LABELS[@]}"; do
    canonical_labels+=("${label_template//AUTHENTIK_HOST/$ak_host}")
  done

  # Check if existing labels already match exactly
  if grep -q 'caddy\.forward_auth' "$compose_file" 2>/dev/null; then
    # Extract existing forward_auth label values (trimmed)
    local existing
    existing=$(grep 'caddy\.forward_auth' "$compose_file" | sed 's/^[[:space:]]*//' | sort)
    local canonical
    canonical=$(printf '%s\n' "${canonical_labels[@]}" | sort)

    if [[ "$existing" == "$canonical" ]]; then
      echo "  [✓] Forward auth labels already up-to-date"
      return 2  # No changes needed
    fi

    # Remove existing forward_auth labels first
    local tmpfile
    tmpfile=$(mktemp)
    grep -v 'caddy\.forward_auth' "$compose_file" > "$tmpfile"
    mv "$tmpfile" "$compose_file"
    echo "  [~] Removed outdated forward auth labels"
  fi

  # Build the block of lines to insert
  local insert_block=""
  for label in "${canonical_labels[@]}"; do
    insert_block+="${label}\n"
  done

  # Insert all labels after each 'caddy: <hostname>' line
  local tmpfile
  tmpfile=$(mktemp)
  awk -v insert="$insert_block" '
  { print }
  /^[[:space:]]+caddy:[[:space:]]/ && !/caddy\./ {
    match($0, /^[[:space:]]*/);
    indent = substr($0, RSTART, RLENGTH)

    n = split(insert, lines, "\\n")
    for (i = 1; i <= n; i++) {
      if (lines[i] != "") print indent lines[i]
    }
  }
  ' "$compose_file" > "$tmpfile"

  mv "$tmpfile" "$compose_file"
  echo "  [✓] Forward auth labels applied (${#canonical_labels[@]} labels)"
}

# Remove forward auth labels from a compose file
remove_forward_auth_labels() {
  local compose_file="$1"

  if ! grep -q 'caddy\.forward_auth' "$compose_file" 2>/dev/null; then
    echo "  [✓] No forward auth labels present"
    return 2  # No changes needed
  fi

  # Remove lines containing caddy.forward_auth
  local tmpfile
  tmpfile=$(mktemp)

  grep -v 'caddy\.forward_auth' "$compose_file" > "$tmpfile"
  mv "$tmpfile" "$compose_file"
  echo "  [✓] Forward auth labels removed"
}

# Recreate compose services in the CT to apply label changes
restart_compose() {
  echo "  Recreating Docker Compose services..."

  # Wait for Docker to be ready
  local retries=5
  while ! ct_exec --timeout 10 'docker info >/dev/null 2>&1' 2>/dev/null; do
    retries=$((retries - 1))
    if [[ $retries -le 0 ]]; then
      echo "  [!] Docker not ready in CT, skipping restart"
      return 1
    fi
    sleep 2
  done

  if ! ct_exec --timeout 15 'test -s /mnt/docker/docker-compose.yaml' 2>/dev/null; then
    echo "  [!] No docker-compose.yaml in CT, skipping restart"
    return 1
  fi

  # Validate compose file after modification
  if ! ct_exec --timeout 30 'cd /mnt/docker && docker compose config --quiet' 2>/dev/null; then
    echo "  [!] Warning: docker-compose.yaml validation failed after modification"
    echo "      Check the compose file: pct exec ${CTID} -- sh -c 'cd /mnt/docker && docker compose config'"
    return 1
  fi

  ct_exec --timeout 120 'cd /mnt/docker && docker compose up -d --force-recreate' 2>/dev/null || true
  echo "  [✓] Compose services recreated"
}

# Process a single CT
process_ct() {
  local compose_file="${DIR_DOCKER}/docker-compose.yaml"

  if [[ ! -f "$compose_file" ]]; then
    echo "  [!] No docker-compose.yaml found at ${compose_file}"
    return 0
  fi

  local rc=0

  if [[ "$REMOVE_MODE" == "true" ]]; then
    echo "  Removing forward auth labels..."
    remove_forward_auth_labels "$compose_file" || rc=$?
  else
    local ak_host
    ak_host=$(config_get_authentik_host)
    if [[ -z "$ak_host" ]]; then
      echo "  [!] Authentik host not configured in commonCT.json"
      return 1
    fi

    echo "  Adding forward auth labels..."
    add_forward_auth_labels "$compose_file" "$ak_host" || rc=$?
  fi

  # Only recreate containers if labels were actually changed
  if [[ "$rc" -eq 2 ]]; then
    echo "  [✓] No changes, skipping restart"
    return 0
  fi

  # Recreate containers to apply label changes
  restart_compose
}

# -----------------------------
# MAIN
# -----------------------------
main() {
  local ct_arg=""

  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --remove|-r)
        REMOVE_MODE=true
        shift
        ;;
      -*)
        echo "Unknown option: $1"
        exit 1
        ;;
      *)
        ct_arg="$1"
        shift
        ;;
    esac
  done

  # Verify Authentik config (unless removing)
  if [[ "$REMOVE_MODE" != "true" ]]; then
    if ! config_authentik_configured; then
      echo "Error: Authentik not configured in commonCT.json (missing host or apitoken)"
      exit 1
    fi
  fi

  build_ct_list

  if [[ ${#CT_LIST[@]} -eq 0 ]]; then
    echo "No containers found."
    exit 0
  fi

  # Build list of CTs to process
  local cts_to_process=()

  if [[ -z "$ct_arg" ]]; then
    local action="enable forward auth"
    [[ "$REMOVE_MODE" == "true" ]] && action="disable forward auth"
    select_ct_interactive_multi "$action" || exit 1
    cts_to_process=("${SELECTED_CTS[@]}")
  else
    resolve_ct_from_input "$ct_arg" || exit 1
    cts_to_process=("$CTID")
  fi

  local mode_label="Enabling"
  [[ "$REMOVE_MODE" == "true" ]] && mode_label="Disabling"

  # Process each selected CT
  local total=${#cts_to_process[@]}
  local current=0

  # Ensure domain-level Authentik app exists (once, before processing CTs)
  if [[ "$REMOVE_MODE" != "true" ]]; then
    echo "Ensuring Authentik domain-level forward auth..."
    # Use the first CT's hostname to derive the domain
    local first_hostname="${CT_MAP[${cts_to_process[0]}]}"
    configure_authentik_forward_auth "$first_hostname"
    echo ""
  fi

  status_bar_init

  for CTID in "${cts_to_process[@]}"; do
    current=$((current + 1))
    CT_HOSTNAME="${CT_MAP[$CTID]}"
    get_ct_dirs "${CT_HOSTNAME}"

    echo ""
    echo "=============================================="
    echo "${mode_label} forward auth: CT ${CTID} (${CT_HOSTNAME}) [${current}/${total}]"
    echo "=============================================="
    echo ""

    status_progress "$current" "$total" "CT ${CTID}: ${mode_label} forward auth..."

    ensure_ct_running || continue

    process_ct

    echo ""
    local done_label="enabled"
    [[ "$REMOVE_MODE" == "true" ]] && done_label="disabled"
    echo "Done. CT ${CTID} (${CT_HOSTNAME}) forward auth ${done_label}."
  done

  status_bar_cleanup

  echo ""
  echo "All ${total} container(s) processed."
}

main "$@"
