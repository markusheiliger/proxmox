#!/usr/bin/env bash
#
# createCT.sh - Create a Proxmox LXC container with Docker pre-installed
# Documentation: createCT.md
#
# DESCRIPTION:
#   Provisions an Alpine Linux container on Proxmox VE with:
#   - Docker and Docker Compose installed
#   - Timezone configured (Europe/Berlin)
#   - Docker logging to OTEL collector (fluentd)
#   - Telegraf metrics collection to OTEL
#   - Syslog forwarding to OTEL
#   - ghcr.io authentication configured
#   - Container registry authentication (from commonCT.json)
#   - Step CA root certificate trusted (for non-CA hosts)
#   - Bind mounts for /mnt/docker and /mnt/docker-data
#
#   Configuration functions are IDEMPOTENT and shared with refreshCT.sh,
#   meaning the same configuration can be re-applied to update existing CTs.
#
# USAGE:
#   ./createCT.sh <hostname> [--size S|M|L] [--cores N] [--memory MB] [--priority low|mid|high] [--vlan ID] [key=value overrides...]
#
# EXAMPLES:
#   ./createCT.sh app.thesaints.home                   # Default size S, priority mid
#   ./createCT.sh app.thesaints.home --size M          # Medium size
#   ./createCT.sh app.thesaints.home --cores 3 --memory 3072  # Custom allocation
#   ./createCT.sh app.thesaints.home --size M --memory 3072   # Size M base, 3072 MB RAM
#   ./createCT.sh app.thesaints.home --priority low    # Low priority (background)
#   ./createCT.sh app.thesaints.home --size L          # Large size (e.g., Seafile)
#   ./createCT.sh nvr.thesaints.home --priority high
#   ./createCT.sh app.thesaints.home --vlan 100        # Assign net0 to VLAN 100
#   ./createCT.sh app.thesaints.home IP=10.0.0.50/24 GW=10.0.0.1
#   ./createCT.sh ca.thesaints.home CTID=2000
#   ./createCT.sh app.thesaints.home --monitor
#
# HOSTNAME VALIDATION:
#   - Regular hosts: domain (e.g., thesaints.home) must exist in commonCT.json
#   - CA hosts (ca.*): must be fully qualified (e.g., ca.domain.tld)
#
# CONFIGURABLE PARAMETERS (with defaults):
#   --size           T-shirt size: S, M, L (default: S, defined in commonCT.json)
#   --cores          Override cores from the size base (e.g. --cores 3)
#   --memory         Override memory in MB from the size base (e.g. --memory 3072)
#   --vlan           VLAN id for net0 (1-4094 to assign, 0 to leave untagged;
#                    omit to use the bridge default / no VLAN)
#   CTID             Auto-allocated starting at 2000, step 100
#   STORAGE          local-lvm (fixed; node-local pve/data thin pool)
#   DISK             16 (GB)
#   BRIDGE           vmbr1
#   IP               dhcp (or CIDR like 10.0.0.50/24)
#   GW               (empty, required for static IP)
#   TEMPLATE_PREFIX  alpine-3
#
# REQUIREMENTS:
#   - Run on Proxmox VE host as root
#   - commonCT.json in same directory with Step CA fingerprints
#
# FILES:
#   commonCT.json    Step CA configuration (domain -> fingerprint mapping)
#   /mnt/docker/<hostname>/          Bind mount for docker configs
#   /mnt/docker-data/<hostname>/     Bind mount for docker data
#
# SEE ALSO:
#   refreshCT.sh     Re-apply configuration to existing container
#   deleteCT.sh      Delete a container and optionally its data
#   commonCT.sh      Shared idempotent configuration functions
#
set -euo pipefail

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/commonCT.sh"

# Ensure jq is available on Proxmox host
if ! command -v jq &>/dev/null; then
  echo "Installing jq on Proxmox host..."
  apt-get update -qq && apt-get install -y -qq jq
fi

# -----------------------------
# GLOBAL VARIABLES
# -----------------------------

