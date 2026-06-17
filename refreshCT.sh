#!/usr/bin/env bash
#
# refreshCT.sh - Refresh and update a Proxmox LXC container
#
# DESCRIPTION:
#   Updates an existing LXC container on Proxmox VE by re-applying all
#   configuration using IDEMPOTENT functions shared with createCT.sh.
#   This ensures existing containers can receive the latest configuration
#   changes without recreation.
#
#   Applied configurations (all idempotent):
#   - System packages updated via apk upgrade
#   - Timezone set to Europe/Berlin (tzdata installed)
#   - Docker logging configured to OTEL collector (fluentd)
#   - Telegraf metrics collection to OTEL (10s interval)
#   - Syslog forwarding to OTEL collector
#   - ghcr.io Docker authentication refreshed
#   - Step CA root certificate trust updated
#   - Docker Compose services restarted
#
#   Host-specific behavior:
#   - CA hosts (ca.*): Skip logging, telegraf, syslog, step_ca
#   - OTEL hosts (otel.*): Skip logging, syslog (would loop)
#
# USAGE:
#   ./refreshCT.sh [CTID or hostname] [--size S|M|L] [--priority low|mid|high] [--gpu] [--monitor]
#
# EXAMPLES:
#   ./refreshCT.sh                           # Interactive multi-select
#   ./refreshCT.sh --gpu                     # Interactive single-select + GPU
#   ./refreshCT.sh 2100                      # Refresh by CTID
#   ./refreshCT.sh app.thesaints.home        # Refresh by hostname
#   ./refreshCT.sh 2100 --monitor            # Refresh and stream logs
#   ./refreshCT.sh 2100 --size L             # Resize to Large and refresh
#   ./refreshCT.sh 2100 --priority high      # Set high priority
#   ./refreshCT.sh 2600 --gpu                # Enable GPU passthrough
#
# BEHAVIOR:
#   - Without arguments: multi-select dialog to choose multiple containers
#   - With options only (--gpu, --size, --monitor): single-select dialog
#   - With CTID/hostname: operates on that specific container
#   - All configuration functions are idempotent (safe to run repeatedly)
#   - Docker Compose services are pulled and restarted
#
# REQUIREMENTS:
#   - Run on Proxmox VE host as root
#   - Container must be running
#
# SEE ALSO:
#   createCT.sh      Create a new container with Docker
#   deleteCT.sh      Delete a container and optionally its data
#   commonCT.sh      Shared idempotent configuration functions
#
set -euo pipefail

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/commonCT.sh"

# Global flags
MONITOR_AFTER=false
GPU_PASSTHROUGH=false
CT_SIZE=""
CT_PRIORITY=""

# -----------------------------
# FUNCTIONS
# -----------------------------

# Note: update_packages is now provided by ensure_packages_and_ca in commonCT.sh
# This legacy function is kept for reference but is no longer called

# Reset Docker and restart compose services
reset_docker() {
  echo "Checking for docker-compose.yaml..."
  
  if ! ct_exec --timeout 15 'test -s /mnt/docker/docker-compose.yaml' 2>/dev/null; then
    echo "  No docker-compose.yaml found, skipping Docker reset"
    return
  fi
  
  echo "  Found docker-compose.yaml"
  
  # Ensure Docker daemon is running and responsive.
  # configure_step_ca may have already restarted Docker, so check first.
  # If Docker is already responsive, restart to apply daemon.json changes.
  # If not, wait for the in-progress restart to finish (up to 120s).
  # Alpine's supervise-daemon uses --retry TERM/60/KILL/10 for the stop phase;
  # container restoration with cgroupv2 in LXC adds another 30-50s.
  echo "  Ensuring Docker daemon is ready..."
  if ct_exec --timeout 10 'docker info >/dev/null 2>&1' 2>/dev/null; then
    # Docker is responsive — restart to apply any daemon.json changes
    echo "  Restarting Docker daemon..."
    ct_exec --timeout 120 'service docker restart >/dev/null 2>&1 || true'
  fi
  
  # Wait for Docker daemon to be responsive (compose config needs it)
  local max_wait=120
  local waited=0
  while ! ct_exec --timeout 10 'docker info >/dev/null 2>&1' 2>/dev/null; do
    waited=$((waited + 10))
    if [[ $waited -ge $max_wait ]]; then
      echo "  [!] Warning: Docker daemon not responding after ${max_wait}s, skipping"
      return
    fi
    sleep 5
  done
  echo "  [✓] Docker daemon ready"
  
  # Validate compose file
  echo "  Validating docker-compose.yaml..."
  if ! ct_exec --timeout 30 'cd /mnt/docker && docker compose config --quiet' 2>/dev/null; then
    echo "  [!] Warning: docker-compose.yaml validation failed, skipping start"
    echo "      Fix the compose file and run: pct exec ${CTID} -- sh -c 'cd /mnt/docker && docker compose up -d'"
    return
  fi
  echo "  [✓] Compose file is valid"
  
  # Pull and deploy
  echo "  Pulling images and deploying..."
  compose_up "${CTID}"
  
  # Fix permissions after containers are created
  fix_mount_permissions
  
  # Restart to apply permission fixes
  ct_exec --timeout 60 'cd /mnt/docker && docker compose restart' 2>/dev/null || true
  
  # Cleanup unused images
  echo "  Cleaning up unused images..."
  ct_exec --timeout 30 'docker image prune -f' 2>/dev/null || true
  
  echo "  [✓] Docker Compose services running"
}

