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
#   - Docker Compose services fully restarted (down -> pull -> up)
#
#   Host-specific behavior:
#   - CA hosts (ca.*): Skip logging, telegraf, syslog, step_ca
#   - OTEL hosts (otel.*): Skip logging, syslog (would loop)
#
# USAGE:
#   ./refreshCT.sh [CTID or hostname] [--size S|M|L | --cores N --memory MB] [--priority low|mid|high] [--gpu] [--monitor] [--reset]
#
# EXAMPLES:
#   ./refreshCT.sh                           # Interactive multi-select
#   ./refreshCT.sh --gpu                     # Interactive single-select + GPU
#   ./refreshCT.sh 2100                      # Refresh by CTID
#   ./refreshCT.sh app.thesaints.home        # Refresh by hostname
#   ./refreshCT.sh 2100 --monitor            # Refresh and stream logs
#   ./refreshCT.sh 2100 --size L             # Resize to a named size and refresh
#   ./refreshCT.sh 2100 --cores 3 --memory 3072  # Resize to a CUSTOM allocation
#   ./refreshCT.sh 2100 --priority high      # Set high priority
#   ./refreshCT.sh 2600 --gpu                # Enable GPU passthrough
#   ./refreshCT.sh 2100 --reset              # Wipe data subfolders, then re-init
#
#   Sizing is either a named t-shirt size (--size, validated against commonCT.json)
#   OR a custom allocation (--cores and/or --memory). The two modes are mutually
#   exclusive. With a custom allocation, any dimension you omit keeps the CT's
#   current value. Swap is always re-derived as half of memory.
#
# BEHAVIOR:
#   - Without arguments: multi-select dialog to choose multiple containers
#   - With options only (--gpu, --size, --cores, --memory, --monitor, --reset): single-select dialog
#   - With CTID/hostname: operates on that specific container
#   - All configuration functions are idempotent (safe to run repeatedly)
#   - A resize (--size/--cores/--memory) waits up to 5 minutes for an active
#     Proxmox lock (e.g. an in-progress backup) to clear before resizing, and
#     aborts if it does not clear in time
#   - Each CT's storage volumes (rootfs + volume mount points) are checked before
#     refresh; if a backing ZFS pool is DEGRADED/resilvering or a storage is
#     missing, a warning is printed but the refresh continues
#   - Docker Compose services are brought down, freshly pulled, and started
#   - With --reset: between 'compose down' and 'compose up', each CT shows its own
#     list of deletable subfolders under /mnt/docker/<host> and
#     /mnt/docker-data/<host> and asks for confirmation before recursively deleting
#     them (subfolders starting with '_' are excluded; docker-compose.yaml and .env
#     are kept). The 'caddy/' folder requires a separate, dedicated confirmation
#     because deleting it forces Let's Encrypt/ACME certificate re-issuance.
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
CT_CORES=""
CT_MEMORY=""
CT_PRIORITY=""
RESET=false

# -----------------------------
# FUNCTIONS
# -----------------------------

# Note: update_packages is now provided by ensure_packages_and_ca in commonCT.sh
# This legacy function is kept for reference but is no longer called

