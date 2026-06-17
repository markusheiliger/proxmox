#!/usr/bin/env bash
#
# createCT.sh - Create a Proxmox LXC container with Docker pre-installed
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
#   ./createCT.sh <hostname> [--size S|M|L] [--priority low|mid|high] [--gpu] [key=value overrides...]
#
# EXAMPLES:
#   ./createCT.sh app.thesaints.home                   # Default size S, priority mid
#   ./createCT.sh app.thesaints.home --size M          # Medium size
#   ./createCT.sh app.thesaints.home --priority low    # Low priority (background)
#   ./createCT.sh app.thesaints.home --size L          # Large size (e.g., Seafile)
#   ./createCT.sh nvr.thesaints.home --gpu --priority high  # GPU + high priority
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
#   --gpu            Enable GPU passthrough for VAAPI hardware acceleration
#   CTID             Auto-allocated starting at 2000, step 100
#   STORAGE          local-lvm
#   DISK             16 (GB)
#   CORES            From size (S=1, M=2, L=4) or manual override
#   MEMORY           From size (S=1024, M=2048, L=4096) or manual override
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
GPU_PASSTHROUGH=false
CT_SIZE="S"
CT_PRIORITY="mid"

# -----------------------------
# FUNCTIONS
# -----------------------------

# Show usage and exit
usage() {
  echo "Usage: $0 <hostname> [--size S|M|L] [--priority low|mid|high] [--gpu] [key=value overrides]"
  echo ""
  echo "Options:"
  echo "  --size S|M|L             T-shirt size (default: S)"
  echo "  --priority low|mid|high  CPU priority (default: mid)"
  echo "  --gpu                    Enable GPU passthrough (VAAPI)"
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
  used=$(pct list | awk '{print $1}' | grep -E '^[0-9]+$' | sort -n)

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
  STORAGE="${STORAGE:-local-lvm}"
  DISK="${DISK:-16}"
  CORES="${CORES:-${SIZE_CORES}}"
  MEMORY="${MEMORY:-${SIZE_MEMORY}}"
  BRIDGE="${BRIDGE:-vmbr1}"
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
  pveam update >/dev/null

  local latest_template
  latest_template=$(pveam available | awk '{print $2}' \
    | grep "^${TEMPLATE_PREFIX}" \
    | sort -V \
    | tail -n 1)

  if [[ -z "${latest_template}" ]]; then
    echo "ERROR: No template found matching prefix '${TEMPLATE_PREFIX}'"
    exit 1
  fi

  echo "Latest matching template: ${latest_template}"
  TEMPLATE_PATH="${TEMPLATE_STORE}:vztmpl/${latest_template}"

  if ! pveam list "${TEMPLATE_STORE}" | awk '{print $2}' | grep -qx "${latest_template}"; then
    echo "Template not found locally. Downloading ${latest_template}..."
    pveam download "${TEMPLATE_STORE}" "${latest_template}"
  else
    echo "Template already present locally."
  fi
}

# Create the container
create_ct() {
  if pct status "${CTID}" &>/dev/null; then
    echo "CT ${CTID} already exists, skipping creation."
    return
  fi

  echo "Creating CT ${CTID} (${HOSTNAME})..."

  local net0="name=eth0,bridge=${BRIDGE},ip=${IP}"
  [[ -n "${GW}" ]] && net0="${net0},gw=${GW}"

  # Validate and get CPU units for priority
  validate_priority "${CT_PRIORITY}" || exit 1
  
  pct create "${CTID}" "${TEMPLATE_PATH}" \
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
    if pct status "${CTID}" | grep -q "status: running"; then
      pct stop "${CTID}"
      sleep 2
    fi
    pct start "${CTID}"
    sleep 3
  else
    echo "  LXC config already correct."
  fi
}

# Start the container
start_ct() {
  if ! pct status "${CTID}" | grep -q "status: running"; then
    echo "Starting CT ${CTID}..."
    pct start "${CTID}"
    sleep 3
  fi
}

