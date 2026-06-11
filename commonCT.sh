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
#   ensure_swap            Ensure swap is half of memory
#   compose_up             Start Docker Compose services in CT
#   compose_down           Stop Docker Compose services in CT
#   extract_domain_from_hostname  Extract domain from hostname
#   resolve_dns_with_retry Resolve DNS with retry loop (sets DNS_RESOLVED_IP)
#   check_dns_health       Check and auto-fix DNS via UDM Pro API
#
# CONFIG FUNCTIONS (read from commonCT.json):
#   config_exists          Check if config file exists
#   config_get_domains     Get list of configured domains
#   config_domain_exists   Check if domain is configured
#   config_get_fingerprint Get SSL fingerprint for domain
#   config_get_email       Get email for domain
#   config_get_ca_name     Get CA name for domain
#   config_get_compose_template  Get compose template path for domain
#   config_size_exists     Check if size is defined
#   config_get_sizes       Get list of available sizes
#   config_get_size_cores  Get cores for size
#   config_get_size_memory Get memory for size
#   validate_size          Validate size and set SIZE_CORES/SIZE_MEMORY
#   validate_priority      Validate priority and set PRIORITY_CPUUNITS
#   validate_hostname      Validate hostname format and domain config
#   config_get_newt_id     Get newt ID for hostname
#   config_get_newt_secret Get newt secret for hostname
#   config_get_newt_endpoint Get newt endpoint (global or per-site)
#   config_get_registries  Get list of configured container registries
#   config_get_registry_username Get username for registry
#   config_get_registry_password Get password for registry
#   config_get_udmpro_host Get UDM Pro host address
#   config_get_udmpro_apikey Get UDM Pro API key
#   config_udmpro_configured Check if UDM Pro is configured
#   udmpro_make_static    Set static IP and local DNS on UDM Pro client
#
# PROVIDED VARIABLES:
#   SCRIPT_DIR             Directory containing the calling script
#   CONFIG_FILE            Path to commonCT.json
#   CT_MAP                 Associative array: CTID -> hostname
#   CT_STATUS              Associative array: CTID -> status (running/stopped)
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
declare -A CT_STATUS
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
  jq -r '.domains[]' "${CONFIG_FILE}"
}

# Check if domain is configured
# Args: $1 = domain name
# Returns: 0 if configured, 1 if not
config_domain_exists() {
  local domain="$1"
  if ! config_exists; then
    return 1
  fi
  jq -e --arg d "$domain" '.domains | index($d)' "${CONFIG_FILE}" >/dev/null 2>&1
}

# Get SSL fingerprint for domain
# Args: $1 = domain name
# Returns: fingerprint string (or empty if not found)
config_get_fingerprint() {
  local domain="$1"
  if ! config_exists; then
    return 1
  fi
  jq -r --arg d "$domain" '.ssl[$d].fingerprint // empty' "${CONFIG_FILE}"
}

# Get email for domain
# Args: $1 = domain name
# Returns: email string (or empty if not found)
config_get_email() {
  local domain="$1"
  if ! config_exists; then
    return 1
  fi
  jq -r --arg d "$domain" '.ssl[$d].email // empty' "${CONFIG_FILE}"
}

# Get CA name for domain
# Args: $1 = domain name
# Returns: ca.<domain>
config_get_ca_name() {
  local domain="$1"
  echo "ca.${domain}"
}

# Get compose template path for domain
# Args: $1 = domain name (e.g., thesaints.home)
# Returns: path to compose template file (or error if not found)
config_get_compose_template() {
  local domain="$1"
  local template="${SCRIPT_DIR}/compose/${domain}.yaml"
  if [[ ! -f "$template" ]]; then
    echo "ERROR: Compose template not found: ${template}" >&2
    return 1
  fi
  echo "$template"
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

# Validate priority and return CPU units value
# Args: $1 = priority name (low, mid, high)
# Sets: PRIORITY_CPUUNITS (global)
# Returns: 0 if valid, 1 if invalid (with error message)
validate_priority() {
  local priority="${1:-mid}"
  
  case "${priority,,}" in
    low)  PRIORITY_CPUUNITS=512 ;;
    mid)  PRIORITY_CPUUNITS=1024 ;;
    high) PRIORITY_CPUUNITS=2048 ;;
    *)
      echo "ERROR: Invalid priority '${priority}'. Use: low, mid, high"
      return 1
      ;;
  esac
  
  return 0
}