HOSTNAME=""
CTID=""
STORAGE=""
DISK=""
CORES=""
MEMORY=""
BRIDGE=""
IP=""
GW=""
TEMPLATE_PREFIX=""
TEMPLATE_STORE="local"
TEMPLATE_PATH=""
DIR_DOCKER=""
DIR_DOCKER_DATA=""
COMPOSE_FILE=""
ENV_FILE=""
MONITOR_AFTER=false
CT_SIZE="S"
CT_PRIORITY="mid"
CT_VLAN=""
CREATE_NODE="$(hostname -s)"

# -----------------------------
# FUNCTIONS
# -----------------------------

# Show usage and exit
usage() {
  echo "Usage: $0 <hostname> [--size S|M|L] [--cores N] [--memory MB] [--priority low|mid|high] [key=value overrides]"
  echo ""
  echo "Options:"
  echo "  --size S|M|L             T-shirt size (default: S)"
  echo "  --cores N                Override cores from the size base (custom allocation)"
  echo "  --memory MB              Override memory in MB from the size base (custom allocation)"
  echo "  --priority low|mid|high  CPU priority (default: mid)"
  echo "  --monitor                Start log monitor after creation"
  echo ""
  echo "Sizes (defined in commonCT.json):"
  echo "  S = Small  ($(config_get_size_cores S) cores, $(config_get_size_memory S) MB)"
  echo "  M = Medium ($(config_get_size_cores M) cores, $(config_get_size_memory M) MB)"
  echo "  L = Large  ($(config_get_size_cores L) cores, $(config_get_size_memory L) MB)"
  echo ""
  echo "Priority (CPU units):"
  echo "  low  = 512  (background tasks)"
  echo "  mid  = 1024 (standard workloads)"
  echo "  high = 2048 (critical services)"
  exit 1
}

# Allocate next available CTID
# Strategy:
#   1. Start at base 1000, step by 100 (1000, 1100, 1200, ..., 2900)
#   2. If no free ID found below 3000, restart at 1000 with step 10
next_ctid() {
  local base=2000
  local max=10000
  local used
  used=$(pvesh get /cluster/resources --type vm --output-format json 2>/dev/null \
    | jq -r '.[] | .vmid // empty' | sort -n)

  # First pass: step by 100
  local candidate=$base
  while [[ $candidate -lt $max ]]; do
    if ! echo "$used" | grep -qx "$candidate"; then
      echo "$candidate"
      return 0
    fi
    candidate=$((candidate + 100))
  done

  # Second pass: step by 10 (denser allocation)
  candidate=$base
  while [[ $candidate -lt $max ]]; do
    if ! echo "$used" | grep -qx "$candidate"; then
      echo "$candidate"
      return 0
    fi
    candidate=$((candidate + 10))
  done

  echo "Error: No free CTID available (range ${base}-${max})" >&2
  return 1
}

# Set configuration defaults
set_defaults() {
  # Validate and apply size
  validate_size "${CT_SIZE}" || exit 1
  
  CTID="${CTID:-$(next_ctid)}"
  STORAGE="local-lvm"
  DISK="${DISK:-16}"
  CORES="${CORES:-${SIZE_CORES}}"
  MEMORY="${MEMORY:-${SIZE_MEMORY}}"
  IP="${IP:-dhcp}"
  GW="${GW:-}"
  TEMPLATE_PREFIX="${TEMPLATE_PREFIX:-alpine-3}"

  echo "Hostname: ${HOSTNAME}"
  echo "Size: ${CT_SIZE} (${CORES} cores, ${MEMORY} MB)"
  echo "Using CTID: ${CTID}"
  echo "Template prefix: ${TEMPLATE_PREFIX}"
}

