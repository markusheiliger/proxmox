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
#   ./createCT.sh <hostname> [--size S|M|L] [--gpu] [key=value overrides...]
#
# EXAMPLES:
#   ./createCT.sh app.thesaints.home           # Default size S
#   ./createCT.sh app.thesaints.home --size M  # Medium size
#   ./createCT.sh app.thesaints.home --size L  # Large size (e.g., Seafile)
#   ./createCT.sh nvr.thesaints.home --gpu     # Enable GPU passthrough
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

# -----------------------------
# FUNCTIONS
# -----------------------------

# Show usage and exit
usage() {
  echo "Usage: $0 <hostname> [--size S|M|L] [--gpu] [key=value overrides]"
  echo ""
  echo "Options:"
  echo "  --size S|M|L    T-shirt size (default: S)"
  echo "  --gpu           Enable GPU passthrough (VAAPI)"
  echo "  --monitor       Start log monitor after creation"
  echo ""
  echo "Sizes (defined in commonCT.json):"
  echo "  S = Small  ($(config_get_size_cores S) cores, $(config_get_size_memory S) MB)"
  echo "  M = Medium ($(config_get_size_cores M) cores, $(config_get_size_memory M) MB)"
  echo "  L = Large  ($(config_get_size_cores L) cores, $(config_get_size_memory L) MB)"
  exit 1
}

# Allocate next available CTID (2000 + n*100)
next_ctid() {
  local base=2000
  local step=100
  local used
  used=$(pct list | awk '{print $1}' | grep -E '^[0-9]+$' | sort -n)

  local candidate=$base
  while true; do
    if ! echo "$used" | grep -qx "$candidate"; then
      echo "$candidate"
      return 0
    fi
    candidate=$((candidate + step))
  done
}

# Validate hostname against config
validate_hostname() {
  if ! config_exists; then
    echo "ERROR: Config file not found: ${CONFIG_FILE}"
    exit 1
  fi

  local hostname_parts
  hostname_parts=$(echo "${HOSTNAME}" | tr '.' '\n' | wc -l)

  if [[ "${HOSTNAME}" =~ ^ca\. ]]; then
    # CA host: must be fully qualified (at least 3 parts: ca.domain.tld)
    if [[ ${hostname_parts} -lt 3 ]]; then
      echo "ERROR: CA hostname must be fully qualified (e.g., ca.domain.tld)"
      echo "  Provided: ${HOSTNAME}"
      exit 1
    fi
    echo "Hostname validated: CA host"
  else
    # Regular host: domain must be in config
    local domain
    domain=$(extract_domain_from_hostname "${HOSTNAME}")
    
    if ! config_domain_exists "${domain}"; then
      echo "ERROR: Domain '${domain}' not configured in ${CONFIG_FILE}"
      echo "  Configured domains:"
      config_get_domains | sed 's/^/    /'
      exit 1
    fi
    echo "Hostname validated: domain '${domain}' found in config"
  fi
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

  pct create "${CTID}" "${TEMPLATE_PATH}" \
    --hostname "${HOSTNAME}" \
    --cores "${CORES}" \
    --memory "${MEMORY}" \
    --swap 0 \
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

  pct exec "${CTID}" -- sh -c '
    set -e
    apk update
    apk add docker docker-cli-compose
    rc-update add docker boot
    service docker start || true
  '
}

