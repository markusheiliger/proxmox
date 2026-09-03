#!/usr/bin/env bash
#
# refreshCT.sh - Refresh and update a Proxmox LXC container
# Documentation: refreshCT.md
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
#   ./refreshCT.sh [CTID or hostname] [--size S|M|L | --cores N --memory MB] [--priority low|mid|high] [--vlan ID] [--monitor] [--reset]
#
# EXAMPLES:
#   ./refreshCT.sh                           # Interactive multi-select
#   ./refreshCT.sh 2100                      # Refresh by CTID
#   ./refreshCT.sh app.thesaints.home        # Refresh by hostname
#   ./refreshCT.sh 2100 --monitor            # Refresh and stream logs
#   ./refreshCT.sh 2100 --size L             # Resize to a named size and refresh
#   ./refreshCT.sh 2100 --cores 3 --memory 3072  # Resize to a CUSTOM allocation
#   ./refreshCT.sh 2100 --priority high      # Set high priority
#   ./refreshCT.sh 2100 --vlan 100           # Assign net0 to VLAN 100
#   ./refreshCT.sh 2100 --vlan 0             # Remove any VLAN tag (unassign)
#   ./refreshCT.sh 2100 --reset              # Wipe data subfolders, then re-init
#
#   Sizing is either a named t-shirt size (--size, validated against commonCT.json)
#   OR a custom allocation (--cores and/or --memory). The two modes are mutually
#   exclusive. With a custom allocation, any dimension you omit keeps the CT's
#   current value. Swap is always re-derived as half of memory.
#
#   --vlan sets the VLAN tag on net0: 1-4094 assigns the CT to that VLAN, 0
#   removes any tag (unassign). Omit --vlan to leave the CT's VLAN untouched.
#   When --vlan actually changes the CT's VLAN, it is handled as an isolated
#   phase BEFORE the routine refresh: the UDM Pro fixed IP + local DNS record are
#   released, the tag is applied, the CT is fully stopped/started so it re-wires
#   onto the new VLAN, and once it obtains a fresh lease on the new subnet the
#   fixed IP + local DNS are re-pinned to the new IP. If the CT fails to obtain a
#   new IP the change is rolled back to the previous VLAN/IP (fatal for that CT).
#
# BEHAVIOR:
#   - Without arguments: multi-select dialog to choose multiple containers
#   - With options only (--size, --cores, --memory, --vlan, --monitor, --reset): single-select dialog
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
CT_SIZE=""
CT_CORES=""
CT_MEMORY=""
CT_PRIORITY=""
CT_VLAN=""
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
  local base d name node
  node=$(get_ct_owner_node "$CTID") || return 1
  for base in "$DIR_DOCKER" "$DIR_DOCKER_DATA"; do
    node_path_is_dir "$node" "$base" || continue
    while IFS= read -r d; do
      [[ -n "$d" ]] || continue
      name="$(basename "$d")"
      [[ "$name" == _* ]] && continue     # exclude "_"-prefixed subfolders
      echo "$d"
    done < <(run_on_node "$node" find "$base" -mindepth 1 -maxdepth 1 -type d -print | sort)
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

  local candidates=() node
  node=$(get_ct_owner_node "$CTID") || return 1
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
    node_remove_tree "$node" "$c" "$c" && echo "    Deleted: ${node}:$c"
  done

  # Dedicated confirmation for each caddy folder (cert re-issuance risk).
  for c in "${candidates[@]}"; do
    name="$(basename "$c")"
    [[ "$name" != "caddy" ]] && continue
    local caddy_reply
    read -p "  Also delete ${c}? This wipes LE/ACME certs and forces re-issuance (rate limits). [y/N]: " caddy_reply
    if [[ "$caddy_reply" =~ ^[Yy]$ ]]; then
      node_remove_tree "$node" "$c" "$c" && echo "    Deleted: ${node}:$c"
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
      echo "  [✗] Docker daemon not responding after ${max_wait}s"
      return 1
    fi
    sleep 5
  done
  echo "  [✓] Docker daemon ready"
  
  # Validate compose file
  echo "  Validating docker-compose.yaml..."
  local compose_validation_output
  if ! compose_validation_output=$(ct_exec --timeout 30 'cd /mnt/docker && docker compose config --quiet' 2>&1); then
    echo "  [✗] docker-compose.yaml validation failed"
    if [[ -n "$compose_validation_output" ]]; then
      echo "$compose_validation_output" | sed 's/^/      /'
    fi
    echo "      Fix the compose file and run: pct exec ${CTID} -- sh -c 'cd /mnt/docker && docker compose up -d'"
    return 1
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

  if ! reconcile_compose_permissions "${CTID}"; then
    return 1
  fi

  # Deploy (uses pre-pulled/cached images)
  echo "  Starting services..."
  if ! compose_up "${CTID}"; then
    echo "  [!] Failed to start Docker Compose services"
    return 1
  fi

  if ! wait_for_initialization_services; then
    return 1
  fi
  
  # Cleanup unused images
  echo "  Cleaning up unused images..."
  ct_exec --timeout 30 'docker image prune -f' 2>/dev/null || true

  # Final guard: a refresh must NEVER leave the CT with a torn-down stack. If no
  # services are running after the deploy (e.g. a transient 'compose up' failure
  # following the earlier 'compose down'), retry the deploy once and report if it
  # is still down.
  local running_count
  running_count=$(ct_exec --timeout 30 'cd /mnt/docker && docker compose ps --status running --quiet 2>/dev/null | wc -l' 2>/dev/null | tr -d ' \r')
  if [[ -z "$running_count" || "$running_count" -eq 0 ]]; then
    echo "  [!] No running services after deploy — retrying 'docker compose up -d'..."
    ct_exec --timeout 120 'cd /mnt/docker && docker compose up -d' 2>/dev/null || true
    running_count=$(ct_exec --timeout 30 'cd /mnt/docker && docker compose ps --status running --quiet 2>/dev/null | wc -l' 2>/dev/null | tr -d ' \r')
  fi
  if [[ -z "$running_count" || "$running_count" -eq 0 ]]; then
    echo "  [✗] Stack is DOWN after deploy attempts — manual intervention needed"
    return 1
  fi

  echo "  [✓] Docker Compose services running (${running_count} up)"
}