# Fix permissions on bind mounts based on container UIDs
fix_mount_permissions() {
  echo "  Fixing bind mount permissions..."
  
  # Get compose config as JSON from CT
  local compose_json
  compose_json=$(ct_exec --timeout 30 'cd /mnt/docker && docker compose config --format json' 2>/dev/null) || {
    echo "  [!] Could not get compose config"
    return
  }
  
  # Extract services and their details using jq
  local services
  services=$(echo "$compose_json" | jq -r '.services | keys[]') || return
  
  for svc in $services; do
    # Get image for this service
    local image
    image=$(echo "$compose_json" | jq -r --arg s "$svc" '.services[$s].image // empty')
    [ -z "$image" ] && continue
    
    # Get UID from image metadata (no container run needed)
    local user_spec uid
    user_spec=$(ct_exec --timeout 30 "docker image inspect --format '{{.Config.User}}' '$image'" 2>/dev/null) || user_spec=""
    
    # Parse user spec: could be "uid", "uid:gid", "username", or empty
    if [[ -z "$user_spec" ]]; then
      uid="0"  # No USER directive = root
    elif [[ "$user_spec" =~ ^[0-9]+(:.*)?$ ]]; then
      uid="${user_spec%%:*}"  # Extract UID from "uid" or "uid:gid"
    else
      # Username specified - try to resolve, fallback to 0
      uid=$(ct_exec --timeout 60 "docker run --rm --entrypoint id '$image' -u" 2>/dev/null) || uid="0"
    fi
    [ -z "$uid" ] && uid="0"
    
    # Get writable bind mounts (type=bind, not read_only)
    local mounts
    mounts=$(echo "$compose_json" | jq -r --arg s "$svc" '
      .services[$s].volumes // [] 
      | .[] 
      | select(type == "object" and .type == "bind" and (.read_only != true))
      | .source
    ' 2>/dev/null)
    
    # Also handle short syntax volumes (strings like "/host:/container")
    local short_mounts
    short_mounts=$(echo "$compose_json" | jq -r --arg s "$svc" '
      .services[$s].volumes // [] 
      | .[] 
      | select(type == "string" and (contains(":ro") | not))
      | split(":")[0]
    ' 2>/dev/null)
    
    # Combine and filter to /mnt/docker paths
    for mount_path in $mounts $short_mounts; do
      [[ "$mount_path" != /mnt/docker* ]] && continue
      
      # Check and fix permissions on host
      get_ct_dirs "${CT_HOSTNAME}"
      local host_path="${mount_path/#\/mnt\/docker/${DIR_DOCKER}}"
      
      if [[ -e "$host_path" ]]; then
        local current_uid
        current_uid=$(stat -c %u "$host_path" 2>/dev/null) || current_uid="0"
        if [[ "$current_uid" != "$uid" ]]; then
          echo "    $svc: chown $uid on $host_path"
          chown -R "$uid:$uid" "$host_path" 2>/dev/null || true
        fi
      fi
    done
  done
  
  echo "  [✓] Permissions checked"
}

# Print summary
print_summary() {
  echo ""
  echo "Done. CT ${CTID} (${CT_HOSTNAME}) has been refreshed."
}


# Resize CT resources based on size
resize_ct() {
  if [[ -z "$CT_SIZE" ]]; then
    return
  fi
  
  echo "Resizing CT ${CTID} to size ${CT_SIZE}..."
  
  validate_size "${CT_SIZE}" || exit 1
  
  # Check if CT needs to be stopped for resize
  local was_running=false
  if pct status "${CTID}" | grep -q 'status: running'; then
    was_running=true
    echo "  Stopping CT for resize..."
    pct stop "${CTID}"
    sleep 2
  fi
  
  # Apply new resource settings (swap = half of memory)
  local swap_size=$((SIZE_MEMORY / 2))
  pct set "${CTID}" -cores "${SIZE_CORES}" -memory "${SIZE_MEMORY}" -swap "${swap_size}"
  echo "  [✓] CT resized to ${SIZE_CORES} cores, ${SIZE_MEMORY} MB RAM, ${swap_size} MB swap"
  
  # Restart if it was running
  if [[ "$was_running" == "true" ]]; then
    echo "  Restarting CT..."
    pct start "${CTID}"
    sleep 3
  fi
}

# Apply priority (CPU units) if specified
apply_priority() {
  if [[ -z "$CT_PRIORITY" ]]; then
    local current_units
    current_units=$(pct config "${CTID}" | grep -oP 'cpuunits:\s*\K\d+' || echo "1024")
    echo "  [i] Priority unchanged (current: ${current_units} CPU units)"
    return
  fi
  
  echo "Setting priority to ${CT_PRIORITY}..."
  validate_priority "${CT_PRIORITY}" || exit 1
  pct set "${CTID}" -cpuunits "${PRIORITY_CPUUNITS}"
  echo "  [✓] Priority set to ${CT_PRIORITY} (${PRIORITY_CPUUNITS} CPU units)"
}

# -----------------------------
# MAIN
# -----------------------------
main() {
  local ct_arg=""
  local has_options=false
  
  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --monitor|-m)
        MONITOR_AFTER=true
        has_options=true
        shift
        ;;
      --size|-s)
        CT_SIZE="$2"
        has_options=true
        shift 2
        ;;
      --gpu)
        GPU_PASSTHROUGH=true
        has_options=true
        shift
        ;;
      --priority|-p)
        CT_PRIORITY="$2"
        has_options=true
        shift 2
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
  
  build_ct_list
  
  if [[ ${#CT_LIST[@]} -eq 0 ]]; then
    echo "No containers found."
    exit 0
  fi
  
  # Build list of CTs to process
  # Multi-select only when no arguments provided; single-select if any options given
  local cts_to_process=()
  
  if [[ -z "$ct_arg" ]]; then
    if [[ "$has_options" == "true" ]]; then
      select_ct_interactive_single "refresh" || exit 1
      cts_to_process=("$CTID")
    else
      select_ct_interactive_multi "refresh" || exit 1
      cts_to_process=("${SELECTED_CTS[@]}")
    fi
  else
    resolve_ct_from_input "$ct_arg" || exit 1
    cts_to_process=("$CTID")
  fi
  
  # Process each selected CT
  local total=${#cts_to_process[@]}
  local current=0
  
  # Initialize status bar for progress tracking
  local steps_per_ct=7
  local total_steps=$((total * steps_per_ct))
  local overall_step=0
  
  status_bar_init
  
  for CTID in "${cts_to_process[@]}"; do
    current=$((current + 1))
    CT_HOSTNAME="${CT_MAP[$CTID]}"
    local base_step=$(( (current - 1) * steps_per_ct ))
    
    echo ""
    echo "=============================================="
    echo "Refreshing: CT ${CTID} (${CT_HOSTNAME}) [${current}/${total}]"
    echo "=============================================="
    echo ""
    
    ensure_ct_running || { overall_step=$((base_step + steps_per_ct)); continue; }
    
    overall_step=$((base_step + 1)); status_progress "$overall_step" "$total_steps" "CT ${CTID}: Resizing..."
    resize_ct
    ensure_swap
    apply_priority
    
    overall_step=$((base_step + 2)); status_progress "$overall_step" "$total_steps" "CT ${CTID}: Verifying mountpoints..."
    setup_mountpoints
    
    overall_step=$((base_step + 3)); status_progress "$overall_step" "$total_steps" "CT ${CTID}: Applying configuration..."
    apply_ct_configuration "${CTID}" "${CT_HOSTNAME}" "${GPU_PASSTHROUGH}"
    
    overall_step=$((base_step + 4)); status_progress "$overall_step" "$total_steps" "CT ${CTID}: Restarting Docker..."
    reset_docker || echo "  [!] Docker reset failed (non-fatal)"
    
    overall_step=$((base_step + 5)); status_progress "$overall_step" "$total_steps" "CT ${CTID}: Rebooting..."
    reboot_ct || echo "  [!] Reboot verification failed (non-fatal)"
    
    overall_step=$((base_step + 6)); status_progress "$overall_step" "$total_steps" "CT ${CTID}: Checking DNS..."
    check_dns_health || echo "  [!] DNS health check failed (non-fatal)"
    
    overall_step=$((base_step + 7)); status_progress "$overall_step" "$total_steps" "CT ${CTID}: Running configure script..."
    get_ct_dirs
    run_configure_script
    
    print_summary
  done
  
  # Clean up status bar
  status_bar_cleanup
  
  echo ""
  echo "All ${total} container(s) refreshed."

  # Optionally start monitoring (only for single CT)
  if [[ "$MONITOR_AFTER" == "true" && $total -eq 1 ]]; then
    echo ""
    echo "Starting log monitor..."
    exec "${SCRIPT_DIR}/monitorCT.sh" "${cts_to_process[0]}"
  fi
}

main "$@"