# Find and download template
prepare_template() {
  echo "Searching for latest template matching prefix '${TEMPLATE_PREFIX}'..."
  run_on_node "$CREATE_NODE" pveam update >/dev/null

  local latest_template
  latest_template=$(run_on_node "$CREATE_NODE" pveam available | awk '{print $2}' \
    | grep "^${TEMPLATE_PREFIX}" \
    | sort -V \
    | tail -n 1)

  if [[ -z "${latest_template}" ]]; then
    echo "ERROR: No template found matching prefix '${TEMPLATE_PREFIX}'"
    exit 1
  fi

  echo "Latest matching template: ${latest_template}"
  TEMPLATE_PATH="${TEMPLATE_STORE}:vztmpl/${latest_template}"

  if ! run_on_node "$CREATE_NODE" pveam list "${TEMPLATE_STORE}" | awk '{print $2}' | grep -qx "${latest_template}"; then
    echo "Template not found locally. Downloading ${latest_template}..."
    run_on_node "$CREATE_NODE" pveam download "${TEMPLATE_STORE}" "${latest_template}"
  else
    echo "Template already present locally."
  fi
}

# Create the container
create_ct() {
  if pvesh get "/cluster/resources" --type vm --output-format json 2>/dev/null \
      | jq -e --argjson id "$CTID" '.[] | select(.vmid == $id)' >/dev/null; then
    echo "CT ${CTID} already exists, skipping creation."
    return
  fi

  echo "Creating CT ${CTID} (${HOSTNAME})..."

  local net0="name=eth0,bridge=${BRIDGE},ip=${IP}"
  [[ -n "${GW}" ]] && net0="${net0},gw=${GW}"

  # Validate and get CPU units for priority
  validate_priority "${CT_PRIORITY}" || exit 1
  
  run_on_node "$CREATE_NODE" pct create "${CTID}" "${TEMPLATE_PATH}" \
    --hostname "${HOSTNAME}" \
    --cores "${CORES}" \
    --memory "${MEMORY}" \
    --swap "$((MEMORY / 2))" \
    --cpuunits "${PRIORITY_CPUUNITS}" \
    --rootfs "${STORAGE}:${DISK}" \
    --net0 "${net0}" \
    --unprivileged 0 \
    --features nesting=1,fuse=1,keyctl=1 \
    --onboot 1
  CT_NODE["$CTID"]="$CREATE_NODE"
}

# Configure LXC for Docker capabilities support
configure_lxc_docker() {
  local lxc_conf="/etc/pve/lxc/${CTID}.conf"
  local needs_restart=false
  
  echo "Configuring LXC for Docker support..."
  
  # Add apparmor profile if not present
  if ! grep -q "^lxc.apparmor.profile:" "$lxc_conf" 2>/dev/null; then
    echo "lxc.apparmor.profile: unconfined" >> "$lxc_conf"
    needs_restart=true
  fi
  
  # Add cap.drop (empty) if not present
  if ! grep -q "^lxc.cap.drop:" "$lxc_conf" 2>/dev/null; then
    echo "lxc.cap.drop:" >> "$lxc_conf"
    needs_restart=true
  fi
  
  # Restart CT if config was changed and CT is running
  if [[ "$needs_restart" == "true" ]]; then
    echo "  LXC config updated, restarting CT..."
    if pct_status "${CTID}" | grep -q "status: running"; then
      pct_stop "${CTID}"
      sleep 2
    fi
    pct_start "${CTID}"
    sleep 3
  else
    echo "  LXC config already correct."
  fi
}

# Start the container
start_ct() {
  if ! pct_status "${CTID}" | grep -q "status: running"; then
    echo "Starting CT ${CTID}..."
    pct_start "${CTID}"
    sleep 3
  fi
}

# Install Docker and Docker Compose
# install_docker is now in commonCT.sh (shared single source of truth).
# The OpenRC boot runlevel is managed idempotently by ensure_docker_runlevel()
# via apply_ct_configuration (shared between createCT and refreshCT).

# Create docker-compose.yaml template
# create_compose_template is now in commonCT.sh (shared between createCT and refreshCT)

# Update or create .env file with required configuration values
# Merges values from commonCT.json while preserving user-defined variables
#
# Values and their sources:
#   HOSTNAME            - Argument passed to createCT.sh (e.g., app.thesaints.home)
#   STEP_CA_URL         - Constructed from domain: https://ca.<domain>/acme/acme/directory
#   STEP_CA_FINGERPRINT - From commonCT.json: ssl.<domain>.fingerprint
#   CADDY_EMAIL         - From commonCT.json: ssl.<domain>.email
#   DNSIMPLE_API_ACCESS_TOKEN - From commonCT.json: ssl.<domain>.dns_api_token (for letsencrypt+dnsimple)
#
# update_env_file is now in commonCT.sh (shared between createCT and refreshCT)

