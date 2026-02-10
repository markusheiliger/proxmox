#!/usr/bin/env bash
#
# commonCT.sh - Shared functions for CT management scripts
#
# DESCRIPTION:
#   Common utilities for createCT.sh, deleteCT.sh, and refreshCT.sh.
#   This file is meant to be dot-sourced, not executed directly.
#
#   Many functions are designed to be IDEMPOTENT - safe to run multiple
#   times without side effects. This allows refreshCT.sh to apply the
#   same configuration functions as createCT.sh to update existing CTs.
#
# USAGE:
#   source "$(dirname "${BASH_SOURCE[0]}")/commonCT.sh"
#   # or
#   . /root/commonCT.sh
#
# IDEMPOTENT CONFIGURATION FUNCTIONS:
#   These functions can be safely called multiple times on the same CT.
#   They check current state and only apply changes when needed.
#
#   configure_timezone        Install tzdata, fix /etc/localtime symlink
#   configure_docker_logging  Set Docker daemon.json for fluentd logging
#   configure_telegraf        Install/configure Telegraf metrics to OTEL
#   configure_syslog_forwarding  Configure busybox syslogd remote logging
#   configure_step_ca         Install step-cli, bootstrap CA trust
#   configure_registry_logins  Authenticate Docker to configured registries
#   configure_gpu_passthrough Configure GPU passthrough (VAAPI)
#
#   Host-specific behavior:
#   - CA hosts (ca.*): Skip logging, telegraf, syslog, step_ca
#   - OTEL hosts (otel.*): Skip logging, syslog (would loop)
#
# UTILITY FUNCTIONS:
#   build_ct_list          Build list of all containers into CT_MAP and CT_LIST
#   select_ct_interactive_single  Display whiptail menu to select one container
#   select_ct_interactive_multi   Display whiptail checklist to select multiple containers
#   resolve_ct_from_input  Resolve CTID/hostname from user input
#   ensure_ct_running      Ensure container is running (starts if stopped)
#   ensure_ct_stopped      Verify container is stopped
#   get_ct_status          Get container status
#   ct_exec                Execute command in container
#   reboot_ct              Reboot container and wait for it to come back up
#   compose_up             Start Docker Compose services in CT
#   compose_down           Stop Docker Compose services in CT
#   extract_domain_from_hostname  Extract domain from hostname
#
# CONFIG FUNCTIONS (read from commonCT.json):
#   config_exists          Check if config file exists
#   config_get_domains     Get list of configured domains
#   config_domain_exists   Check if domain is configured
#   config_get_fingerprint Get Step CA fingerprint for domain
#   config_get_email       Get email for domain
#   config_get_ca_name     Get CA name for domain
#   config_size_exists     Check if size is defined
#   config_get_sizes       Get list of available sizes
#   config_get_size_cores  Get cores for size
#   config_get_size_memory Get memory for size
#   validate_size          Validate size and set SIZE_CORES/SIZE_MEMORY
#   config_get_newt_id     Get newt ID for hostname
#   config_get_newt_secret Get newt secret for hostname
#   config_get_newt_endpoint Get newt endpoint (global or per-site)
#   config_get_registries  Get list of configured container registries
#   config_get_registry_username Get username for registry
#   config_get_registry_password Get password for registry
#
# PROVIDED VARIABLES:
#   SCRIPT_DIR             Directory containing the calling script
#   CONFIG_FILE            Path to commonCT.json
#   CT_MAP                 Associative array: CTID -> hostname
#   CT_LIST                Array of CTIDs
#   CTID                   Selected container ID
#   CT_HOSTNAME            Selected container hostname
#
# SEE ALSO:
#   createCT.sh      Create a new container with Docker
#   refreshCT.sh     Refresh/update container configuration
#   deleteCT.sh      Delete a container
#   monitorCT.sh     Stream Docker Compose logs
#

# Prevent direct execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "This script should be sourced, not executed directly."
  echo "Usage: source commonCT.sh"
  exit 1
fi

# -----------------------------
# GLOBAL VARIABLES
# -----------------------------
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)}"
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/commonCT.json}"

declare -A CT_MAP
declare -a CT_LIST
CTID=""
CT_HOSTNAME=""

# Status bar state
STATUS_BAR_ENABLED=false
STATUS_BAR_TEXT=""

# -----------------------------
# STATUS BAR FUNCTIONS
# -----------------------------

# Initialize status bar (reserves bottom line of terminal)
# Call this before starting operations that use status_update
status_bar_init() {
  STATUS_BAR_ENABLED=true
  local rows
  rows=$(tput lines)
  # Clear screen first
  clear
  # Set scroll region to exclude last line
  printf '\e[1;%dr' "$((rows-1))"
  # Move cursor to top-left of scroll region
  printf '\e[1;1H'
  # Clear the status line and set initial text
  printf '\e[%d;1H\e[0;7m Starting...\e[K\e[0m' "$rows"
  # Move cursor back to scroll region
  printf '\e[1;1H'
}

# Update the status bar text
# Args: $1 = status text
status_update() {
  [[ "$STATUS_BAR_ENABLED" != "true" ]] && return
  STATUS_BAR_TEXT="$1"
  local rows cols
  rows=$(tput lines)
  cols=$(tput cols)
  # Truncate text if too long
  local text="${1:0:$((cols-2))}"
  # Save cursor, move to status line (outside scroll region), print, restore
  printf '\e7\e[%d;1H\e[0;7m %s\e[K\e[0m\e8' "$rows" "$text"
}

# Update status bar with progress info
# Args: $1 = current, $2 = total, $3 = message
status_progress() {
  local current="$1" total="$2" msg="$3"
  local pct=$((current * 100 / total))
  status_update "[${current}/${total}] ${pct}% - ${msg}"
}