# List deletable subfolders for a reset, one path per line.
# Emits the immediate subdirectories of DIR_DOCKER and DIR_DOCKER_DATA whose
# basename does NOT start with "_". Top-level files (docker-compose.yaml, .env)
# are never listed. Requires get_ct_dirs to have set DIR_DOCKER/DIR_DOCKER_DATA.
reset_list_candidates() {
  local base d name
  for base in "$DIR_DOCKER" "$DIR_DOCKER_DATA"; do
    [[ -d "$base" ]] || continue
    for d in "$base"/*/; do
      [[ -d "$d" ]] || continue          # skip when glob has no match
      name="$(basename "$d")"
      [[ "$name" == _* ]] && continue     # exclude "_"-prefixed subfolders
      echo "${d%/}"
    done
  done
}

# Interactive per-CT reset cleanup. Intended to run while Compose is DOWN
# (between compose_down and compose_up) so bind mounts are released.
# Shows this CT's deletable subfolders, asks for confirmation, and recursively
# deletes the confirmed ones. The "caddy" folder requires a separate, dedicated
# confirmation because deleting it forces Let's Encrypt/ACME cert re-issuance.
# Uses globals CTID and CT_HOSTNAME. Never fatal (always returns 0).
reset_cleanup_folders() {
  get_ct_dirs "${CT_HOSTNAME}"

  local candidates=()
  mapfile -t candidates < <(reset_list_candidates)

  if [[ ${#candidates[@]} -eq 0 ]]; then
    echo "  [reset] CT ${CTID} (${CT_HOSTNAME}): no deletable subfolders found."
    return 0
  fi

  echo ""
  echo "  [reset] CT ${CTID} (${CT_HOSTNAME}) — subfolders eligible for RECURSIVE deletion:"
  local c name
  for c in "${candidates[@]}"; do
    name="$(basename "$c")"
    if [[ "$name" == "caddy" ]]; then
      echo "    $c   (Caddy data — separate confirmation)"
    else
      echo "    $c"
    fi
  done
  echo "    ('_'-prefixed subfolders are excluded; docker-compose.yaml and .env are kept)"
  echo ""

  local reply
  read -p "  Delete these folders for CT ${CTID}? [y/N]: " reply
  if [[ ! "$reply" =~ ^[Yy]$ ]]; then
    echo "  [reset] Declined — continuing refresh without deleting."
    return 0
  fi

  # Delete all non-caddy candidates first.
  for c in "${candidates[@]}"; do
    name="$(basename "$c")"
    [[ "$name" == "caddy" ]] && continue
    rm -rf "$c" && echo "    Deleted: $c"
  done

  # Dedicated confirmation for each caddy folder (cert re-issuance risk).
  for c in "${candidates[@]}"; do
    name="$(basename "$c")"
    [[ "$name" != "caddy" ]] && continue
    local caddy_reply
    read -p "  Also delete ${c}? This wipes LE/ACME certs and forces re-issuance (rate limits). [y/N]: " caddy_reply
    if [[ "$caddy_reply" =~ ^[Yy]$ ]]; then
      rm -rf "$c" && echo "    Deleted: $c"
    else
      echo "    Kept: $c"
    fi
  done

  return 0
}

# Reset Docker and perform a full compose restart (down -> pull -> up)
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
  
  # Enforce a full stop/start cycle so refresh behavior is deterministic.
  echo "  Stopping existing Compose services..."
  if ! compose_down "${CTID}"; then
    echo "  [!] Warning: failed to stop existing Compose services, skipping deploy"
    return 1
  fi

  # Pre-pull all images BEFORE any destructive cleanup. A transient registry
  # failure must never leave a CT with wiped data and no images to start from.
  echo "  Pulling images before deploy..."
  if ! compose_pull "${CTID}"; then
    if [[ "${RESET:-false}" == "true" ]]; then
      echo "  [!] Image pull failed; NOT wiping data. CT left intact."
      echo "      Retry later: pct exec ${CTID} -- sh -c 'cd /mnt/docker && docker compose pull'"
      return 1
    fi
    echo "  [!] Warning: image pull failed; continuing with cached images."
  fi

  # Optional reset: with Compose down (bind mounts released) and images cached,
  # wipe data subfolders so the next 'compose up' reinitializes from scratch.
  if [[ "${RESET:-false}" == "true" ]]; then
    reset_cleanup_folders
  fi

  # Deploy (uses pre-pulled/cached images)
  echo "  Starting services..."
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
  # Nothing requested -> no-op
  if [[ -z "$CT_SIZE" && -z "$CT_CORES" && -z "$CT_MEMORY" ]]; then
    return
  fi

  # Named size and custom cores/memory are mutually exclusive
  if [[ -n "$CT_SIZE" && ( -n "$CT_CORES" || -n "$CT_MEMORY" ) ]]; then
    echo "ERROR: --size cannot be combined with --cores/--memory" >&2
    exit 1
  fi

  # A resize stops/sets/starts the CT, which fails while Proxmox holds a config
  # lock (e.g. an in-progress backup). Wait the lock out (up to 5 min) before
  # touching the CT; abort if it does not clear.
  if ! wait_for_ct_unlock "${CTID}" 300; then
    echo "ERROR: CT ${CTID} is still locked/unavailable after 5 minutes; aborting resize." >&2
    exit 1
  fi

  if [[ -n "$CT_SIZE" ]]; then
    # Named t-shirt size: resolve SIZE_CORES/SIZE_MEMORY from commonCT.json
    echo "Resizing CT ${CTID} to size ${CT_SIZE}..."
    validate_size "${CT_SIZE}" || exit 1
  else
    # Custom allocation: validate provided dimensions, fill omitted ones from
    # the CT's current config so a single dimension can be tuned in isolation.
    if [[ -n "$CT_CORES" && ! "$CT_CORES" =~ ^[1-9][0-9]*$ ]]; then
      echo "ERROR: --cores must be a positive integer (got '${CT_CORES}')" >&2
      exit 1
    fi
    if [[ -n "$CT_MEMORY" && ! "$CT_MEMORY" =~ ^[1-9][0-9]*$ ]]; then
      echo "ERROR: --memory must be a positive integer in MB (got '${CT_MEMORY}')" >&2
      exit 1
    fi
    SIZE_CORES="${CT_CORES:-$(pct config "${CTID}" 2>/dev/null | grep -oP '^cores:\s*\K\d+' || echo "")}"
    SIZE_MEMORY="${CT_MEMORY:-$(pct config "${CTID}" 2>/dev/null | grep -oP '^memory:\s*\K\d+' || echo "")}"
    if [[ -z "$SIZE_CORES" || -z "$SIZE_MEMORY" ]]; then
      echo "ERROR: could not determine target cores/memory for CT ${CTID}" >&2
      exit 1
    fi
    echo "Resizing CT ${CTID} to custom allocation (${SIZE_CORES} cores, ${SIZE_MEMORY} MB)..."
  fi

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
      --cores)
        CT_CORES="$2"
        has_options=true
        shift 2
        ;;
      --memory)
        CT_MEMORY="$2"
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
      --reset)
        RESET=true
        has_options=true
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
  local failed_cts=()
  
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
    
    check_ct_storage_health "${CTID}" warn
    
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

    # MANDATORY: every CT is a Docker host — a reboot that leaves the daemon
    # dead means the whole stack is down. Verify (with active recovery) and
    # treat a hard failure as fatal for this CT.
    if ! ensure_docker_running "${CTID}"; then
      echo "  [✗] FATAL: Docker daemon is not running in CT ${CTID} after reboot — skipping remaining steps"
      failed_cts+=("${CTID} (${CT_HOSTNAME})")
      overall_step=$((base_step + steps_per_ct))
      continue
    fi

    overall_step=$((base_step + 6)); status_progress "$overall_step" "$total_steps" "CT ${CTID}: Checking DNS..."
    check_dns_health || echo "  [!] DNS health check failed (non-fatal)"
    
    overall_step=$((base_step + 7)); status_progress "$overall_step" "$total_steps" "CT ${CTID}: Running configure script..."
    get_ct_dirs
    sync_config_shared
    run_configure_script
    
    print_summary
  done
  
  # Clean up status bar
  status_bar_cleanup
  
  echo ""
  echo "All ${total} container(s) refreshed."

  if [[ ${#failed_cts[@]} -gt 0 ]]; then
    echo ""
    echo "  [✗] Docker daemon FAILED to come up after reboot on:"
    for f in "${failed_cts[@]}"; do
      echo "        - ${f}"
    done
    return 1
  fi

  # Optionally start monitoring (only for single CT)
  if [[ "$MONITOR_AFTER" == "true" && $total -eq 1 ]]; then
    echo ""
    echo "Starting log monitor..."
    exec "${SCRIPT_DIR}/monitorCT.sh" "${cts_to_process[0]}"
  fi
}

main "$@"