# Create docker-compose.yaml template
create_compose_template() {
  local compose_file="$1"
  local domain
  domain=$(extract_domain_from_hostname "${HOSTNAME}")
  local ca_url="https://$(config_get_ca_name "${domain}")/acme/acme/directory"
  
  cat > "$compose_file" << 'COMPOSE_EOF'
services:
  # Hello World service - replace with your actual application
  hello:
    container_name: hello
    restart: unless-stopped
    image: traefik/whoami:latest
    labels:
      caddy: ${HOSTNAME}
      caddy.reverse_proxy: "{{upstreams 80}}"

  # Caddy reverse proxy with automatic SSL
  caddy:
    container_name: caddy
    restart: unless-stopped
    image: ghcr.io/thesaints-de/caddy
    ports:
      - 80:80
      - 443:443
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - /mnt/docker/caddy/data:/data
    environment:
      STEP_CA_URL: ${STEP_CA_URL}
      STEP_CA_FINGERPRINT: ${STEP_CA_FINGERPRINT}
    labels:
      caddy.email: ${CADDY_EMAIL}
      caddy.acme_ca: ${STEP_CA_URL}
      caddy.acme_ca_root: /root/.step/certs/root_ca.crt

  # Newt tunnel for external access via Pangolin
  newt:
    container_name: newt
    restart: unless-stopped
    image: fosrl/newt
    profiles:
      - published
    environment:
      NEWT_ID: ${NEWT_ID}
      NEWT_SECRET: ${NEWT_SECRET}
      NEWT_ENDPOINT: ${NEWT_ENDPOINT}
COMPOSE_EOF
}

# Update or create .env file with required configuration values
# Merges values from commonCT.json while preserving user-defined variables
#
# Values and their sources:
#   HOSTNAME            - Argument passed to createCT.sh (e.g., app.thesaints.home)
#   STEP_CA_URL         - Constructed from domain: https://ca.<domain>/acme/acme/directory
#   STEP_CA_FINGERPRINT - From commonCT.json: step_ca.<domain>.fingerprint
#   CADDY_EMAIL         - From commonCT.json: step_ca.<domain>.email
#
update_env_file() {
  local env_file="$1"
  local domain
  domain=$(extract_domain_from_hostname "${HOSTNAME}")
  local ca_name
  ca_name=$(config_get_ca_name "${domain}")
  local fingerprint
  fingerprint=$(config_get_fingerprint "${domain}")
  local email
  email=$(config_get_email "${domain}")
  
  # Create file if it doesn't exist
  touch "$env_file"
  
  # Function to set or update a key in the .env file
  set_env_value() {
    local key="$1"
    local value="$2"
    local comment="$3"
    
    if grep -q "^${key}=" "$env_file"; then
      # Update existing key
      sed -i "s|^${key}=.*|${key}=${value}|" "$env_file"
    else
      # Add new key with optional comment
      if [[ -n "$comment" ]]; then
        echo -e "\n# ${comment}" >> "$env_file"
      fi
      echo "${key}=${value}" >> "$env_file"
    fi
  }
  
  # Update required configuration values
  set_env_value "HOSTNAME" "${HOSTNAME}" "Site hostname (from CT container)"
  set_env_value "STEP_CA_URL" "https://${ca_name}/acme/acme/directory" "Step CA configuration (from commonCT.json)"
  set_env_value "STEP_CA_FINGERPRINT" "${fingerprint}" ""
  set_env_value "CADDY_EMAIL" "${email}" "Caddy email for ACME (from commonCT.json)"
  
  # Add Newt/Pangolin placeholders if not already present
  if ! grep -q "^NEWT_ID=" "$env_file"; then
    echo -e "\n# Newt/Pangolin tunnel configuration (for 'published' profile)" >> "$env_file"
    echo "NEWT_ID=" >> "$env_file"
    echo "NEWT_SECRET=" >> "$env_file"
    echo "NEWT_ENDPOINT=" >> "$env_file"
  fi
  
  # Clean up multiple blank lines
  sed -i '/^$/N;/^\n$/d' "$env_file"
}