# Clean up status bar (restore full scroll region)
status_bar_cleanup() {
  if [[ "$STATUS_BAR_ENABLED" == "true" ]]; then
    local rows
    rows=$(tput lines)
    # Restore full scroll region
    printf '\e[1;%dr' "$rows"
    # Clear status line
    printf '\e[%d;1H\e[K' "$rows"
    # Move cursor to bottom of restored region
    printf '\e[%d;1H' "$((rows-1))"
    STATUS_BAR_ENABLED=false
  fi
}

# Trap to ensure cleanup on exit
trap 'status_bar_cleanup' EXIT

# -----------------------------
# CONFIGURATION FUNCTIONS
# -----------------------------

# Check if config file exists
# Returns: 0 if exists, 1 if not
config_exists() {
  [[ -f "${CONFIG_FILE}" ]]
}

# Get list of configured domains
# Returns: newline-separated list of domains
config_get_domains() {
  if ! config_exists; then
    return 1
  fi
  grep -oP '"[^"]+"\s*:\s*\{' "${CONFIG_FILE}" | grep -v step_ca | sed 's/[":{}]//g' | tr -d ' '
}

# Check if domain is configured
# Args: $1 = domain name
# Returns: 0 if configured, 1 if not
config_domain_exists() {
  local domain="$1"
  if ! config_exists; then
    return 1
  fi
  grep -q "\"${domain}\"" "${CONFIG_FILE}"
}

# Get Step CA fingerprint for domain
# Args: $1 = domain name
# Returns: fingerprint string (or empty if not found)
config_get_fingerprint() {
  local domain="$1"
  if ! config_exists; then
    return 1
  fi
  grep -A2 "\"${domain}\"" "${CONFIG_FILE}" | grep fingerprint | sed 's/.*"fingerprint"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/'
}

# Get email for domain
# Args: $1 = domain name
# Returns: email string (or empty if not found)
config_get_email() {
  local domain="$1"
  if ! config_exists; then
    return 1
  fi
  grep -A3 "\"${domain}\"" "${CONFIG_FILE}" | grep email | sed 's/.*"email"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/'
}

# Get CA name for domain
# Args: $1 = domain name
# Returns: ca.<domain>
config_get_ca_name() {
  local domain="$1"
  echo "ca.${domain}"
}

# Extract domain from hostname
# Args: $1 = hostname (e.g., app.thesaints.home)
# Returns: domain (e.g., thesaints.home)
extract_domain_from_hostname() {
  local hostname="$1"
  echo "${hostname}" | sed 's/^[^.]*\.//'
}

# Check if size is defined in config
# Args: $1 = size name (e.g., S, M, L)
# Returns: 0 if defined, 1 if not
config_size_exists() {
  local size="$1"
  if ! config_exists; then
    return 1
  fi
  jq -e ".sizes.\"${size}\"" "${CONFIG_FILE}" >/dev/null 2>&1
}

# Get available size names
# Returns: space-separated list of size names
config_get_sizes() {
  if ! config_exists; then
    return 1
  fi
  jq -r '.sizes | keys | join(" ")' "${CONFIG_FILE}" 2>/dev/null
}

# Get cores for size
# Args: $1 = size name (e.g., S, M, L)
# Returns: number of cores
config_get_size_cores() {
  local size="$1"
  if ! config_exists; then
    return 1
  fi
  jq -r ".sizes.\"${size}\".cores // empty" "${CONFIG_FILE}" 2>/dev/null
}

# Get memory for size
# Args: $1 = size name (e.g., S, M, L)
# Returns: memory in MB
config_get_size_memory() {
  local size="$1"
  if ! config_exists; then
    return 1
  fi
  jq -r ".sizes.\"${size}\".memory // empty" "${CONFIG_FILE}" 2>/dev/null
}

# Validate size and return values
# Args: $1 = size name
# Sets: SIZE_CORES, SIZE_MEMORY (global)
# Returns: 0 if valid, 1 if invalid (with error message)
validate_size() {
  local size="$1"
  
  if ! config_size_exists "$size"; then
    echo "ERROR: Size '${size}' not defined in ${CONFIG_FILE}"
    echo "  Available sizes: $(config_get_sizes)"
    return 1
  fi
  
  SIZE_CORES=$(config_get_size_cores "$size")
  SIZE_MEMORY=$(config_get_size_memory "$size")
  
  if [[ -z "$SIZE_CORES" || -z "$SIZE_MEMORY" ]]; then
    echo "ERROR: Size '${size}' is missing cores or memory definition"
    return 1
  fi
  
  return 0
}

# -----------------------------
# NEWT CONFIGURATION FUNCTIONS
# -----------------------------

# Get newt ID for hostname
# Args: $1 = hostname (e.g., seafile.thesaints.home)
# Returns: newt ID or empty
config_get_newt_id() {
  local hostname="$1"
  if ! config_exists; then
    return 1
  fi
  jq -r ".newt.sites.\"${hostname}\".id // empty" "${CONFIG_FILE}" 2>/dev/null
}

# Get newt secret for hostname
# Args: $1 = hostname (e.g., seafile.thesaints.home)
# Returns: newt secret or empty
config_get_newt_secret() {
  local hostname="$1"
  if ! config_exists; then
    return 1
  fi
  jq -r ".newt.sites.\"${hostname}\".secret // empty" "${CONFIG_FILE}" 2>/dev/null
}

# Get newt endpoint (global or per-site override)
# Args: $1 = hostname (optional, for per-site override)
# Returns: endpoint URL or empty
config_get_newt_endpoint() {
  local hostname="$1"
  if ! config_exists; then
    return 1
  fi
  # Check for per-site endpoint first, fall back to global
  local endpoint
  if [[ -n "$hostname" ]]; then
    endpoint=$(jq -r ".newt.sites.\"${hostname}\".endpoint // empty" "${CONFIG_FILE}" 2>/dev/null)
  fi
  if [[ -z "$endpoint" ]]; then
    endpoint=$(jq -r ".newt.endpoint // empty" "${CONFIG_FILE}" 2>/dev/null)
  fi
  echo "$endpoint"
}