# Setup bind mounts
# setup_mountpoints is now in commonCT.sh (shared between createCT and refreshCT)

# Wait for condition with timeout
# Displays a spinning progress indicator while waiting
# Args: $1 = description, $2 = check command, $3 = timeout (default 30)
wait_for() {
  local description="$1"
  local check_cmd="$2"
  local timeout="${3:-30}"
  local spin=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')

  for ((i=1; i<=timeout; i++)); do
    if eval "$check_cmd" 2>/dev/null; then
      printf "\r  %s... done.%s\n" "$description" "$(printf ' %.0s' {1..20})"
      return 0
    fi
    printf "\r  Waiting for %s... %s (%ds/%ds)" "$description" "${spin[$((i % ${#spin[@]}))]}" "$i" "$timeout"
    sleep 1
  done
  printf "\r  %s... timed out.%s\n" "$description" "$(printf ' %.0s' {1..20})"
  return 1
}

# Verify container and Docker setup
verify_setup() {
  echo "Verifying CT ${CTID}..."

  # Wait for CT to be running
  if ! wait_for "CT running" "pct_status '${CTID}' | grep -q 'status: running'" 30; then
    echo "ERROR: CT ${CTID} failed to start after reboot."
    exit 1
  fi
  echo "  [✓] CT is running"

  # Wait for Docker daemon
  if ! wait_for "Docker daemon" "ct_exec --timeout 5 'docker info &>/dev/null'" 300; then
    echo "ERROR: Docker daemon not responding in CT ${CTID}."
    exit 1
  fi
  echo "  [✓] Docker daemon is running"

  # Verify docker compose
  if ! ct_exec --timeout 15 'docker compose version &>/dev/null'; then
    echo "ERROR: Docker Compose not available in CT ${CTID}."
    exit 1
  fi
  echo "  [✓] Docker Compose is available"

  # Verify mountpoints
  if ! ct_exec --timeout 15 'test -d /mnt/docker'; then
    echo "ERROR: /mnt/docker not mounted in CT ${CTID}."
    exit 1
  fi
  if ! ct_exec --timeout 15 'test -d /mnt/docker-data'; then
    echo "ERROR: /mnt/docker-data not mounted in CT ${CTID}."
    exit 1
  fi
  echo "  [✓] Mountpoints accessible"
}

# Print final summary
print_summary() {
  echo ""
  echo "Done. CT ${CTID} (${HOSTNAME}) is fully provisioned and verified."
  echo "  /mnt/docker      → $DIR_DOCKER"
  echo "  /mnt/docker-data → $DIR_DOCKER_DATA"
  echo "  docker-compose.yaml ensured at $COMPOSE_FILE"
  echo "  .env ensured at $ENV_FILE"
}

# Start docker compose if compose file has content
start_compose() {
  if [[ -s "$COMPOSE_FILE" ]]; then
    echo "Found existing docker-compose.yaml..."
    
    # Validate compose file first
    echo "  Validating docker-compose.yaml..."
    if ! ct_exec --timeout 30 'cd /mnt/docker && docker compose config --quiet' 2>/dev/null; then
      echo "  [!] Warning: docker-compose.yaml validation failed, skipping start"
      echo "      Fix the compose file and run: pct exec ${CTID} -- sh -c 'cd /mnt/docker && docker compose up -d'"
      return
    fi
    echo "  [✓] Compose file is valid"

    echo "  Pulling images..."
    if ! compose_pull "${CTID}"; then
      echo "ERROR: Failed to pull images before permission reconciliation." >&2
      return 1
    fi
    if ! reconcile_compose_permissions "${CTID}"; then
      echo "ERROR: Compose permission reconciliation failed." >&2
      return 1
    fi
    
    # Start services
    echo "  Starting services..."
    if compose_up "${CTID}"; then
      echo "  [✓] Docker Compose services started"
    else
      echo "ERROR: docker compose up failed" >&2
      return 1
    fi
  fi
}