# Setup bind mounts
setup_mountpoints() {
  echo "Registering mountpoints for CT ${CTID}..."

  local hostname_lower
  hostname_lower=$(echo "$HOSTNAME" | tr '[:upper:]' '[:lower:]')

  DIR_DOCKER="/mnt/docker/${hostname_lower}"
  DIR_DOCKER_DATA="/mnt/docker-data/${hostname_lower}"

  mkdir -p "$DIR_DOCKER"
  mkdir -p "$DIR_DOCKER_DATA"
  mkdir -p "$DIR_DOCKER/caddy/data"

  echo "Created:"
  echo "  $DIR_DOCKER"
  echo "  $DIR_DOCKER_DATA"

  COMPOSE_FILE="${DIR_DOCKER}/docker-compose.yaml"
  ENV_FILE="${DIR_DOCKER}/.env"

  if [[ ! -f "$COMPOSE_FILE" ]]; then
    echo "Creating template docker-compose.yaml at $COMPOSE_FILE"
    create_compose_template "$COMPOSE_FILE"
  fi

  echo "Updating .env at $ENV_FILE"
  update_env_file "$ENV_FILE"

  echo "Removing existing mountpoints..."
  for mp in $(pct config "$CTID" | awk -F: '/^mp[0-9]+/ {print $1}'); do
    echo "  deleting $mp"
    pct set "$CTID" -delete "$mp"
  done

  echo "Adding new bind mounts..."
  pct set "$CTID" -mp0 "${DIR_DOCKER},mp=/mnt/docker"
  pct set "$CTID" -mp1 "${DIR_DOCKER_DATA},mp=/mnt/docker-data"

  echo "Mountpoints updated."
}

# Wait for condition with timeout
wait_for() {
  local description="$1"
  local check_cmd="$2"
  local timeout="${3:-30}"

  for ((i=1; i<=timeout; i++)); do
    if eval "$check_cmd"; then
      return 0
    fi
    sleep 1
  done
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
  if ! wait_for "Docker daemon" "pct exec '${CTID}' -- docker info &>/dev/null" 30; then
    echo "ERROR: Docker daemon not responding in CT ${CTID}."
    exit 1
  fi
  echo "  [✓] Docker daemon is running"

  # Verify docker compose
  if ! pct exec "${CTID}" -- docker compose version &>/dev/null; then
    echo "ERROR: Docker Compose not available in CT ${CTID}."
    exit 1
  fi
  echo "  [✓] Docker Compose is available"

  # Verify mountpoints
  if ! pct exec "${CTID}" -- test -d /mnt/docker; then
    echo "ERROR: /mnt/docker not mounted in CT ${CTID}."
    exit 1
  fi
  if ! pct exec "${CTID}" -- test -d /mnt/docker-data; then
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
    if ! pct exec "${CTID}" -- sh -c 'cd /mnt/docker && docker compose config --quiet' 2>/dev/null; then
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
  local total_steps=16
  local step=0
  
  status_bar_init
  
  step=$((step + 1)); status_progress "$step" "$total_steps" "Validating hostname..."
  validate_hostname
  
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
  
  step=$((step + 1)); status_progress "$step" "$total_steps" "Installing Docker..."
  install_docker
  
  step=$((step + 1)); status_progress "$step" "$total_steps" "Configuring timezone..."
  configure_timezone
  
  step=$((step + 1)); status_progress "$step" "$total_steps" "Configuring Docker logging..."
  configure_docker_logging "${HOSTNAME}"
  
  step=$((step + 1)); status_progress "$step" "$total_steps" "Configuring Telegraf..."
  configure_telegraf "${HOSTNAME}"
  
  step=$((step + 1)); status_progress "$step" "$total_steps" "Configuring syslog..."
  configure_syslog_forwarding "${HOSTNAME}"
  
  step=$((step + 1)); status_progress "$step" "$total_steps" "Configuring registries..."
  configure_registry_logins
  
  step=$((step + 1)); status_progress "$step" "$total_steps" "Configuring Step CA..."
  configure_step_ca "${HOSTNAME}"
  
  step=$((step + 1)); status_progress "$step" "$total_steps" "Setting up mountpoints..."
  setup_mountpoints
  reboot_ct
  
  # Configure GPU passthrough if requested
  if [[ "$GPU_PASSTHROUGH" == "true" ]]; then
    status_progress "$step" "$total_steps" "Configuring GPU passthrough..."
    configure_gpu_passthrough
  fi
  
  step=$((step + 1)); status_progress "$step" "$total_steps" "Verifying setup..."
  verify_setup
  start_compose
  reboot_ct
  
  step=$((step + 1)); status_progress "$step" "$total_steps" "Checking DNS..."
  check_dns_health "$CTID" "$HOSTNAME"
  
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