# Validate hostname against config
# Args: $1 = hostname (e.g., app.thesaints.home)
# Returns: 0 if valid, 1 if invalid (with error message)
# Validation rules:
#   - CA hosts (ca.*): must be fully qualified (at least 3 parts: ca.domain.tld)
#   - Regular hosts: domain must exist in commonCT.json
validate_hostname() {
  local hostname="$1"
  
  if [[ -z "$hostname" ]]; then
    echo "ERROR: No hostname provided"
    return 1
  fi
  
  if ! config_exists; then
    echo "ERROR: Config file not found: ${CONFIG_FILE}"
    return 1
  fi

  local hostname_parts
  hostname_parts=$(echo "${hostname}" | tr '.' '\n' | wc -l)

  if [[ "${hostname}" =~ ^ca\. ]]; then
    # CA host: must be fully qualified (at least 3 parts: ca.domain.tld)
    if [[ ${hostname_parts} -lt 3 ]]; then
      echo "ERROR: CA hostname must be fully qualified (e.g., ca.domain.tld)"
      echo "  Provided: ${hostname}"
      return 1
    fi
    echo "Hostname validated: CA host"
  else
    # Regular host: domain must be in config
    local domain
    domain=$(extract_domain_from_hostname "${hostname}")
    
    if ! config_domain_exists "${domain}"; then
      echo "ERROR: Domain '${domain}' not configured in ${CONFIG_FILE}"
      echo "  Configured domains:"
      config_get_domains | sed 's/^/    /'
      return 1
    fi
    echo "Hostname validated: domain '${domain}' found in config"
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

# -----------------------------
# UDM PRO CONFIGURATION FUNCTIONS
# -----------------------------

# Get UDM Pro host
# Returns: host address or empty
config_get_udmpro_host() {
  if ! config_exists; then
    return 1
  fi
  jq -r '.udmpro.host // empty' "${CONFIG_FILE}" 2>/dev/null
}

# Get UDM Pro API key
# Returns: API key or empty
config_get_udmpro_apikey() {
  if ! config_exists; then
    return 1
  fi
  jq -r '.udmpro.apikey // empty' "${CONFIG_FILE}" 2>/dev/null
}

# Check if UDM Pro is configured
# Returns: 0 if configured (host and apikey set), 1 if not
config_udmpro_configured() {
  local host apikey
  host=$(config_get_udmpro_host)
  apikey=$(config_get_udmpro_apikey)
  [[ -n "$host" && -n "$apikey" ]]
}

# -----------------------------
# AUTHENTIK CONFIGURATION FUNCTIONS
# -----------------------------

# Get Authentik host
# Returns: host address or empty
config_get_authentik_host() {
  if ! config_exists; then
    return 1
  fi
  jq -r '.authentik.host // empty' "${CONFIG_FILE}" 2>/dev/null
}

# Get Authentik API token
# Returns: API token or empty
config_get_authentik_token() {
  if ! config_exists; then
    return 1
  fi
  jq -r '.authentik.apitoken // empty' "${CONFIG_FILE}" 2>/dev/null
}

# Get Authentik outpost name
# Returns: outpost name or empty
config_get_authentik_outpost() {
  if ! config_exists; then
    return 1
  fi
  jq -r '.authentik.outpost_name // empty' "${CONFIG_FILE}" 2>/dev/null
}

# Get Authentik authorization flow slug
# Returns: flow slug or empty
config_get_authentik_authorization_flow() {
  if ! config_exists; then
    return 1
  fi
  jq -r '.authentik.authorization_flow_slug // empty' "${CONFIG_FILE}" 2>/dev/null
}

# Get Authentik invalidation flow slug
# Returns: flow slug or empty
config_get_authentik_invalidation_flow() {
  if ! config_exists; then
    return 1
  fi
  jq -r '.authentik.invalidation_flow_slug // empty' "${CONFIG_FILE}" 2>/dev/null
}

# Check if Authentik is configured
# Returns: 0 if configured (host and apitoken set), 1 if not
config_authentik_configured() {
  local host token
  host=$(config_get_authentik_host)
  token=$(config_get_authentik_token)
  [[ -n "$host" && -n "$token" ]]
}

# Set static IP and local DNS record on UDM Pro client
# Finds client by MAC address and configures fixed IP + local DNS name
#
# Args:
#   $1 - CT MAC address
#   $2 - CT IP address
#   $3 - CT hostname (FQDN for local DNS record)
# Returns: 0 on success, 1 on error (client not found or API failure)
udmpro_make_static() {
  local ct_mac="$1"
  local ct_ip="$2"
  local ct_hostname="$3"
  
  if ! config_udmpro_configured; then
    echo "  [!] UDM Pro not configured"
    return 1
  fi
  
  local udm_host udm_apikey
  udm_host=$(config_get_udmpro_host)
  udm_apikey=$(config_get_udmpro_apikey)
  
  echo "  Looking up client in UDM Pro..."
  
  # Normalize MAC for comparison (lowercase)
  local ct_mac_normalized="${ct_mac,,}"
  
  # Get all known clients
  local all_clients
  all_clients=$(curl -sk -H "X-API-KEY: ${udm_apikey}" \
    "https://${udm_host}/proxy/network/api/s/default/rest/user" 2>/dev/null || true)
  
  if [[ -z "$all_clients" ]] || ! echo "$all_clients" | jq -e '.data' >/dev/null 2>&1; then
    echo "  [!] Failed to query UDM Pro API"
    return 1
  fi
  
  # Find client by MAC
  local client_id
  client_id=$(echo "$all_clients" | jq -r --arg mac "$ct_mac_normalized" \
    '.data[] | select((.mac | ascii_downcase) == $mac) | ._id' 2>/dev/null | head -1 || true)
  
  if [[ -z "$client_id" || "$client_id" == "null" ]]; then
    echo "  [!] Client with MAC ${ct_mac} not found in UDM Pro"
    return 1
  fi
  
  # Clear conflicting DNS record from other clients (e.g., stale entries after CT recreation)
  local conflicting_ids
  conflicting_ids=$(echo "$all_clients" | jq -r --arg dns "$ct_hostname" --arg self "$client_id" \
    '.data[] | select(.local_dns_record == $dns and .local_dns_record_enabled == true and ._id != $self) | ._id' 2>/dev/null || true)
  
  if [[ -n "$conflicting_ids" ]]; then
    while IFS= read -r stale_id; do
      [[ -z "$stale_id" ]] && continue
      local stale_mac
      stale_mac=$(echo "$all_clients" | jq -r --arg id "$stale_id" '.data[] | select(._id == $id) | .mac' 2>/dev/null || true)
      echo "    Clearing stale DNS record from client ${stale_id} (MAC: ${stale_mac})"
      curl -sk -X PUT -H "X-API-KEY: ${udm_apikey}" -H "Content-Type: application/json" \
        "https://${udm_host}/proxy/network/api/s/default/rest/user/${stale_id}" \
        -d '{"local_dns_record_enabled": false, "local_dns_record": ""}' >/dev/null 2>&1 || true
    done <<< "$conflicting_ids"
  fi
  
  echo "    Client ID: ${client_id}"
  echo "    Setting static IP: ${ct_ip}"
  echo "    Setting local DNS: ${ct_hostname}"
  echo "    Setting alias: ${ct_hostname}"
  
  # Update client with fixed IP, local DNS record, and alias name
  local update_payload
  update_payload=$(jq -n \
    --arg ip "$ct_ip" \
    --arg dns "$ct_hostname" \
    --arg name "$ct_hostname" \
    '{
      use_fixedip: true,
      fixed_ip: $ip,
      local_dns_record_enabled: true,
      local_dns_record: $dns,
      name: $name
    }')
  
  local update_result
  update_result=$(curl -sk -X PUT -H "X-API-KEY: ${udm_apikey}" -H "Content-Type: application/json" \
    "https://${udm_host}/proxy/network/api/s/default/rest/user/${client_id}" \
    -d "$update_payload" 2>/dev/null || true)
  
  if echo "$update_result" | jq -e '.meta.rc == "ok"' >/dev/null 2>&1; then
    echo "  [✓] UDM Pro client configured"
    return 0
  else
    local error_msg
    error_msg=$(echo "$update_result" | jq -r '.meta.msg // "unknown error"' 2>/dev/null || echo "unknown error")
    echo "  [!] Failed to update client: ${error_msg}"
    return 1
  fi
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
  tzdata_installed=$(ct_exec --timeout 15 'apk info -e tzdata >/dev/null 2>&1 && echo "yes" || echo "no"')
  
  if [[ "$tzdata_installed" != "yes" ]]; then
    echo "  Installing tzdata..."
    ct_exec --timeout 120 'apk add --no-cache tzdata >/dev/null'
  else
    echo "  tzdata already installed"
  fi
  
  # Fix /etc/localtime
  ct_exec --timeout 15 "
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

  ct_exec --timeout 15 "
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
  telegraf_installed=$(ct_exec --timeout 15 'command -v telegraf >/dev/null 2>&1 && echo "yes" || echo "no"')
  
  if [[ "$telegraf_installed" != "yes" ]]; then
    echo "  Installing telegraf..."
    ct_exec --timeout 120 'apk add --no-cache telegraf'
  else
    echo "  Telegraf already installed"
  fi

  # Ensure telegraf user can access docker socket
  local in_docker_group
  in_docker_group=$(ct_exec --timeout 15 'groups telegraf 2>/dev/null | grep -q docker && echo "yes" || echo "no"')
  if [[ "$in_docker_group" != "yes" ]]; then
    echo "  Adding telegraf user to docker group..."
    ct_exec --timeout 15 'adduser telegraf docker 2>/dev/null || true'
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
  ct_exec --timeout 30 "
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
  service_status=$(ct_exec --timeout 15 'rc-service telegraf status 2>&1 || true')
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
  ct_exec --timeout 30 "
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
      # Restart syslog service (backgrounded to avoid blocking on DNS resolution)
      service syslog restart >/dev/null 2>&1 &
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
  step_installed=$(ct_exec --timeout 15 'command -v step >/dev/null 2>&1 && echo "yes" || echo "no"')
  
  if [[ "$step_installed" != "yes" ]]; then
    echo "  Installing step-cli..."
    ct_exec --timeout 120 'apk add --no-cache step-cli >/dev/null'
  else
    echo "  step-cli already installed"
  fi

  # Bootstrap CA trust (--force makes it idempotent)
  echo "  Bootstrapping CA trust..."
  if ! ct_exec --timeout 60 "step ca bootstrap \
    --ca-url 'https://${ca_name}' \
    --fingerprint '${fingerprint}' \
    --install --force" 2>&1; then
    echo "  [!] Warning: step ca bootstrap failed (CA may be unreachable)"
    return 0  # Non-fatal - continue with refresh
  fi

  # Install root CA to system trust store (for Docker containers)
  echo "  Installing root CA to system trust store..."
  if ct_exec --timeout 30 "cp /root/.step/certs/root_ca.crt /usr/local/share/ca-certificates/step-ca-root.crt && update-ca-certificates" >/dev/null 2>&1; then
    echo "  [✓] Root CA added to system trust store"
  else
    echo "  [!] Warning: Failed to add root CA to system trust store"
  fi
  
  echo "  [✓] Step CA trust configured"
}

# Configure a scheduled arping on the default gateway every minute
# Ensures the CT remains reachable by refreshing the ARP table on the gateway
# Idempotent: overwrites cron entry or unit files (safe to run repeatedly)
# Supports both OpenRC (Alpine/crond) and systemd (Debian/RHEL)
# Args:
#   $1 - hostname (optional, defaults to CT_HOSTNAME or HOSTNAME)
# Requires: CTID to be set
configure_arping_service() {
  local ct_hostname="${1:-${CT_HOSTNAME:-${HOSTNAME}}}"
  local arping_cmd='GW=$(ip route | awk '"'"'/default/ {print $3}'"'"'); [ -n "$GW" ] && arping -c 1 -A -I eth0 $GW >/dev/null 2>&1 || true'

  echo "Configuring arping gateway service..."

  # Ensure arping is installed
  local has_arping
  has_arping=$(ct_exec --timeout 15 'command -v arping >/dev/null 2>&1 && echo yes || echo no')
  if [[ "$has_arping" != "yes" ]]; then
    echo "  Installing arping..."
    ct_exec --timeout 120 '
      if command -v apk >/dev/null 2>&1; then
        apk add --no-cache iputils >/dev/null
      elif command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq && apt-get install -y -qq iputils-arping >/dev/null
      elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q iputils >/dev/null
      else
        echo "  [!] Unknown package manager, cannot install arping" >&2
        exit 1
      fi
    '
  else
    echo "  arping already installed"
  fi

  # Detect init system and configure accordingly
  if ct_exec --timeout 15 '[ -d /run/systemd/system ]' 2>/dev/null; then
    # systemd: use a timer unit
    echo "  Using systemd timer..."

    ct_exec --timeout 15 'cat > /etc/systemd/system/arping-gateway.service << "UNIT"
[Unit]
Description=ARP announce on default gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c '"'"'GW=$(ip route | awk "/default/ {print \\$3}"); [ -n "$GW" ] && arping -c 1 -A -I eth0 $GW || true'"'"'
UNIT'

    ct_exec --timeout 15 'cat > /etc/systemd/system/arping-gateway.timer << "UNIT"
[Unit]
Description=ARP announce on default gateway every minute

[Timer]
OnBootSec=0
OnUnitActiveSec=60

[Install]
WantedBy=timers.target
UNIT'

    ct_exec --timeout 30 '
      systemctl daemon-reload
      systemctl enable --now arping-gateway.timer >/dev/null 2>&1
    '
  else
    # OpenRC/crond: use a cron job
    echo "  Using crond..."

    # Ensure crond is enabled and running
    ct_exec --timeout 30 '
      if command -v rc-update >/dev/null 2>&1; then
        rc-update add crond default 2>/dev/null || true
        service crond start 2>/dev/null || true
      fi
    '

    # Write arping script and cron entry idempotently
    # Uses a wrapper script to avoid awk/dollar-sign quoting issues in ct_exec
    pct exec "${CTID}" -- sh -c 'cat > /usr/local/bin/arping-gw.sh << '"'"'SCRIPT'"'"'
#!/bin/sh
GW=$(ip route | awk '"'"'"'"'"'"'"'"'/default/ {print $3}'"'"'"'"'"'"'"'"')
[ -n "$GW" ] && arping -c 1 -A -I eth0 $GW >/dev/null 2>&1 || true
SCRIPT
chmod +x /usr/local/bin/arping-gw.sh
sed -i "/arping/d" /etc/crontabs/root
echo "* * * * * /usr/local/bin/arping-gw.sh" >> /etc/crontabs/root'
  fi

  echo "  [✓] Arping gateway service configured"
}

# Configure Authentik forward auth for a CT
# Detects caddy.forward_auth labels in the CT's docker-compose.yaml and
# auto-provisions a domain-level forward auth setup in Authentik via REST API:
#   1. Proxy Provider (mode: forward_domain, one per domain)
#   2. Application (linked to the provider)
#   3. Outpost assignment (adds provider to the configured outpost)
# Domain-level: one provider covers all services under the same parent domain.
# Individual apps handle their own authorization; Authentik only authenticates.
# Idempotent: skips if domain application already exists with a provider attached
# Args:
#   $1 - CT hostname (e.g., rust.thesaints.home)
# Returns: 0 on success or skip, 1 on error
configure_authentik_forward_auth() {
  local ct_hostname="${1:-${CT_HOSTNAME:-${HOSTNAME}}}"

  # Check if Authentik is configured
  if ! config_authentik_configured; then
    echo "  [!] Authentik not configured (missing host or apitoken in commonCT.json)"
    return 0
  fi

  # Check if docker-compose.yaml has forward_auth labels
  local hostname_lower
  hostname_lower=$(echo "$ct_hostname" | tr '[:upper:]' '[:lower:]')
  local compose_file="/mnt/docker/${hostname_lower}/docker-compose.yaml"

  if [[ ! -f "$compose_file" ]]; then
    return 0
  fi

  if ! grep -q 'caddy\.forward_auth' "$compose_file" 2>/dev/null; then
    return 0
  fi

  echo "Configuring Authentik forward auth..."

  local ak_host ak_token ak_outpost auth_flow_slug inval_flow_slug
  ak_host=$(config_get_authentik_host)
  ak_token=$(config_get_authentik_token)
  ak_outpost=$(config_get_authentik_outpost)
  auth_flow_slug=$(config_get_authentik_authorization_flow)
  inval_flow_slug=$(config_get_authentik_invalidation_flow)

  local ak_api="https://${ak_host}/api/v3"

  # Domain-level: one provider per domain, not per hostname
  local domain
  domain=$(extract_domain_from_hostname "$ct_hostname")
  local slug
  slug=$(echo "$domain" | tr '.' '-')

  # Helper: Authentik API GET
  ak_get() {
    curl -sk -H "Authorization: Bearer ${ak_token}" -H "Accept: application/json" \
      "${ak_api}${1}" 2>/dev/null
  }

  # Helper: Authentik API POST
  ak_post() {
    curl -sk -X POST -H "Authorization: Bearer ${ak_token}" \
      -H "Content-Type: application/json" -H "Accept: application/json" \
      "${ak_api}${1}" -d "${2}" 2>/dev/null
  }

  # Helper: Authentik API PATCH
  ak_patch() {
    curl -sk -X PATCH -H "Authorization: Bearer ${ak_token}" \
      -H "Content-Type: application/json" -H "Accept: application/json" \
      "${ak_api}${1}" -d "${2}" 2>/dev/null
  }

  # Step 1: Check if domain application already exists with a provider
  local existing_app
  existing_app=$(ak_get "/core/applications/?slug=${slug}")

  if echo "$existing_app" | jq -e --arg s "$slug" '.results[] | select(.slug == $s) | .provider != null' >/dev/null 2>&1; then
    echo "  [✓] Authentik: domain '${domain}' already configured"
    return 0
  fi

  # Step 2: Look up flow UUIDs by slug
  echo "  Looking up authorization flow: ${auth_flow_slug}"
  local auth_flow_uuid
  auth_flow_uuid=$(ak_get "/flows/instances/?slug=${auth_flow_slug}" | \
    jq -r '.results[0].pk // empty' 2>/dev/null)

  if [[ -z "$auth_flow_uuid" ]]; then
    echo "  [!] Authorization flow '${auth_flow_slug}' not found in Authentik"
    return 1
  fi

  echo "  Looking up invalidation flow: ${inval_flow_slug}"
  local inval_flow_uuid
  inval_flow_uuid=$(ak_get "/flows/instances/?slug=${inval_flow_slug}" | \
    jq -r '.results[0].pk // empty' 2>/dev/null)

  if [[ -z "$inval_flow_uuid" ]]; then
    echo "  [!] Invalidation flow '${inval_flow_slug}' not found in Authentik"
    return 1
  fi

  # Step 3: Create domain-level Proxy Provider
  echo "  Creating domain-level proxy provider: ${domain}"
  local provider_payload
  provider_payload=$(jq -n \
    --arg name "${domain}" \
    --arg auth_flow "$auth_flow_uuid" \
    --arg inval_flow "$inval_flow_uuid" \
    --arg ext_host "https://${ak_host}" \
    --arg cookie_domain "$domain" \
    '{
      name: $name,
      authorization_flow: $auth_flow,
      invalidation_flow: $inval_flow,
      external_host: $ext_host,
      mode: "forward_domain",
      cookie_domain: $cookie_domain
    }')

  local provider_result
  provider_result=$(ak_post "/providers/proxy/" "$provider_payload")

  local provider_pk
  provider_pk=$(echo "$provider_result" | jq -r '.pk // empty' 2>/dev/null)

  if [[ -z "$provider_pk" ]]; then
    local error_detail
    error_detail=$(echo "$provider_result" | jq -r 'if .detail then .detail elif .name then .name[0] else "unknown error" end' 2>/dev/null || echo "unknown error")
    echo "  [!] Failed to create proxy provider: ${error_detail}"
    return 1
  fi
  echo "    Provider ID: ${provider_pk}"

  # Step 4: Create Application
  echo "  Creating application: ${slug}"
  local app_payload
  app_payload=$(jq -n \
    --arg name "${domain}" \
    --arg slug "$slug" \
    --argjson provider "$provider_pk" \
    --arg launch_url "https://${ak_host}" \
    '{
      name: $name,
      slug: $slug,
      provider: $provider,
      meta_launch_url: $launch_url
    }')

  local app_result
  app_result=$(ak_post "/core/applications/" "$app_payload")

  if ! echo "$app_result" | jq -e '.pk' >/dev/null 2>&1; then
    local error_detail
    error_detail=$(echo "$app_result" | jq -r 'if .detail then .detail elif .slug then .slug[0] else "unknown error" end' 2>/dev/null || echo "unknown error")
    echo "  [!] Failed to create application: ${error_detail}"
    return 1
  fi
  echo "    Application slug: ${slug}"

  # Step 5: Assign provider to outpost
  if [[ -n "$ak_outpost" ]]; then
    echo "  Assigning to outpost: ${ak_outpost}"

    local outpost_result
    outpost_result=$(ak_get "/outposts/instances/?name__iexact=$(printf '%s' "$ak_outpost" | jq -sRr @uri)")

    local outpost_uuid
    outpost_uuid=$(echo "$outpost_result" | jq -r '.results[0].pk // empty' 2>/dev/null)

    if [[ -z "$outpost_uuid" ]]; then
      echo "  [!] Outpost '${ak_outpost}' not found — provider created but not assigned to outpost"
      return 0
    fi

    # Get current providers list and append new provider
    local current_providers
    current_providers=$(echo "$outpost_result" | jq -r '[.results[0].providers[]]' 2>/dev/null)

    # Check if provider already assigned
    if echo "$current_providers" | jq -e --argjson pk "$provider_pk" 'index($pk) != null' >/dev/null 2>&1; then
      echo "    Provider already assigned to outpost"
    else
      local updated_providers
      updated_providers=$(echo "$current_providers" | jq --argjson pk "$provider_pk" '. + [$pk]')

      local patch_payload
      patch_payload=$(jq -n --argjson providers "$updated_providers" '{providers: $providers}')

      local patch_result
      patch_result=$(ak_patch "/outposts/instances/${outpost_uuid}/" "$patch_payload")

      if echo "$patch_result" | jq -e '.pk' >/dev/null 2>&1; then
        echo "    [✓] Provider assigned to outpost"
      else
        echo "    [!] Failed to assign provider to outpost"
      fi
    fi
  fi

  echo "  [✓] Authentik forward auth configured (domain: ${domain})"
  return 0
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
    ct_exec --timeout 15 "${ctid}" "
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
  ct_exec --timeout 15 "${ctid}" "
    addgroup -g ${render_gid} render 2>/dev/null || true
    addgroup root render 2>/dev/null || true
  "
  
  # Verify device is accessible
  if ct_exec --timeout 15 "${ctid}" 'test -e /dev/dri/renderD128' 2>/dev/null; then
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
    already_logged_in=$(ct_exec --timeout 15 "cat ~/.docker/config.json 2>/dev/null | grep -q '${registry}' && echo 'yes' || echo 'no'")
    
    if [[ "$already_logged_in" == "yes" ]]; then
      echo "  ${registry}: already authenticated"
      count=$((count + 1))
      continue
    fi
    
    # Authenticate
    echo "  ${registry}: logging in..."
    local login_output
    if ! login_output=$(ct_exec --timeout 60 "echo '${password}' | docker login '${registry}' -u '${username}' --password-stdin" 2>&1); then
      echo "  [!] ${registry}: login failed: ${login_output}"
      return 1
    fi
    
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
  
  ct_exec --timeout 300 "${ctid}" "cd /mnt/docker && docker compose ${profile_flag} up -d --pull always --remove-orphans"
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
  profile_flags=$(ct_exec --timeout 30 "${ctid}" 'cd /mnt/docker && docker compose config --profiles 2>/dev/null' | \
    while read -r profile; do echo -n "--profile $profile "; done)
  
  ct_exec --timeout 120 "${ctid}" "cd /mnt/docker && docker compose ${profile_flags} down"
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

# Resolve DNS with retry loop
# Attempts to resolve hostname via DNS, retrying for up to timeout seconds.
# If expected_ip is provided, only succeeds if resolved IP matches.
#
# Args:
#   $1 - hostname to resolve
#   $2 - expected IP (optional, if provided must match for success)
#   $3 - timeout in seconds (optional, default 60)
#   $4 - interval between retries (optional, default 5)
# Sets: DNS_RESOLVED_IP (global) - the resolved IP or empty
# Returns: 0 if resolved (and matches expected_ip if provided), 1 otherwise
resolve_dns_with_retry() {
  local hostname="$1"
  local expected_ip="${2:-}"
  local timeout="${3:-60}"
  local interval="${4:-5}"
  local quiet="${5:-false}"
  
  DNS_RESOLVED_IP=""
  
  for ((i=0; i<=timeout; i+=interval)); do
    # Use dig for pure DNS lookup (bypasses /etc/hosts)
    # +time=2 +tries=1 prevents dig from hanging on unresponsive DNS
    DNS_RESOLVED_IP=$(dig +short +time=2 +tries=1 "${hostname}" A 2>/dev/null | grep -E '^[0-9.]+$' | head -1 || true)
    
    if [[ -n "$DNS_RESOLVED_IP" ]]; then
      # End the line (caller used echo -n)
      [[ "$quiet" != "true" ]] && echo ""
      
      # If no expected IP, any resolution is success
      if [[ -z "$expected_ip" ]]; then
        return 0
      fi
      # If expected IP provided, check if it matches
      if [[ "$DNS_RESOLVED_IP" == "$expected_ip" ]]; then
        return 0
      fi
      # Resolved but to wrong IP - return immediately (no point retrying)
      return 1
    fi
    
    # Show progress dot for each retry
    [[ "$quiet" != "true" ]] && echo -n "."
    
    # Don't sleep on last iteration
    [[ $i -lt $timeout ]] && sleep "$interval"
  done
  
  # End the line (caller used echo -n)
  [[ "$quiet" != "true" ]] && echo ""
  
  # Never resolved
  return 1
}

# Check DNS configuration for a CT, configure static IP/DNS if needed
# 
# Flow:
#   Step 1: Get CT hostname, IP, and MAC address
#   Step 2: Resolve hostname via DNS
#     - DNS matches CT IP → SUCCESS
#     - DNS fails/mismatches → configure static IP and local DNS on UDM Pro
#
# Args:
#   $1 - CTID (optional, defaults to global CTID)
#   $2 - hostname (optional, defaults to global CT_HOSTNAME)
# Returns: 0 if DNS is healthy, 1 on error
check_dns_health() {
  local ctid="${1:-${CTID}}"
  local hostname="${2:-${CT_HOSTNAME}}"
  
  echo "Checking DNS health for ${hostname}..."
  
  # -------------------------
  # Get CT info
  # -------------------------
  local ct_ip ct_mac
  
  # Get IP from inside the CT (uses grep+tr+cut for BusyBox compatibility)
  ct_ip=$(ct_exec --timeout 15 "${ctid}" 'ip -4 addr show eth0 2>/dev/null | grep "inet " | tr -s " " | cut -d" " -f3 | cut -d"/" -f1' 2>/dev/null)
  if [[ -z "$ct_ip" ]]; then
    echo "  [!] Could not get IP from CT ${ctid}"
    return 1
  fi
  
  # Get MAC from CT config
  ct_mac=$(pct config "${ctid}" 2>/dev/null | grep -oP 'hwaddr=\K[^,]+' | tr '[:upper:]' '[:lower:]')
  if [[ -z "$ct_mac" ]]; then
    echo "  [!] Could not get MAC from CT ${ctid}"
    return 1
  fi
  
  echo "  CT IP:  ${ct_ip}"
  echo "  CT MAC: ${ct_mac}"
  
  # -------------------------
  # Ensure UDM Pro has fixed IP and local DNS record
  # Always run (idempotent) to ensure device properties are set
  # -------------------------
  udmpro_make_static "$ct_mac" "$ct_ip" "$hostname" || true
  
  # -------------------------
  # Check DNS
  # -------------------------
  echo -n "  Checking DNS resolution..."
  
  if resolve_dns_with_retry "$hostname" "$ct_ip"; then
    echo "  DNS IP: ${DNS_RESOLVED_IP}"
    echo "  [✓] DNS matches CT IP"
    return 0
  fi
  
  # DNS check failed - either wrong IP or not found
  if [[ -n "$DNS_RESOLVED_IP" ]]; then
    echo "  DNS IP: ${DNS_RESOLVED_IP}"
    echo "  [!] DNS mismatch: expected ${ct_ip}, got ${DNS_RESOLVED_IP}"
  else
    echo "  DNS IP: (not found after 60s)"
  fi
  
  echo -n "  Waiting for DNS propagation..."
  
  # Wait for DNS to propagate and verify it matches
  if resolve_dns_with_retry "$hostname" "$ct_ip"; then
    echo "  [✓] DNS resolves correctly"
    return 0
  fi
  
  echo "  [!] DNS did not propagate within 60s"
  return 1
}

# -----------------------------
# CONTAINER FUNCTIONS
# -----------------------------

# Ensure swap is half of memory
# Checks current CT config and adjusts swap if needed
# Requires: CTID to be set
ensure_swap() {
  local current_memory current_swap expected_swap
  
  # Get current memory and swap from CT config
  current_memory=$(pct config "${CTID}" 2>/dev/null | grep -oP '^memory:\s*\K\d+' || echo "0")
  current_swap=$(pct config "${CTID}" 2>/dev/null | grep -oP '^swap:\s*\K\d+' || echo "0")
  expected_swap=$((current_memory / 2))
  
  if [[ "$current_swap" -ne "$expected_swap" ]]; then
    echo "Adjusting swap: ${current_swap} MB -> ${expected_swap} MB (half of ${current_memory} MB RAM)"
    pct set "${CTID}" -swap "${expected_swap}"
    echo "  [\u2713] Swap adjusted"
  fi
}

# Build list of all containers
# Populates CT_MAP (CTID -> hostname), CT_STATUS (CTID -> status), and CT_LIST (array of CTIDs)
build_ct_list() {
  CT_MAP=()
  CT_LIST=()
  CT_STATUS=()
  
  # Parse pct list output: VMID, Status, Lock, Name
  # Skip header line, extract all info in one pass
  # Use $NF for Name (last field) since Lock column may be empty
  while IFS= read -r line; do
    local id status name
    id=$(echo "$line" | awk '{print $1}')
    [[ "$id" =~ ^[0-9]+$ ]] || continue
    
    status=$(echo "$line" | awk '{print $2}')
    name=$(echo "$line" | awk '{print $NF}')
    
    CT_MAP["$id"]="$name"
    CT_STATUS["$id"]="$status"
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
  
  # Build whiptail radiolist arguments
  local radio_args=()
  local width=60
  local item_width=$((width - 16))  # Account for borders, tag column, and radio button
  local first=true
  
  for id in "${CT_LIST[@]}"; do
    local status hostname item_text selected
    status="${CT_STATUS[$id]}"
    hostname="${CT_MAP[$id]}"
    # Pad text to fixed width for consistent listbox appearance
    item_text=$(printf "%-${item_width}s" "${hostname} [${status}]")
    # Pre-select first item
    if [[ "$first" == "true" ]]; then
      selected="ON"
      first=false
    else
      selected="OFF"
    fi
    radio_args+=("$id" "$item_text" "$selected")
  done
  
  # Calculate dialog dimensions
  local height=$((${#CT_LIST[@]} + 8))
  [[ $height -gt 20 ]] && height=20
  local list_height=$((height - 6))
  
  # Show whiptail radiolist and capture selection
  local selection
  selection=$(whiptail --title "Container Selection" \
    --radiolist "Select container to ${action}:" \
    "$height" "$width" "$list_height" \
    "${radio_args[@]}" \
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
  local width=60
  local item_width=$((width - 16))  # Account for borders, tag column, and checkbox
  
  for id in "${CT_LIST[@]}"; do
    local status hostname item_text
    status="${CT_STATUS[$id]}"
    hostname="${CT_MAP[$id]}"
    # Pad text to fixed width for consistent listbox appearance
    item_text=$(printf "%-${item_width}s" "${hostname} [${status}]")
    checklist_args+=("$id" "$item_text" "OFF")
  done
  
  # Calculate dialog dimensions
  local height=$((${#CT_LIST[@]} + 8))
  [[ $height -gt 20 ]] && height=20
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

# Execute command in container with optional timeout
# Args:
#   --timeout N  Maximum seconds before killing the command (optional, default: no timeout)
#   $1           CTID (optional if $CTID is set), detected when first arg is numeric
#   remaining    Command string to execute via sh -c
# Usage:
#   ct_exec "command"
#   ct_exec 2100 "command"
#   ct_exec --timeout 30 "command"
#   ct_exec --timeout 60 2100 "command"
# Returns: exit code of the command, or 124 on timeout
ct_exec() {
  local ct_timeout=""
  
  if [[ "$1" == "--timeout" ]]; then
    ct_timeout="$2"
    shift 2
  fi
  
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
  
  if [[ -n "$ct_timeout" ]]; then
    local rc=0
    timeout "${ct_timeout}" pct exec "$ctid" -- sh -c "$cmd" || rc=$?
    if [[ $rc -eq 124 ]]; then
      echo "  [!] Timeout: command exceeded ${ct_timeout}s in CT ${ctid}" >&2
    fi
    return $rc
  else
    pct exec "$ctid" -- sh -c "$cmd"
  fi
}

# Check if container exists
# Args: $1 = CTID
# Returns: 0 if exists, 1 if not
ct_exists() {
  local ctid="$1"
  pct status "$ctid" &>/dev/null
}

# Run per-CT configure.sh script (if present)
# Looks for ${DIR_DOCKER}/configure.sh on the Proxmox host and runs it
# inside the CT via ct_exec. The script must be idempotent.
#
# If ${DIR_DOCKER}/configure.env exists, each line maps an env var name to
# a jq path in commonCT.json. Resolved values are injected as environment
# variables into the ct_exec call (secrets never touch CT disk).
#
# configure.env format (lines starting with # are ignored):
#   ENV_VAR_NAME=jq.dot.path
#   AUTHENTIK_API_TOKEN=authentik.apitoken
#
# Args: none (uses global CTID, CT_HOSTNAME, DIR_DOCKER)
# Returns: 0 on success or if no script exists, 1 on failure (non-fatal)
run_configure_script() {
  local configure_script="${DIR_DOCKER}/_config/configure.sh"

  if [[ ! -f "$configure_script" ]]; then
    return 0
  fi

  echo "Running per-CT configure script..."

  # Ensure the script is executable
  chmod +x "$configure_script"

  # Build env var prefix from configure.env mappings
  local env_prefix=""
  local configure_env="${DIR_DOCKER}/_config/configure.env"

  if [[ -f "$configure_env" ]] && config_exists; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      # Skip comments and blank lines
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      [[ -z "${line// /}" ]] && continue

      local var_name="${line%%=*}"
      local jq_path="${line#*=}"

      # Convert dot path to jq filter: authentik.apitoken -> .authentik.apitoken
      local jq_filter=".${jq_path}"
      local value
      value=$(jq -r "${jq_filter} // empty" "${CONFIG_FILE}" 2>/dev/null)

      if [[ -n "$value" ]]; then
        # Escape single quotes in value for safe shell injection
        value="${value//\'/\'\\\'\'}"
        env_prefix="${env_prefix}${var_name}='${value}' "
      fi
    done < "$configure_env"
  fi

  # Wait for Docker containers to be healthy (up to 120s)
  echo "  Waiting for containers to be healthy..."
  local retries=24
  while ! ct_exec --timeout 10 'cd /mnt/docker && docker compose ps --status running --quiet 2>/dev/null | head -1 | grep -q .' 2>/dev/null; do
    retries=$((retries - 1))
    if [[ $retries -le 0 ]]; then
      echo "  [!] Containers not healthy after 120s, running configure.sh anyway"
      break
    fi
    sleep 5
  done

  # Run the script inside the CT with injected env vars
  if ct_exec --timeout 120 "cd /mnt/docker && ${env_prefix}bash ./_config/configure.sh '${CT_HOSTNAME}'" 2>&1; then
    echo "  [✓] Configure script completed"
  else
    echo "  [!] Configure script failed (exit code $?) — continuing"
    return 0  # Non-fatal
  fi
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