# Install Docker and Docker Compose
install_docker() {
  echo "Installing Docker inside CT ${CTID}..."

  ct_exec --timeout 120 '
    set -e
    apk update
    apk add docker docker-cli-compose ca-certificates
    rc-update add docker boot
    service docker start || true
  '
}

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
  if ! wait_for "CT running" "pct status '${CTID}' | grep -q 'status: running'" 30; then
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
    
    # Start services
    echo "  Starting services..."
    if compose_up "${CTID}"; then
      echo "  [✓] Docker Compose services started"
    else
      echo "  [!] Warning: docker compose up failed"
    fi
  fi
}

# -----------------------------
# MAIN
# -----------------------------
main() {
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
      --size|-s)
        CT_SIZE="$2"
        shift 2
        ;;
      --gpu)
        GPU_PASSTHROUGH=true
        shift
        ;;
      --priority|-p)
        CT_PRIORITY="$2"
        shift 2
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
      [[ -n "$CT_SIZE" ]] && refresh_args+=("--size" "$CT_SIZE")
      [[ "$GPU_PASSTHROUGH" == "true" ]] && refresh_args+=("--gpu")
      [[ -n "$CT_PRIORITY" ]] && refresh_args+=("--priority" "$CT_PRIORITY")
      exec "${SCRIPT_DIR}/refreshCT.sh" "${refresh_args[@]}"
    else
      echo "Aborted."
      exit 0
    fi
  fi
  
  step=$((step + 1)); status_progress "$step" "$total_steps" "Setting defaults..."
  set_defaults
  
  step=$((step + 1)); status_progress "$step" "$total_steps" "Preparing template..."
  prepare_template
  
  step=$((step + 1)); status_progress "$step" "$total_steps" "Creating container..."
  create_ct
  
  step=$((step + 1)); status_progress "$step" "$total_steps" "Configuring LXC for Docker..."
  configure_lxc_docker
  
  step=$((step + 1)); status_progress "$step" "$total_steps" "Starting container..."
  start_ct
  ensure_swap
  
  # Wait for network connectivity before installing packages
  local net_targets=("https://dl-cdn.alpinelinux.org" "https://registry-1.docker.io" "https://ghcr.io")
  local net_ok=() net_fail=()
  for target in "${net_targets[@]}"; do
    local host="${target#https://}"
    if wait_for "${host}" "ct_exec --timeout 5 'wget --spider -q ${target}'" 30; then
      net_ok+=("$host")
    else
      net_fail+=("$host")
    fi
  done
  if [[ ${#net_ok[@]} -gt 0 ]]; then
    echo "  [✓] Reachable: ${net_ok[*]}"
  fi
  for host in "${net_fail[@]}"; do
    echo "  [!] Warning: ${host} is not reachable — image pulls may fail"
  done
  # Alpine CDN is required for package installation
  if [[ " ${net_fail[*]} " == *" dl-cdn.alpinelinux.org "* ]]; then
    echo "ERROR: No network connectivity to Alpine package CDN in CT ${CTID}."
    exit 1
  fi

  step=$((step + 1)); status_progress "$step" "$total_steps" "Installing Docker..."
  install_docker

  step=$((step + 1)); status_progress "$step" "$total_steps" "Applying configuration..."
  apply_ct_configuration "${CTID}" "${HOSTNAME}" "${GPU_PASSTHROUGH}"

  step=$((step + 1)); status_progress "$step" "$total_steps" "Setting up mountpoints..."
  setup_mountpoints
  reboot_ct || echo "  [!] Reboot verification failed (non-fatal)"
  
  step=$((step + 1)); status_progress "$step" "$total_steps" "Verifying setup..."
  verify_setup
  start_compose
  reboot_ct || echo "  [!] Reboot verification failed (non-fatal)"
  
  step=$((step + 1)); status_progress "$step" "$total_steps" "Checking DNS..."
  check_dns_health "$CTID" "$HOSTNAME" || echo "  [!] DNS health check failed (non-fatal)"
  
  status_progress "$step" "$total_steps" "Running configure script..."
  run_configure_script
  
  status_bar_cleanup
  
  print_summary

  # Optionally start monitoring
  if [[ "$MONITOR_AFTER" == "true" ]]; then
    echo ""
    echo "Starting log monitor..."
    exec "${SCRIPT_DIR}/monitorCT.sh" "$CTID"
  fi
}

main "$@"