# Wait for every service explicitly configured with restart: "no". A refresh
# must not report success while initialization is still running, and any
# non-zero initializer exit is fatal for this CT.
wait_for_initialization_services() {
  local compose_json services service container_ids container_id container_name
  local state exit_code elapsed latest_log

  compose_json=$(ct_exec --timeout 30 'cd /mnt/docker && docker compose config --format json' 2>/dev/null) || {
    echo "  [!] Could not inspect Compose initialization services"
    return 1
  }
  services=$(echo "$compose_json" | jq -r '
    .services | to_entries[] | select(.value.restart == "no") | .key
  ') || return 1

  if [[ -z "$services" ]]; then
    return 0
  fi

  for service in $services; do
    container_ids=$(ct_exec --timeout 30 "cd /mnt/docker && docker compose ps -a -q '$service'" 2>/dev/null) || {
      echo "  [!] Could not find initialization service '$service'"
      return 1
    }
    if [[ -z "$container_ids" ]]; then
      echo "  [!] Initialization service '$service' has no container"
      return 1
    fi

    for container_id in $container_ids; do
      container_name=$(ct_exec --timeout 15 "docker inspect --format '{{.Name}}' '$container_id'" 2>/dev/null)
      container_name=${container_name#/}
      echo "  Waiting for initialization service ${container_name:-$service}..."
      elapsed=0
      while true; do
        state=$(ct_exec --timeout 15 "docker inspect --format '{{.State.Status}}' '$container_id'" 2>/dev/null | tail -1 | tr -d '[:space:]') || {
          echo "  [!] Could not inspect initialization service '${container_name:-$service}'"
          return 1
        }
        case "$state" in
          exited|dead)
            break
            ;;
          created|running|restarting)
            sleep 30
            elapsed=$((elapsed + 30))
            latest_log=$(ct_exec --timeout 15 "docker logs --tail 20 '$container_id' 2>&1" 2>/dev/null | awk 'NF { line=$0 } END { print line }' || true)
            if [[ -n "$latest_log" ]]; then
              echo "  [i] ${container_name:-$service} still running (${elapsed}s): ${latest_log}"
            else
              echo "  [i] ${container_name:-$service} still running (${elapsed}s)"
            fi
            ;;
          *)
            echo "  [!] Initialization service '${container_name:-$service}' has unexpected state '${state:-unknown}'"
            return 1
            ;;
        esac
      done

      exit_code=$(ct_exec --timeout 15 "docker inspect --format '{{.State.ExitCode}}' '$container_id'" 2>/dev/null | tail -1 | tr -d '[:space:]') || {
        echo "  [!] Could not read exit code for initialization service '${container_name:-$service}'"
        return 1
      }
      if [[ ! "$exit_code" =~ ^[0-9]+$ || "$exit_code" -ne 0 ]]; then
        echo "  [!] Initialization service '${container_name:-$service}' exited with code ${exit_code:-unknown}"
        echo "      Recent logs:"
        ct_exec --timeout 15 "docker logs --tail 20 '$container_id' 2>&1" 2>/dev/null | sed 's/^/        /' || true
        return 1
      fi
      echo "  [✓] Initialization service ${container_name:-$service} completed"
    done
  done
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
    SIZE_CORES="${CT_CORES:-$(pct_config "${CTID}" 2>/dev/null | grep -oP '^cores:\s*\K\d+' || echo "")}"
    SIZE_MEMORY="${CT_MEMORY:-$(pct_config "${CTID}" 2>/dev/null | grep -oP '^memory:\s*\K\d+' || echo "")}"
    if [[ -z "$SIZE_CORES" || -z "$SIZE_MEMORY" ]]; then
      echo "ERROR: could not determine target cores/memory for CT ${CTID}" >&2
      exit 1
    fi
    echo "Resizing CT ${CTID} to custom allocation (${SIZE_CORES} cores, ${SIZE_MEMORY} MB)..."
  fi

  # Check if CT needs to be stopped for resize
  local was_running=false
  if pct_status "${CTID}" | grep -q 'status: running'; then
    was_running=true
    echo "  Stopping CT for resize..."
    pct_stop "${CTID}"
    sleep 2
  fi
  
  # Apply new resource settings (swap = half of memory)
  local swap_size=$((SIZE_MEMORY / 2))
  pct_set "${CTID}" -cores "${SIZE_CORES}" -memory "${SIZE_MEMORY}" -swap "${swap_size}"
  echo "  [✓] CT resized to ${SIZE_CORES} cores, ${SIZE_MEMORY} MB RAM, ${swap_size} MB swap"
  
  # Restart if it was running
  if [[ "$was_running" == "true" ]]; then
    echo "  Restarting CT..."
    pct_start "${CTID}"
    sleep 3
  fi
}