# -----------------------------
# MAIN
# -----------------------------
main() {
  lifecycle_log_init "${BASH_SOURCE[0]}" "$@"
  # Parse arguments
  [[ $# -lt 1 ]] && usage
  
  HOSTNAME="$1"
  shift

  # Allow optional overrides and flags
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --monitor|-m)
        MONITOR_AFTER=true
        shift
        ;;
      --node)
        [[ -n "${2:-}" ]] || { echo "ERROR: --node requires a node." >&2; exit 1; }
        CREATE_NODE="$2"
        shift 2
        ;;
      --size|-s)
        CT_SIZE="$2"
        shift 2
        ;;
      --cores)
        if [[ ! "$2" =~ ^[1-9][0-9]*$ ]]; then
          echo "ERROR: --cores must be a positive integer (got '$2')" >&2
          exit 1
        fi
        CORES="$2"
        shift 2
        ;;
      --memory)
        if [[ ! "$2" =~ ^[1-9][0-9]*$ ]]; then
          echo "ERROR: --memory must be a positive integer in MB (got '$2')" >&2
          exit 1
        fi
        MEMORY="$2"
        shift 2
        ;;
      --priority|-p)
        CT_PRIORITY="$2"
        shift 2
        ;;
      --vlan)
        if [[ ! "$2" =~ ^(0|[1-9][0-9]*)$ ]] || (( $2 > 4094 )); then
          echo "ERROR: --vlan must be an integer in range 0-4094 (got '$2')" >&2
          exit 1
        fi
        CT_VLAN="$2"
        shift 2
        ;;
      STORAGE=*)
        echo "ERROR: CT rootfs storage is fixed to local-lvm; STORAGE overrides are unsupported." >&2
        exit 1
        ;;
      BRIDGE=*)
        echo "ERROR: BRIDGE overrides are unsupported; bridge assignment is derived from node policy." >&2
        exit 1
        ;;
      *=*)
        eval "$1"
        shift
        ;;
      *)
        echo "Unknown argument: $1"
        usage
        ;;
    esac
  done

  # Execute provisioning steps
  local total_steps=11
  local step=0
  
  status_bar_init
  
  step=$((step + 1)); status_progress "$step" "$total_steps" "Validating hostname..."
  validate_hostname "${HOSTNAME}" || exit 1
  if ! online_cluster_nodes | grep -Fxq "$CREATE_NODE"; then
    echo "ERROR: Target node '${CREATE_NODE}' is not online." >&2
    exit 1
  fi
  validate_node_storage_contract "$CREATE_NODE" || exit 1
  
  # Check if a CT with this hostname already exists
  build_ct_list
  local existing_ctid=""
  for id in "${CT_LIST[@]}"; do
    if [[ "${CT_MAP[$id]}" == "${HOSTNAME}" ]]; then
      existing_ctid="$id"
      break
    fi
  done
  
  if [[ -n "$existing_ctid" ]]; then
    status_bar_cleanup
    echo "CT ${existing_ctid} already exists with hostname '${HOSTNAME}'."
    local answer
    read -rp "Run refreshCT instead? [y/N]: " answer
    if [[ "$answer" =~ ^[Yy]$ ]]; then
      # Forward compatible flags to refreshCT.sh
      local refresh_args=("${existing_ctid}")
      [[ "$MONITOR_AFTER" == "true" ]] && refresh_args+=("--monitor")
      # refreshCT treats --size and --cores/--memory as mutually exclusive, so a
      # custom allocation (if given) takes precedence over the named size.
      if [[ -n "$CORES" || -n "$MEMORY" ]]; then
        [[ -n "$CORES" ]] && refresh_args+=("--cores" "$CORES")
        [[ -n "$MEMORY" ]] && refresh_args+=("--memory" "$MEMORY")
      elif [[ -n "$CT_SIZE" ]]; then
        refresh_args+=("--size" "$CT_SIZE")
      fi
      [[ -n "$CT_PRIORITY" ]] && refresh_args+=("--priority" "$CT_PRIORITY")
      [[ -n "$CT_VLAN" ]] && refresh_args+=("--vlan" "$CT_VLAN")
      exec "${SCRIPT_DIR}/refreshCT.sh" "${refresh_args[@]}"
    else
      echo "Aborted."
      exit 0
    fi
  fi
  
  step=$((step + 1)); status_progress "$step" "$total_steps" "Setting defaults..."
  set_defaults
  bridge_policy_resolve "$CREATE_NODE" CT "$CTID" "$HOSTNAME" || exit 1
  BRIDGE="$BRIDGE_POLICY_SELECTED"
  echo "Bridge policy: ${BRIDGE} (${BRIDGE_POLICY_REASON}, rank ${BRIDGE_POLICY_RANK})"
  validate_rootfs_target_capacity "$CREATE_NODE" "${DISK}" 20 || exit 1
  validate_os_root_headroom "$CREATE_NODE" 20 || exit 1
  
  step=$((step + 1)); status_progress "$step" "$total_steps" "Preparing template..."
  prepare_template
  
  step=$((step + 1)); status_progress "$step" "$total_steps" "Creating container..."
  create_ct
  apply_vlan_tag "${CTID}" "${CT_VLAN}"
  
  step=$((step + 1)); status_progress "$step" "$total_steps" "Configuring LXC for Docker..."
  configure_lxc_docker
  reconcile_ct_gpu_config "${CTID}" "$CREATE_NODE" || exit 1
  
  step=$((step + 1)); status_progress "$step" "$total_steps" "Starting container..."
  start_ct
  ensure_swap
  
  # Wait for network connectivity before installing packages. Only the Alpine package
  # CDN is probed here: install_docker (the very next step) installs from it, so an early
  # fatal check fails fast with a clear message. Registry reachability (ghcr.io/docker.io)
  # is intentionally NOT probed — it runs before Docker is installed (so a bare wget can't
  # validate Docker's real pull path) and compose_pull already owns it with retry/backoff.
  if ! wait_for "dl-cdn.alpinelinux.org" "ct_exec --timeout 5 'wget --spider -q https://dl-cdn.alpinelinux.org'" 30; then
    echo "ERROR: No network connectivity to Alpine package CDN in CT ${CTID}."
    exit 1
  fi
  echo "  [✓] Reachable: dl-cdn.alpinelinux.org"

  step=$((step + 1)); status_progress "$step" "$total_steps" "Installing Docker..."
  install_docker

  step=$((step + 1)); status_progress "$step" "$total_steps" "Applying configuration..."
  apply_ct_configuration "${CTID}" "${HOSTNAME}"
  finalize_ct_gpu_capability "${CTID}" "$CREATE_NODE" || exit 1

  step=$((step + 1)); status_progress "$step" "$total_steps" "Setting up mountpoints..."
  setup_mountpoints
  reboot_ct || echo "  [!] Reboot verification failed (non-fatal)"
  
  step=$((step + 1)); status_progress "$step" "$total_steps" "Verifying setup..."
  verify_setup
  start_compose || exit 1
  reboot_ct || echo "  [!] Reboot verification failed (non-fatal)"

  # MANDATORY: this CT is a Docker host — the post-compose reboot must leave the
  # daemon up (with active recovery) or provisioning is not actually complete.
  if ! ensure_docker_running "${CTID}"; then
    echo "ERROR: Docker daemon is not running in CT ${CTID} after reboot."
    exit 1
  fi
  
  step=$((step + 1)); status_progress "$step" "$total_steps" "Checking DNS..."
  check_dns_health "$CTID" "$HOSTNAME" || echo "  [!] DNS health check failed (non-fatal)"
  
  status_progress "$step" "$total_steps" "Running configure script..."
  sync_config_shared
  run_configure_script
  
  status_bar_cleanup
  
  print_summary
  reconcile_backup_job_selections || echo "  [!] Could not refresh managed backup job membership."

  # Optionally start monitoring
  if [[ "$MONITOR_AFTER" == "true" ]]; then
    echo ""
    echo "Starting log monitor..."
    lifecycle_log_stop 0
    exec "${SCRIPT_DIR}/monitorCT.sh" "$CTID"
  fi
}

main "$@"