# -----------------------------
# REGISTRY CONFIGURATION FUNCTIONS
# -----------------------------

# Get list of configured container registries
# Returns: newline-separated list of registry names
config_get_registries() {
  if ! config_exists; then
    return 1
  fi
  jq -r '.registries // {} | keys[]' "${CONFIG_FILE}" 2>/dev/null
}

# Get username for a container registry
# Args: $1 = registry name (e.g., ghcr.io)
# Returns: username or empty
config_get_registry_username() {
  local registry="$1"
  if ! config_exists; then
    return 1
  fi
  jq -r ".registries.\"${registry}\".username // empty" "${CONFIG_FILE}" 2>/dev/null
}

# Get password for a container registry
# Args: $1 = registry name (e.g., ghcr.io)
# Returns: password or empty
config_get_registry_password() {
  local registry="$1"
  if ! config_exists; then
    return 1
  fi
  jq -r ".registries.\"${registry}\".password // empty" "${CONFIG_FILE}" 2>/dev/null
}

# Configure timezone in CT
# Installs tzdata and sets /etc/localtime to Europe/Berlin
# Idempotent: safe to run multiple times
# Args:
#   $1 - timezone (optional, defaults to Europe/Berlin)
# Requires: CTID to be set
configure_timezone() {
  local timezone="${1:-Europe/Berlin}"
  
  echo "Configuring timezone..."
  echo "  Timezone: ${timezone}"
  
  # Check if tzdata needs to be installed
  local tzdata_installed
  tzdata_installed=$(pct exec "${CTID}" -- sh -c 'apk info -e tzdata >/dev/null 2>&1 && echo "yes" || echo "no"')
  
  if [[ "$tzdata_installed" != "yes" ]]; then
    echo "  Installing tzdata..."
    pct exec "${CTID}" -- apk add --no-cache tzdata >/dev/null
  else
    echo "  tzdata already installed"
  fi
  
  # Fix /etc/localtime
  pct exec "${CTID}" -- sh -c "
    # Remove if directory (corrupted state)
    if [ -d /etc/localtime ]; then
      rm -rf /etc/localtime
      echo '  Fixed: removed /etc/localtime directory'
    fi
    
    # Create symlink if not already correct
    target=\"/usr/share/zoneinfo/${timezone}\"
    if [ -L /etc/localtime ]; then
      current=\$(readlink /etc/localtime)
      if [ \"\$current\" != \"\$target\" ]; then
        rm -f /etc/localtime
        ln -s \"\$target\" /etc/localtime
        echo '  Updated symlink'
      fi
    else
      rm -f /etc/localtime 2>/dev/null || true
      ln -s \"\$target\" /etc/localtime
      echo '  Created symlink'
    fi
  "
  
  echo "  [✓] Timezone configured"
}

# Configure Docker log forwarding to OTEL
# Args: $1 = CT hostname (e.g., seafile.thesaints.home)
# Uses: CTID global variable
configure_docker_logging() {
  local ct_hostname="${1:-${CT_HOSTNAME:-${HOSTNAME}}}"
  
  # Skip for CA hosts
  if [[ "${ct_hostname}" =~ ^ca\. ]]; then
    echo "Skipping log forwarding for CA host."
    return
  fi

  # Skip for otel host itself (avoid loop)
  if [[ "${ct_hostname}" =~ ^otel\. ]]; then
    echo "Skipping log forwarding for OTEL host (would loop)."
    return
  fi

  echo "Configuring Docker log forwarding to OTEL..."

  local domain otel_host
  domain=$(extract_domain_from_hostname "${ct_hostname}")
  otel_host="otel.${domain}"

  echo "  Log target: ${otel_host}:24224"
  echo "  Tag format: ${ct_hostname}.{{.Name}}"

  # Build daemon.json using jq
  # Tag format: hostname.containername (e.g., seafile.thesaints.home.seafile-db)
  local daemon_json
  daemon_json=$(jq -n \
    --arg addr "${otel_host}:24224" \
    --arg hostname "${ct_hostname}" \
    '{
      "log-driver": "fluentd",
      "log-opts": {
        "fluentd-address": $addr,
        "fluentd-async": "true",
        "fluentd-buffer-limit": "2097152",
        "tag": ($hostname + ".{{.Name}}")
      }
    }')

  pct exec "${CTID}" -- sh -c "
    mkdir -p /etc/docker
    echo '${daemon_json}' > /etc/docker/daemon.json
  "
  echo "  [✓] Docker log forwarding configured"
}

# Configure Telegraf for metrics collection
# Installs telegraf and configures it to send metrics to OTEL collector
# Idempotent: skips if already configured with correct settings
# Args:
#   $1 - hostname (optional, defaults to CT_HOSTNAME or HOSTNAME)
# Requires: CTID to be set
configure_telegraf() {
  local ct_hostname="${1:-${CT_HOSTNAME:-${HOSTNAME}}}"
  
  # Skip for CA hosts (no metrics needed)
  if [[ "${ct_hostname}" =~ ^ca\. ]]; then
    echo "Skipping Telegraf for CA host."
    return
  fi

  echo "Configuring Telegraf metrics collection..."

  local domain otel_host
  domain=$(extract_domain_from_hostname "${ct_hostname}")
  otel_host="otel.${domain}"

  echo "  Metrics target: ${otel_host}:4317"

  # Check if telegraf is installed
  local telegraf_installed
  telegraf_installed=$(pct exec "${CTID}" -- sh -c 'command -v telegraf >/dev/null 2>&1 && echo "yes" || echo "no"')
  
  if [[ "$telegraf_installed" != "yes" ]]; then
    echo "  Installing telegraf..."
    pct exec "${CTID}" -- sh -c '
      apk add --no-cache telegraf
    '
  else
    echo "  Telegraf already installed"
  fi

  # Ensure telegraf user can access docker socket
  local in_docker_group
  in_docker_group=$(pct exec "${CTID}" -- sh -c 'groups telegraf 2>/dev/null | grep -q docker && echo "yes" || echo "no"')
  if [[ "$in_docker_group" != "yes" ]]; then
    echo "  Adding telegraf user to docker group..."
    pct exec "${CTID}" -- adduser telegraf docker 2>/dev/null || true
  fi

  # Build telegraf config
  local telegraf_conf
  telegraf_conf="# Telegraf configuration for ${ct_hostname}
# Auto-generated by commonCT.sh - manual changes may be overwritten

[agent]
  interval = \"10s\"
  round_interval = true
  metric_batch_size = 1000
  metric_buffer_limit = 10000
  collection_jitter = \"0s\"
  flush_interval = \"10s\"
  flush_jitter = \"0s\"
  precision = \"0s\"
  hostname = \"${ct_hostname}\"
  omit_hostname = false

[[outputs.opentelemetry]]
  service_address = \"${otel_host}:4317\"
  [outputs.opentelemetry.attributes]
    \"service.name\" = \"${ct_hostname}\"
    \"service.namespace\" = \"${domain}\"

# Host metrics
[[inputs.cpu]]
  percpu = true
  totalcpu = true
  collect_cpu_time = false
  report_active = false

[[inputs.mem]]

[[inputs.disk]]
  ignore_fs = [\"tmpfs\", \"devtmpfs\", \"devfs\", \"iso9660\", \"overlay\", \"aufs\", \"squashfs\"]

[[inputs.diskio]]

[[inputs.net]]
  ignore_protocol_stats = true

[[inputs.system]]

[[inputs.processes]]

# Docker metrics
[[inputs.docker]]
  endpoint = \"unix:///var/run/docker.sock\"
  gather_services = false
  timeout = \"5s\"
"

  # Write config and ensure service is enabled
  pct exec "${CTID}" -- sh -c "
    mkdir -p /etc/telegraf
    cat > /etc/telegraf/telegraf.conf << 'TELEGRAF_EOF'
${telegraf_conf}
TELEGRAF_EOF

    # Set correct config path for OpenRC service
    echo 'TELEGRAF_OPTS=\"-config /etc/telegraf/telegraf.conf\"' > /etc/conf.d/telegraf
    
    # Enable service (OpenRC)
    rc-update add telegraf default >/dev/null 2>&1 || true
    
    # Restart to apply config (or start if not running)
    if rc-service telegraf status >/dev/null 2>&1; then
      rc-service telegraf restart >/dev/null 2>&1
    else
      rc-service telegraf start >/dev/null 2>&1
    fi
  "
  
  # Wait for service to stabilize
  sleep 4
  
  # Verify service is running
  local service_status
  service_status=$(pct exec "${CTID}" -- rc-service telegraf status 2>&1 || true)
  if echo "$service_status" | grep -q "started"; then
    echo "  [✓] Telegraf configured and running"
  elif echo "$service_status" | grep -q "crashed"; then
    echo "  [!] Warning: Telegraf service crashed - check config with: pct exec ${CTID} -- telegraf --test"
  else
    echo "  [!] Warning: Telegraf service status unknown"
  fi
}

# Configure syslog forwarding to OTEL collector
# Idempotent: updates config and restarts syslog if needed
# Args:
#   $1 - hostname (optional, defaults to CT_HOSTNAME or HOSTNAME)
# Requires: CTID to be set
configure_syslog_forwarding() {
  local ct_hostname="${1:-${CT_HOSTNAME:-${HOSTNAME}}}"
  
  # Skip for CA hosts
  if [[ "${ct_hostname}" =~ ^ca\. ]]; then
    echo "Skipping syslog forwarding for CA host."
    return
  fi

  # Skip for otel host itself (avoid loop)
  if [[ "${ct_hostname}" =~ ^otel\. ]]; then
    echo "Skipping syslog forwarding for OTEL host (would loop)."
    return
  fi

  echo "Configuring syslog forwarding..."

  local domain otel_host
  domain=$(extract_domain_from_hostname "${ct_hostname}")
  otel_host="otel.${domain}"

  echo "  Syslog target: ${otel_host}:514"

  # Alpine uses busybox syslogd - configure remote logging
  pct exec "${CTID}" -- sh -c "
    # Check current config
    current_opts=\$(grep '^SYSLOGD_OPTS=' /etc/conf.d/syslog 2>/dev/null || echo '')
    expected_opts='SYSLOGD_OPTS=\"-t -L -R ${otel_host}:514\"'
    
    if [ \"\$current_opts\" = \"\$expected_opts\" ]; then
      echo '  Syslog already configured correctly'
    else
      # Update syslogd config to forward to remote
      if grep -q '^SYSLOGD_OPTS=' /etc/conf.d/syslog 2>/dev/null; then
        sed -i 's|^SYSLOGD_OPTS=.*|SYSLOGD_OPTS=\"-t -L -R ${otel_host}:514\"|' /etc/conf.d/syslog
      else
        echo 'SYSLOGD_OPTS=\"-t -L -R ${otel_host}:514\"' >> /etc/conf.d/syslog
      fi
      # Restart syslog service
      service syslog restart >/dev/null 2>&1 || true
      echo '  Syslog config updated'
    fi
  "
  
  echo "  [✓] Syslog forwarding configured"
}

# Configure Step CA root certificate trust
# Installs step-cli and bootstraps CA trust
# Idempotent: uses --force flag to update existing config
# Args:
#   $1 - hostname (optional, defaults to CT_HOSTNAME or HOSTNAME)
# Requires: CTID to be set
configure_step_ca() {
  local ct_hostname="${1:-${CT_HOSTNAME:-${HOSTNAME}}}"
  
  # Skip for CA hosts
  if [[ "${ct_hostname}" =~ ^ca\. ]]; then
    echo "Skipping Step CA setup for CA host."
    return
  fi

  echo "Configuring Step CA trust..."

  local domain ca_name fingerprint
  domain=$(extract_domain_from_hostname "${ct_hostname}")
  ca_name=$(config_get_ca_name "${domain}")
  fingerprint=$(config_get_fingerprint "${domain}")

  echo "  CA: ${ca_name}"
  echo "  Fingerprint: ${fingerprint:0:16}..."

  # Check if step-cli is installed
  local step_installed
  step_installed=$(pct exec "${CTID}" -- sh -c 'command -v step >/dev/null 2>&1 && echo "yes" || echo "no"')
  
  if [[ "$step_installed" != "yes" ]]; then
    echo "  Installing step-cli..."
    pct exec "${CTID}" -- apk add --no-cache step-cli >/dev/null
  else
    echo "  step-cli already installed"
  fi

  # Bootstrap CA trust (--force makes it idempotent)
  pct exec "${CTID}" -- step ca bootstrap \
    --ca-url "https://${ca_name}" \
    --fingerprint "${fingerprint}" \
    --install --force >/dev/null 2>&1
  
  echo "  [✓] Step CA trust configured"
}

# Configure GPU passthrough for hardware acceleration (e.g., VAAPI)
# Idempotent: only adds config if not already present
# Requires a full stop/start cycle to apply mount changes
# Args:
#   $1 - CTID (optional, defaults to global CTID)
configure_gpu_passthrough() {
  local ctid="${1:-${CTID}}"
  local config_file="/etc/pve/lxc/${ctid}.conf"
  
  echo "Configuring GPU passthrough for CT ${ctid}..."
  
  # Check if host has GPU devices
  if [[ ! -d /dev/dri ]]; then
    echo "  [!] No GPU found on host (/dev/dri does not exist)"
    return 1
  fi
  
  # Get render device GID from host
  local render_gid
  render_gid=$(stat -c '%g' /dev/dri/renderD128 2>/dev/null) || {
    echo "  [!] Could not determine render device GID"
    return 1
  }
  
  # Check if GPU passthrough is already configured
  local needs_config=false
  if ! grep -q "lxc.cgroup2.devices.allow: c 226:\* rwm" "$config_file" 2>/dev/null; then
    needs_config=true
  fi
  if ! grep -q "lxc.mount.entry: /dev/dri" "$config_file" 2>/dev/null; then
    needs_config=true
  fi
  
  if [[ "$needs_config" == "false" ]]; then
    echo "  GPU passthrough already configured"
    # Still ensure render group exists inside CT
    pct exec "${ctid}" -- sh -c "
      addgroup -g ${render_gid} render 2>/dev/null || true
      addgroup root render 2>/dev/null || true
    " 2>/dev/null
    echo "  [✓] GPU passthrough ready"
    return 0
  fi
  
  echo "  Adding GPU passthrough configuration..."
  
  # Add cgroup device access
  if ! grep -q "lxc.cgroup2.devices.allow: c 226:\* rwm" "$config_file"; then
    echo "lxc.cgroup2.devices.allow: c 226:* rwm" >> "$config_file"
    echo "  Added cgroup2 device access for DRI"
  fi
  
  # Add mount entry for /dev/dri
  if ! grep -q "lxc.mount.entry: /dev/dri" "$config_file"; then
    echo "lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir" >> "$config_file"
    echo "  Added /dev/dri bind mount"
  fi
  
  # Need full stop/start for mount changes to take effect
  echo "  Stopping CT ${ctid} to apply mount changes..."
  pct stop "${ctid}"
  
  # Wait for stop
  local timeout=30
  for ((i=1; i<=timeout; i++)); do
    if pct status "${ctid}" 2>/dev/null | grep -q "status: stopped"; then
      break
    fi
    sleep 1
  done
  
  echo "  Starting CT ${ctid}..."
  pct start "${ctid}"
  
  # Wait for start and responsiveness
  local running=false
  for ((i=1; i<=timeout; i++)); do
    if pct status "${ctid}" 2>/dev/null | grep -q "status: running"; then
      running=true
      break
    fi
    sleep 1
  done
  
  if [[ "$running" != "true" ]]; then
    echo "  [!] Warning: CT ${ctid} did not start within ${timeout}s"
    return 1
  fi
  
  # Wait for responsiveness
  local responsive=false
  for ((i=1; i<=timeout; i++)); do
    if pct exec "${ctid}" -- true 2>/dev/null; then
      responsive=true
      break
    fi
    sleep 1
  done
  
  if [[ "$responsive" != "true" ]]; then
    echo "  [!] Warning: CT ${ctid} not responsive within ${timeout}s"
    return 1
  fi
  
  # Add render group inside CT with matching GID
  echo "  Configuring render group inside CT..."
  pct exec "${ctid}" -- sh -c "
    addgroup -g ${render_gid} render 2>/dev/null || true
    addgroup root render 2>/dev/null || true
  "
  
  # Verify device is accessible
  if pct exec "${ctid}" -- test -e /dev/dri/renderD128 2>/dev/null; then
    echo "  [✓] GPU passthrough configured successfully"
  else
    echo "  [!] Warning: /dev/dri/renderD128 not accessible in CT"
    return 1
  fi
  
  return 0
}

# Configure container registry authentication for Docker
# Logs into all registries defined in commonCT.json
# Idempotent: re-authenticates on each run (login is cheap)
# Requires: CTID to be set
configure_registry_logins() {
  echo "Configuring container registry authentication..."
  
  local registries
  registries=$(config_get_registries)
  
  if [[ -z "$registries" ]]; then
    echo "  No registries configured in ${CONFIG_FILE}"
    return 0
  fi
  
  local count=0
  while IFS= read -r registry; do
    [[ -z "$registry" ]] && continue
    
    local username password
    username=$(config_get_registry_username "$registry")
    password=$(config_get_registry_password "$registry")
    
    if [[ -z "$username" || -z "$password" ]]; then
      echo "  [!] Skipping ${registry}: missing username or password"
      continue
    fi
    
    # Check if already logged in
    local already_logged_in
    already_logged_in=$(pct exec "${CTID}" -- sh -c "cat ~/.docker/config.json 2>/dev/null | grep -q '${registry}' && echo 'yes' || echo 'no'")
    
    if [[ "$already_logged_in" == "yes" ]]; then
      echo "  ${registry}: already authenticated"
    else
      echo "  ${registry}: logging in..."
    fi
    
    # Always re-authenticate to ensure token is valid
    pct exec "${CTID}" -- sh -c "echo '${password}' | docker login '${registry}' -u '${username}' --password-stdin >/dev/null 2>&1"
    
    count=$((count + 1))
  done <<< "$registries"
  
  echo "  [✓] ${count} container registry(s) configured"
}

# Start Docker Compose services in a CT
# Updates .env with newt configuration from commonCT.json
# Enables 'published' profile if newt credentials are configured
# Args:
#   $1 - CTID (optional, defaults to global CTID)
# Returns: exit code from docker compose
compose_up() {
  local ctid="${1:-${CTID}}"
  
  # Get hostname for this CT
  local hostname
  hostname=$(pct config "$ctid" 2>/dev/null | awk -F': ' '/^hostname:/ {print $2}')
  
  # Get newt configuration
  local newt_id newt_secret newt_endpoint
  newt_id=$(config_get_newt_id "$hostname")
  newt_secret=$(config_get_newt_secret "$hostname")
  newt_endpoint=$(config_get_newt_endpoint "$hostname")
  
  # Update .env file with newt values
  local hostname_lower
  hostname_lower=$(echo "$hostname" | tr '[:upper:]' '[:lower:]')
  local env_file="/mnt/docker/${hostname_lower}/.env"
  
  if [[ -f "$env_file" ]]; then
    # Update or add NEWT values
    if grep -q "^NEWT_ID=" "$env_file"; then
      sed -i "s|^NEWT_ID=.*|NEWT_ID=${newt_id}|" "$env_file"
    else
      echo "NEWT_ID=${newt_id}" >> "$env_file"
    fi
    
    if grep -q "^NEWT_SECRET=" "$env_file"; then
      sed -i "s|^NEWT_SECRET=.*|NEWT_SECRET=${newt_secret}|" "$env_file"
    else
      echo "NEWT_SECRET=${newt_secret}" >> "$env_file"
    fi
    
    if grep -q "^NEWT_ENDPOINT=" "$env_file"; then
      sed -i "s|^NEWT_ENDPOINT=.*|NEWT_ENDPOINT=${newt_endpoint}|" "$env_file"
    else
      echo "NEWT_ENDPOINT=${newt_endpoint}" >> "$env_file"
    fi
  fi
  
  # Build compose command with optional published profile
  local profile_flag=""
  if [[ -n "$newt_id" && -n "$newt_secret" && -n "$newt_endpoint" ]]; then
    profile_flag="--profile published"
    echo "  Newt tunnel enabled (published profile)"
  fi
  
  pct exec "${ctid}" -- sh -c "cd /mnt/docker && docker compose ${profile_flag} up -d --pull always --remove-orphans"
}

# Stop Docker Compose services in a CT
# Automatically includes all defined profiles to ensure all services are stopped
# Args:
#   $1 - CTID (optional, defaults to global CTID)
# Returns: exit code from docker compose
compose_down() {
  local ctid="${1:-${CTID}}"
  
  # Get all profiles defined in the compose file and build --profile flags
  local profile_flags
  profile_flags=$(pct exec "${ctid}" -- sh -c 'cd /mnt/docker && docker compose config --profiles 2>/dev/null' | \
    while read -r profile; do echo -n "--profile $profile "; done)
  
  pct exec "${ctid}" -- sh -c "cd /mnt/docker && docker compose ${profile_flags} down"
}

# Reboot a container
# Waits for container to come back up and become responsive
# Args:
#   $1 - CTID (optional, defaults to global CTID)
reboot_ct() {
  local ctid="${1:-${CTID}}"
  
  echo "Rebooting CT ${ctid}..."
  pct reboot "${ctid}"
  
  # Wait for CT status to be running
  echo "  Waiting for CT to start..."
  local timeout=30
  local running=false
  for ((i=1; i<=timeout; i++)); do
    if pct status "${ctid}" 2>/dev/null | grep -q "status: running"; then
      running=true
      break
    fi
    sleep 1
  done
  
  if [[ "$running" != "true" ]]; then
    echo "  [!] Warning: CT ${ctid} did not start within ${timeout}s"
    return 1
  fi
  
  # Wait for CT to become responsive (can execute commands)
  echo "  Waiting for CT to become responsive..."
  local responsive=false
  for ((i=1; i<=timeout; i++)); do
    if pct exec "${ctid}" -- true 2>/dev/null; then
      responsive=true
      break
    fi
    sleep 1
  done
  
  if [[ "$responsive" != "true" ]]; then
    echo "  [!] Warning: CT ${ctid} not responsive within ${timeout}s"
    return 1
  fi
  
  echo "  [✓] CT ${ctid} is running and responsive"
  return 0
}

# Check if DNS resolves hostname to the same IP as the CT reports
# Args:
#   $1 - CTID (optional, defaults to global CTID)
#   $2 - hostname (optional, defaults to global CT_HOSTNAME)
# Returns: 0 if DNS matches, 1 if mismatch or error
check_dns_health() {
  local ctid="${1:-${CTID}}"
  local hostname="${2:-${CT_HOSTNAME}}"
  
  echo "Checking DNS health for ${hostname}..."
  
  # Get IP from inside the CT using ip command (most reliable)
  local ct_ip
  ct_ip=$(pct exec "${ctid}" -- sh -c "ip -4 addr show eth0 2>/dev/null | awk '/inet / {split(\$2, a, \"/\"); print a[1]}'" 2>/dev/null)
  
  if [[ -z "$ct_ip" ]]; then
    echo "  [!] Could not get IP from CT ${ctid}"
    return 1
  fi
  
  echo "  CT reports IP: ${ct_ip}"
  
  # Resolve hostname via DNS from host
  local dns_ip
  dns_ip=$(getent hosts "${hostname}" 2>/dev/null | awk '{print $1}')
  
  if [[ -z "$dns_ip" ]]; then
    echo "  [!] DNS lookup failed for ${hostname}"
    return 1
  fi
  
  echo "  DNS resolves to: ${dns_ip}"
  
  # Compare
  if [[ "$ct_ip" == "$dns_ip" ]]; then
    echo "  [✓] DNS matches CT IP"
    return 0
  else
    echo "  [!] DNS mismatch: CT=${ct_ip}, DNS=${dns_ip}"
    
    # Diagnostic: check if stale DNS IP is reachable
    echo "  Diagnosing stale IP ${dns_ip}..."
    
    if ping -c 1 -W 1 "${dns_ip}" >/dev/null 2>&1; then
      echo "    ${dns_ip} responds to ping - another device has this IP"
      
      # Check ARP cache for MAC address
      local arp_mac
      arp_mac=$(arp -n "${dns_ip}" 2>/dev/null | awk 'NR==2 {print $3}')
      if [[ -n "$arp_mac" && "$arp_mac" != "(incomplete)" ]]; then
        echo "    MAC at ${dns_ip}: ${arp_mac}"
        
        # Try to identify if it's one of our CTs
        local matching_ct=""
        for id in $(pct list 2>/dev/null | awk 'NR>1 {print $1}'); do
          local ct_mac
          ct_mac=$(pct config "$id" 2>/dev/null | grep -oP 'hwaddr=\K[^,]+' | tr '[:upper:]' '[:lower:]')
          if [[ "${ct_mac}" == "${arp_mac,,}" ]]; then
            matching_ct="$id ($(pct config "$id" 2>/dev/null | awk -F': ' '/^hostname:/ {print $2}'))"
            break
          fi
        done
        
        if [[ -n "$matching_ct" ]]; then
          echo "    Belongs to CT: ${matching_ct}"
        else
          echo "    MAC not found in CTs - external device or VM"
        fi
      fi
    else
      echo "    ${dns_ip} not responding - stale DNS record"
    fi
    
    echo "  Action: Update DHCP reservation or DNS record for ${hostname}"
    return 1
  fi
}

# -----------------------------
# CONTAINER FUNCTIONS
# -----------------------------

# Build list of all containers
# Populates CT_MAP (CTID -> hostname) and CT_LIST (array of CTIDs)
build_ct_list() {
  CT_MAP=()
  CT_LIST=()
  
  while IFS= read -r line; do
    local id
    id=$(echo "$line" | awk '{print $1}')
    [[ "$id" =~ ^[0-9]+$ ]] || continue
    
    local ct_hostname
    ct_hostname=$(pct config "$id" 2>/dev/null | awk -F': ' '/^hostname:/ {print $2}')
    CT_MAP["$id"]="$ct_hostname"
    CT_LIST+=("$id")
  done < <(pct list)
}

# Display interactive single-select container menu using whiptail
# Args: $1 = action verb (e.g., "delete", "refresh", "select")
# Sets: CTID, CT_HOSTNAME
# Returns: 0 on success, 1 on failure/cancel
select_ct_interactive_single() {
  local action="${1:-select}"
  
  if [[ ${#CT_LIST[@]} -eq 0 ]]; then
    echo "No containers found."
    return 1
  fi
  
  # Build whiptail menu arguments
  local menu_args=()
  for id in "${CT_LIST[@]}"; do
    local status hostname
    status=$(pct status "$id" 2>/dev/null | awk '{print $2}')
    hostname="${CT_MAP[$id]}"
    # Format: "CTID" "hostname [status]"
    menu_args+=("$id" "${hostname} [${status}]")
  done
  
  # Calculate dialog dimensions
  local height=$((${#CT_LIST[@]} + 8))
  [[ $height -gt 20 ]] && height=20
  local width=60
  local list_height=$((height - 6))
  
  # Show whiptail menu and capture selection
  local selection
  selection=$(whiptail --title "Container Selection" \
    --menu "Select container to ${action}:" \
    "$height" "$width" "$list_height" \
    "${menu_args[@]}" \
    3>&1 1>&2 2>&3) || return 1
  
  if [[ -z "$selection" ]]; then
    echo "No container selected."
    return 1
  fi
  
  CTID="$selection"
  CT_HOSTNAME="${CT_MAP[$CTID]}"
  return 0
}

# Display interactive multi-select container menu using whiptail
# Args: $1 = action verb (e.g., "delete", "refresh", "select")
# Sets: SELECTED_CTS (array of CTIDs)
# Returns: 0 on success, 1 on failure/cancel
select_ct_interactive_multi() {
  local action="${1:-select}"
  
  if [[ ${#CT_LIST[@]} -eq 0 ]]; then
    echo "No containers found."
    return 1
  fi
  
  # Build whiptail checklist arguments
  local checklist_args=()
  for id in "${CT_LIST[@]}"; do
    local status hostname
    status=$(pct status "$id" 2>/dev/null | awk '{print $2}')
    hostname="${CT_MAP[$id]}"
    # Format: "CTID" "hostname [status]" "OFF"
    checklist_args+=("$id" "${hostname} [${status}]" "OFF")
  done
  
  # Calculate dialog dimensions
  local height=$((${#CT_LIST[@]} + 8))
  [[ $height -gt 20 ]] && height=20
  local width=60
  local list_height=$((height - 6))
  
  # Show whiptail checklist with --separate-output for easier parsing
  local selections
  selections=$(whiptail --title "Container Selection" \
    --separate-output \
    --checklist "Select container(s) to ${action} (SPACE to toggle, ENTER to confirm):" \
    "$height" "$width" "$list_height" \
    "${checklist_args[@]}" \
    3>&1 1>&2 2>&3)
  
  local exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    echo "Selection cancelled."
    return 1
  fi
  
  # Parse selections into array (--separate-output gives one item per line)
  SELECTED_CTS=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && SELECTED_CTS+=("$line")
  done <<< "$selections"

  if [[ ${#SELECTED_CTS[@]} -eq 0 ]]; then
    echo "No containers selected."
    return 1
  fi
  
  return 0
}

# Resolve container from CTID or hostname argument
# Args: $1 = CTID or hostname
# Sets: CTID, CT_HOSTNAME
# Returns: 0 on success, 1 on failure
resolve_ct_from_input() {
  local input="$1"
  
  if [[ -z "$input" ]]; then
    echo "ERROR: No CTID or hostname provided."
    return 1
  fi
  
  if [[ "$input" =~ ^[0-9]+$ ]]; then
    # Input is a CTID
    CTID="$input"
    if [[ -z "${CT_MAP[$CTID]:-}" ]]; then
      echo "ERROR: CT ${CTID} does not exist."
      return 1
    fi
    CT_HOSTNAME="${CT_MAP[$CTID]}"
  else
    # Input is a hostname
    CT_HOSTNAME="$input"
    CTID=""
    for id in "${CT_LIST[@]}"; do
      if [[ "${CT_MAP[$id]}" == "$CT_HOSTNAME" ]]; then
        CTID="$id"
        break
      fi
    done
    
    if [[ -z "$CTID" ]]; then
      echo "ERROR: No CT found with hostname '${CT_HOSTNAME}'."
      return 1
    fi
  fi
  
  return 0
}

# Get container status
# Args: $1 = CTID (optional, defaults to $CTID)
# Returns: status string (running, stopped, etc.)
get_ct_status() {
  local ctid="${1:-$CTID}"
  pct status "$ctid" 2>/dev/null | awk '{print $2}'
}

# Ensure container is running (starts it if stopped)
# Args: $1 = CTID (optional, defaults to $CTID)
# Returns: 0 if running/started, 1 on failure
ensure_ct_running() {
  local ctid="${1:-$CTID}"
  local status
  status=$(get_ct_status "$ctid")
  
  if [[ "$status" == "running" ]]; then
    return 0
  fi
  
  if [[ "$status" == "stopped" ]]; then
    echo "CT ${ctid} is stopped, starting it..."
    pct start "$ctid"
    sleep 3
    
    # Verify it started
    status=$(get_ct_status "$ctid")
    if [[ "$status" != "running" ]]; then
      echo "ERROR: Failed to start CT ${ctid}."
      return 1
    fi
    echo "  [✓] CT ${ctid} started"
    return 0
  fi
  
  echo "ERROR: CT ${ctid} is in unexpected state (status: ${status})."
  return 1
}

# Ensure container is stopped
# Args: $1 = CTID (optional, defaults to $CTID)
# Returns: 0 if stopped, 1 if not
ensure_ct_stopped() {
  local ctid="${1:-$CTID}"
  local status
  status=$(get_ct_status "$ctid")
  
  if [[ "$status" != "stopped" ]]; then
    echo "ERROR: CT ${ctid} is not stopped (status: ${status})."
    echo "Stop it first with: pct stop ${ctid}"
    return 1
  fi
  return 0
}

# Execute command in container
# Args: $1 = CTID (optional if $CTID is set), remaining args = command
# Usage: ct_exec "command" or ct_exec 2100 "command"
ct_exec() {
  local ctid
  local cmd
  
  if [[ "$1" =~ ^[0-9]+$ ]] && [[ $# -gt 1 ]]; then
    ctid="$1"
    shift
    cmd="$*"
  else
    ctid="$CTID"
    cmd="$*"
  fi
  
  pct exec "$ctid" -- sh -c "$cmd"
}

# Check if container exists
# Args: $1 = CTID
# Returns: 0 if exists, 1 if not
ct_exists() {
  local ctid="$1"
  pct status "$ctid" &>/dev/null
}

# Get hostname-based directory paths
# Args: $1 = hostname (optional, defaults to $CT_HOSTNAME)
# Sets: DIR_DOCKER, DIR_DOCKER_DATA
get_ct_dirs() {
  local hostname="${1:-$CT_HOSTNAME}"
  local hostname_lower
  hostname_lower=$(echo "$hostname" | tr '[:upper:]' '[:lower:]')
  
  DIR_DOCKER="/mnt/docker/${hostname_lower}"
  DIR_DOCKER_DATA="/mnt/docker-data/${hostname_lower}"
}