# Apply priority (CPU units) if specified
apply_priority() {
  if [[ -z "$CT_PRIORITY" ]]; then
    local current_units
    current_units=$(pct_config "${CTID}" | grep -oP 'cpuunits:\s*\K\d+' || echo "1024")
    echo "  [i] Priority unchanged (current: ${current_units} CPU units)"
    return
  fi
  
  echo "Setting priority to ${CT_PRIORITY}..."
  validate_priority "${CT_PRIORITY}" || exit 1
  pct_set "${CTID}" -cpuunits "${PRIORITY_CPUUNITS}"
  echo "  [✓] Priority set to ${CT_PRIORITY} (${PRIORITY_CPUUNITS} CPU units)"
}

# -----------------------------
# MAIN
# -----------------------------
main() {
  lifecycle_log_init "${BASH_SOURCE[0]}" "$@"
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
      --priority|-p)
        CT_PRIORITY="$2"
        has_options=true
        shift 2
        ;;
      --vlan)
        if [[ ! "$2" =~ ^(0|[1-9][0-9]*)$ ]] || (( $2 > 4094 )); then
          echo "ERROR: --vlan must be an integer in range 0-4094 (got '$2')" >&2
          exit 1
        fi
        CT_VLAN="$2"
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
  local steps_per_ct=8
  local total_steps=$((total * steps_per_ct))
  local overall_step=0
  
  status_bar_init
  
  for CTID in "${cts_to_process[@]}"; do
    current=$((current + 1))
    CT_HOSTNAME="${CT_MAP[$CTID]}"
    local ct_node="${CT_NODE[$CTID]}"
    local base_step=$(( (current - 1) * steps_per_ct ))
    
    echo ""
    echo "=============================================="
    echo "Refreshing: CT ${CTID} (${CT_HOSTNAME}) [${current}/${total}]"
    echo "=============================================="
    echo ""
    
    check_ct_storage_health "${CTID}" warn

    overall_step=$((base_step + 1)); status_progress "$overall_step" "$total_steps" "CT ${CTID}: Reconciling bridge policy..."
    if ! validate_node_storage_contract "$ct_node" \
      || ! bridge_policy_resolve "$ct_node" CT "$CTID" "$CT_HOSTNAME" \
      || ! bridge_policy_reconcile_guest "$ct_node" CT "$CTID" "$BRIDGE_POLICY_SELECTED"; then
      echo "  [✗] FATAL: bridge policy reconciliation failed for CT ${CTID} — skipping remaining steps"
      failed_cts+=("${CTID} (${CT_HOSTNAME}): bridge policy reconciliation")
      overall_step=$((base_step + steps_per_ct))
      continue
    fi
    echo "  [✓] Bridge policy selected ${BRIDGE_POLICY_SELECTED} (${BRIDGE_POLICY_REASON})"

    if ! reconcile_ct_gpu_config "${CTID}" "$ct_node"; then
      echo "  [✗] FATAL: GPU reconciliation failed for CT ${CTID} — skipping remaining steps"
      failed_cts+=("${CTID} (${CT_HOSTNAME}): GPU reconciliation")
      overall_step=$((base_step + steps_per_ct))
      continue
    fi
    
    ensure_ct_running || { overall_step=$((base_step + steps_per_ct)); continue; }

    # PHASE A — isolated VLAN switch. When --vlan changes the CT's VLAN, handle
    # the whole disruptive switch here (release UDM Pro reservation, retag, hard
    # stop/start onto the new VLAN, wait for a fresh new-subnet lease, re-pin)
    # and roll back to the old VLAN/IP on failure — all BEFORE the routine
    # refresh below. No-op when no VLAN change is pending.
    if ! reconcile_vlan_change "${CTID}" "${CT_HOSTNAME}" "${CT_VLAN}"; then
      echo "  [✗] FATAL: VLAN reconciliation failed for CT ${CTID} (rolled back) — skipping remaining steps"
      failed_cts+=("${CTID} (${CT_HOSTNAME}): VLAN reconciliation")
      overall_step=$((base_step + steps_per_ct))
      continue
    fi

    overall_step=$((base_step + 2)); status_progress "$overall_step" "$total_steps" "CT ${CTID}: Resizing..."
    resize_ct
    ensure_swap
    apply_priority
    
    overall_step=$((base_step + 3)); status_progress "$overall_step" "$total_steps" "CT ${CTID}: Verifying mountpoints..."
    setup_mountpoints
    
    overall_step=$((base_step + 4)); status_progress "$overall_step" "$total_steps" "CT ${CTID}: Applying configuration..."
    apply_ct_configuration "${CTID}" "${CT_HOSTNAME}"
    if ! finalize_ct_gpu_capability "${CTID}" "$ct_node"; then
      echo "  [✗] FATAL: GPU verification failed for CT ${CTID} — skipping remaining steps"
      failed_cts+=("${CTID} (${CT_HOSTNAME}): GPU verification")
      overall_step=$((base_step + steps_per_ct))
      continue
    fi
    
    overall_step=$((base_step + 5)); status_progress "$overall_step" "$total_steps" "CT ${CTID}: Restarting Docker..."
    if ! reset_docker; then
      echo "  [✗] FATAL: Docker deployment or initialization failed for CT ${CTID} — skipping remaining steps"
      failed_cts+=("${CTID} (${CT_HOSTNAME}): Docker Compose deployment/initialization")
      overall_step=$((base_step + steps_per_ct))
      continue
    fi
    
    overall_step=$((base_step + 6)); status_progress "$overall_step" "$total_steps" "CT ${CTID}: Rebooting..."
    if [[ "${VLAN_PHASE_RESTARTED:-false}" == "true" ]]; then
      echo "  [i] Skipping reboot — the VLAN phase already stopped/started this CT"
    else
      reboot_ct || echo "  [!] Reboot verification failed (non-fatal)"
    fi

    # MANDATORY: every CT is a Docker host — a reboot that leaves the daemon
    # dead means the whole stack is down. Verify (with active recovery) and
    # treat a hard failure as fatal for this CT.
    if ! ensure_docker_running "${CTID}"; then
      echo "  [✗] FATAL: Docker daemon is not running in CT ${CTID} after reboot — skipping remaining steps"
      failed_cts+=("${CTID} (${CT_HOSTNAME}): Docker daemon after reboot")
      overall_step=$((base_step + steps_per_ct))
      continue
    fi

    overall_step=$((base_step + 7)); status_progress "$overall_step" "$total_steps" "CT ${CTID}: Checking DNS..."
    check_dns_health || echo "  [!] DNS health check failed (non-fatal)"
    
    overall_step=$((base_step + 8)); status_progress "$overall_step" "$total_steps" "CT ${CTID}: Running configure script..."
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
    echo "  [✗] Refresh FAILED on:"
    for f in "${failed_cts[@]}"; do
      echo "        - ${f}"
    done
    return 1
  fi

  # Optionally start monitoring (only for single CT)
  if [[ "$MONITOR_AFTER" == "true" && $total -eq 1 ]]; then
    echo ""
    echo "Starting log monitor..."
    lifecycle_log_stop 0
    exec "${SCRIPT_DIR}/monitorCT.sh" "${cts_to_process[0]}"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
