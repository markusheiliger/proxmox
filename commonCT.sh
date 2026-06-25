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
#   configure_docker_watchdog Boot-time watchdog that retries Docker startup
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
#   flush_local_dns_cache  Flush host local DNS resolver cache (best effort)
#   resolve_dns_with_retry Resolve DNS with retry loop (sets DNS_RESOLVED_IP)
#   check_dns_health       Check and auto-fix DNS via UDM Pro API
#
# CONFIG FUNCTIONS (read from commonCT.json):
#   config_exists          Check if config file exists
#   config_get_domains     Get list of configured domains
#   config_get_primary_domain Get primary domain (first domain in config)
#   config_domain_exists   Check if domain is configured
#   config_get_fingerprint Get SSL fingerprint for domain
#   config_get_email       Get email for domain
#   config_get_ssl_type    Get SSL type for domain (step_ca, letsencrypt)
#   config_get_dns_provider Get DNS provider for domain SSL config
#   config_get_dns_api_token Get DNS API token for domain SSL config
#   config_get_dns_account_id Get DNS account id for domain SSL config
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
#   config_get_splitdns_hostname Get split DNS CT hostname
#   config_splitdns_configured Check if split DNS is configured
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

# Get primary domain (first domain in config)
# Returns: domain string or empty
config_get_primary_domain() {
  if ! config_exists; then
    return 1
  fi
  jq -r '.domains[0] // empty' "${CONFIG_FILE}" 2>/dev/null
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

# Get SSL type for domain
# Args: $1 = domain name
# Returns: SSL type string (e.g., step_ca, letsencrypt) or empty if not found
config_get_ssl_type() {
  local domain="$1"
  if ! config_exists; then
    return 1
  fi
  jq -r --arg d "$domain" '.ssl[$d].type // empty' "${CONFIG_FILE}"
}

# Get DNS provider for domain
# Args: $1 = domain name
# Returns: provider string (e.g., dnsimple) or empty if not found
config_get_dns_provider() {
  local domain="$1"
  if ! config_exists; then
    return 1
  fi
  jq -r --arg d "$domain" '.ssl[$d].dns_provider // empty' "${CONFIG_FILE}"
}

# Get DNS API token for domain
# Args: $1 = domain name
# Returns: token string or empty if not found
config_get_dns_api_token() {
  local domain="$1"
  if ! config_exists; then
    return 1
  fi
  jq -r --arg d "$domain" '.ssl[$d].dns_api_token // empty' "${CONFIG_FILE}"
}

# Get DNS account id for domain
# Args: $1 = domain name
# Returns: account id string or empty if not found
config_get_dns_account_id() {
  local domain="$1"
  if ! config_exists; then
    return 1
  fi
  jq -r --arg d "$domain" '.ssl[$d].dns_account_id // empty' "${CONFIG_FILE}"
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

# Get split DNS CT hostname
# Returns: hostname or empty
config_get_splitdns_hostname() {
  if ! config_exists; then
    return 1
  fi
  jq -r '.splitdns.hostname // empty' "${CONFIG_FILE}" 2>/dev/null
}

# Check if split DNS is configured
# Returns: 0 if configured (hostname set), 1 if not
config_splitdns_configured() {
  local hostname
  hostname=$(config_get_splitdns_hostname)
  [[ -n "$hostname" ]]
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

# -----------------------------
# TELEMETRY CONFIGURATION FUNCTIONS
# -----------------------------

# Get telemetry hostname
# Returns: hostname or empty
config_get_telemetry_hostname() {
  if ! config_exists; then
    return 1
  fi
  jq -r '.telemetry.hostname // empty' "${CONFIG_FILE}" 2>/dev/null
}

# Get telemetry fluentd port
# Returns: port number or empty
config_get_telemetry_fluentd_port() {
  if ! config_exists; then
    return 1
  fi
  jq -r '.telemetry.fluentd_port // empty' "${CONFIG_FILE}" 2>/dev/null
}

# Get telemetry OTLP port
# Returns: port number or empty
config_get_telemetry_otlp_port() {
  if ! config_exists; then
    return 1
  fi
  jq -r '.telemetry.otlp_port // empty' "${CONFIG_FILE}" 2>/dev/null
}

# Get telemetry syslog port
# Returns: port number or empty
config_get_telemetry_syslog_port() {
  if ! config_exists; then
    return 1
  fi
  jq -r '.telemetry.syslog_port // empty' "${CONFIG_FILE}" 2>/dev/null
}

# Check if telemetry is configured
# Returns: 0 if configured (hostname set), 1 if not
config_telemetry_configured() {
  local hostname
  hostname=$(config_get_telemetry_hostname)
  [[ -n "$hostname" ]]
}

# Set static IP and alias on UDM Pro for all CTs.
# Set local DNS record only when CT domain matches the primary domain
# (first entry in .domains[] in commonCT.json, case-insensitive).
#
# Args:
#   $1 - CT MAC address
#   $2 - CT IP address
#   $3 - CT hostname (FQDN, also used as alias)
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

  local ct_domain primary_domain set_local_dns
  ct_domain="${ct_hostname#*.}"
  primary_domain=$(config_get_primary_domain)
  set_local_dns=true
  if [[ -n "$primary_domain" && "${ct_domain,,}" != "${primary_domain,,}" ]]; then
    set_local_dns=false
  fi
  
  # Clear conflicting DNS record from other clients only when we set local DNS.
  if [[ "$set_local_dns" == "true" ]]; then
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
  fi
  
  echo "    Client ID: ${client_id}"
  echo "    Setting static IP: ${ct_ip}"
  echo "    Setting alias: ${ct_hostname}"
  if [[ "$set_local_dns" == "true" ]]; then
    echo "    Setting local DNS: ${ct_hostname} (primary domain)"
  else
    echo "    Skipping local DNS record on UDM Pro (non-primary domain; expects domain forwarding)"
  fi
  
  # Update client with fixed IP and alias. Local DNS is conditional by domain.
  local update_payload
  if [[ "$set_local_dns" == "true" ]]; then
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
  else
    update_payload=$(jq -n \
      --arg ip "$ct_ip" \
      --arg name "$ct_hostname" \
      '{
        use_fixedip: true,
        fixed_ip: $ip,
        local_dns_record_enabled: false,
        local_dns_record: "",
        name: $name
      }')
  fi
  
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

  # Skip for telemetry host itself (avoid loop)
  local telemetry_host
  telemetry_host=$(config_get_telemetry_hostname)
  if [[ "${ct_hostname}" == "${telemetry_host}" ]]; then
    echo "Skipping log forwarding for telemetry host (would loop)."
    return
  fi

  if ! config_telemetry_configured; then
    echo "  [!] Telemetry not configured, skipping log forwarding"
    return
  fi

  local fluentd_port
  fluentd_port=$(config_get_telemetry_fluentd_port)

  echo "Configuring Docker log forwarding to OTEL..."
  echo "  Log target: ${telemetry_host}:${fluentd_port}"
  echo "  Tag format: ${ct_hostname}.{{.Name}}"

  # Build daemon.json using jq
  # Tag format: hostname.containername (e.g., seafile.thesaints.home.seafile-db)
  local daemon_json
  daemon_json=$(jq -n \
    --arg addr "${telemetry_host}:${fluentd_port}" \
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

  # Disable Telegraf on the telemetry host itself (avoid self-reporting)
  local telemetry_host
  telemetry_host=$(config_get_telemetry_hostname)
  if [[ "${ct_hostname}" == "${telemetry_host}" ]]; then
    echo "Disabling Telegraf on telemetry host (avoid self-reporting)..."
    ct_exec --timeout 15 '
      rc-service telegraf stop >/dev/null 2>&1 || true
      rc-update del telegraf default >/dev/null 2>&1 || true
    '
    echo "  [✓] Telegraf disabled on telemetry host"
    return
  fi

  if ! config_telemetry_configured; then
    echo "  [!] Telemetry not configured, skipping Telegraf"
    return
  fi

  local otlp_port
  otlp_port=$(config_get_telemetry_otlp_port)

  local domain
  domain=$(extract_domain_from_hostname "${ct_hostname}")

  echo "Configuring Telegraf metrics collection..."
  echo "  Metrics target: ${telemetry_host}:${otlp_port}"

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
  service_address = \"${telemetry_host}:${otlp_port}\"
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

  # A transient crash can occur if telegraf restarts while the Docker socket is
  # mid-cycle (e.g. during a refresh that also restarts Docker) or under brief
  # memory pressure on low-RAM CTs. Retry the restart once before warning.
  if echo "$service_status" | grep -q "crashed"; then
    echo "  Telegraf reported crashed, retrying restart..."
    ct_exec --timeout 30 'rc-service telegraf restart >/dev/null 2>&1 || true'
    sleep 6
    service_status=$(ct_exec --timeout 15 'rc-service telegraf status 2>&1 || true')
  fi

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

  # Skip for telemetry host itself (avoid loop)
  local telemetry_host
  telemetry_host=$(config_get_telemetry_hostname)
  if [[ "${ct_hostname}" == "${telemetry_host}" ]]; then
    echo "Skipping syslog forwarding for telemetry host (would loop)."
    return
  fi

  if ! config_telemetry_configured; then
    echo "  [!] Telemetry not configured, skipping syslog forwarding"
    return
  fi

  local syslog_port
  syslog_port=$(config_get_telemetry_syslog_port)

  echo "Configuring syslog forwarding..."
  echo "  Syslog target: ${telemetry_host}:${syslog_port}"

  # Alpine uses busybox syslogd - configure remote logging
  ct_exec --timeout 30 "
    # Check current config
    current_opts=\$(grep '^SYSLOGD_OPTS=' /etc/conf.d/syslog 2>/dev/null || echo '')
    expected_opts='SYSLOGD_OPTS=\"-t -L -R ${telemetry_host}:${syslog_port}\"'
    
    if [ \"\$current_opts\" = \"\$expected_opts\" ]; then
      echo '  Syslog already configured correctly'
    else
      # Update syslogd config to forward to remote
      if grep -q '^SYSLOGD_OPTS=' /etc/conf.d/syslog 2>/dev/null; then
        sed -i 's|^SYSLOGD_OPTS=.*|SYSLOGD_OPTS=\"-t -L -R ${telemetry_host}:${syslog_port}\"|' /etc/conf.d/syslog
      else
        echo 'SYSLOGD_OPTS=\"-t -L -R ${telemetry_host}:${syslog_port}\"' >> /etc/conf.d/syslog
      fi
      # Restart syslog service (backgrounded to avoid blocking on DNS resolution)
      service syslog restart >/dev/null 2>&1 &
      echo '  Syslog config updated'
    fi
  "
  
  echo "  [✓] Syslog forwarding configured"
}

# Ensure system packages and CA certificates are current
# Detects package manager (apk/apt-get/dnf) and runs full update/upgrade
# Ensures ca-certificates package is installed and trust store is refreshed
# Idempotent: safe to run multiple times
# Args:
#   $1 - CTID (optional, defaults to global CTID)
# Returns: 0 on success, 1 on error (non-fatal)
ensure_packages_and_ca() {
  local ctid="${1:-${CTID}}"
  
  echo "Ensuring packages and CA certificates are current..."
  
  if ! ct_exec --timeout 180 "${ctid}" '
    set -e
    
    # Detect package manager and update
    if command -v apk >/dev/null 2>&1; then
      echo "  Using Alpine Linux (apk)"
      apk update
      apk upgrade --no-cache
      # Ensure ca-certificates and jq are installed
      apk add --no-cache ca-certificates jq 2>/dev/null || true
    elif command -v apt-get >/dev/null 2>&1; then
      echo "  Using Debian/Ubuntu (apt-get)"
      DEBIAN_FRONTEND=noninteractive apt-get update -qq
      DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
      # Ensure ca-certificates and jq are installed
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates jq 2>/dev/null || true
    elif command -v dnf >/dev/null 2>&1; then
      echo "  Using RHEL/Fedora (dnf)"
      dnf check-update -q || true
      dnf upgrade -y -q
      # Ensure ca-certificates and jq are installed
      dnf install -y -q ca-certificates jq 2>/dev/null || true
    else
      echo "  [!] Unknown package manager"
      exit 1
    fi
    
    # Refresh CA trust store (distro-agnostic)
    if command -v update-ca-certificates >/dev/null 2>&1; then
      update-ca-certificates
    elif command -v update-ca-trust >/dev/null 2>&1; then
      update-ca-trust
    fi
  ' 2>/dev/null; then
    echo "  [!] Warning: Package/CA update failed (continuing)"
    return 0  # Non-fatal - continue provisioning
  fi
  
  echo "  [✓] Packages and CA certificates current"
  return 0
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

  local domain
  domain=$(extract_domain_from_hostname "${ct_hostname}")

  # Skip for non-step_ca SSL types
  local ssl_type
  ssl_type=$(config_get_ssl_type "${domain}")
  if [[ "$ssl_type" != "step_ca" ]]; then
    echo "Skipping Step CA setup (SSL type: ${ssl_type:-unknown})"
    return
  fi

  echo "Configuring Step CA trust..."

  local ca_name fingerprint
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
  if ct_exec --timeout 30 "cp /root/.step/certs/root_ca.crt /usr/local/share/ca-certificates/step-ca-root.crt" >/dev/null 2>&1; then
    # Refresh trust store to include newly added cert
    if ct_exec --timeout 30 'update-ca-certificates' >/dev/null 2>&1; then
      echo "  [✓] Root CA added to system trust store"
      # Restart Docker so it picks up the new CA cert.
      # Alpine's supervise-daemon stop phase can take up to 70s;
      # container restoration adds another 30-50s.
      echo "  Restarting Docker to reload trust store..."
      ct_exec --timeout 120 'service docker restart >/dev/null 2>&1 || true'
    else
      echo "  [!] Warning: Failed to refresh CA trust store"
    fi
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

# Install Docker and Docker Compose inside a CT (Alpine/OpenRC).
# Create-time step; the boot runlevel is managed separately and idempotently
# by ensure_docker_runlevel() (invoked from apply_ct_configuration), so this
# function only installs the packages and starts the daemon.
# Args:
#   $1 - CTID (defaults to global $CTID)
install_docker() {
  local ctid="${1:-${CTID}}"

  echo "Installing Docker inside CT ${ctid}..."
  ct_exec --timeout 120 "${ctid}" '
    set -e
    apk update
    apk add docker docker-cli-compose ca-certificates
    service docker start || true
  '
}

# Ensure the Docker service starts on boot via the correct OpenRC runlevel.
# Docker must run in the 'default' runlevel (after networking and bind mounts
# are ready), not 'boot' (which starts too early and intermittently fails).
# Idempotent: safe to run on every create/refresh. No-op on non-OpenRC systems.
# Args:
#   $1 - CTID (defaults to global $CTID)
ensure_docker_runlevel() {
  local ctid="${1:-${CTID}}"

  echo "Ensuring Docker starts on boot (OpenRC default runlevel)..."
  ct_exec --timeout 30 "${ctid}" '
    if command -v rc-update >/dev/null 2>&1; then
      rc-update del docker boot 2>/dev/null || true
      rc-update add docker default 2>/dev/null || true
    fi
  '
  echo "  [✓] Docker boot runlevel configured"
}

# Verify the Docker daemon is up and responsive inside a CT, with active
# recovery. Every CT in this fleet is a Docker host, so a dead daemon after a
# reboot is a hard failure — this function waits for `docker info`, and if the
# daemon does not come up it re-asserts the boot runlevel and forces a restart
# before giving up. Idempotent and safe to call after any reboot.
# Args:
#   $1 - CTID (defaults to global $CTID)
#   $2 - seconds to wait for the daemon on each attempt (optional, default 120)
# Returns: 0 if the daemon is responsive, 1 if still down after recovery.
ensure_docker_running() {
  local ctid="${1:-${CTID}}"
  local timeout="${2:-120}"
  local i

  echo "Verifying Docker daemon in CT ${ctid}..."

  # Fast path / initial wait: daemon may still be starting after the reboot.
  for ((i=1; i<=timeout; i++)); do
    if ct_exec --timeout 10 "${ctid}" 'docker info >/dev/null 2>&1' 2>/dev/null; then
      echo "  [✓] Docker daemon is running"
      return 0
    fi
    sleep 1
  done

  # Recovery: re-assert the boot runlevel and force a (re)start, then wait again.
  echo "  [!] Docker daemon not responding after ${timeout}s — attempting recovery..."
  ensure_docker_runlevel "${ctid}"
  ct_exec --timeout 60 "${ctid}" 'rc-service docker restart >/dev/null 2>&1 || rc-service docker start >/dev/null 2>&1 || true'

  for ((i=1; i<=timeout; i++)); do
    if ct_exec --timeout 10 "${ctid}" 'docker info >/dev/null 2>&1' 2>/dev/null; then
      echo "  [✓] Docker daemon recovered and is running"
      return 0
    fi
    sleep 1
  done

  echo "  [✗] Docker daemon FAILED to start in CT ${ctid} after recovery attempt"
  echo "      Diagnose: pct exec ${ctid} -- sh -c 'rc-service docker status; tail -n 40 /var/log/docker.log'"
  return 1
}

# Install a boot-time Docker watchdog inside the CT.
# On a low-RAM CT the embedded containerd can time out during the boot storm,
# causing dockerd to give up and exit — leaving the Docker host dead after a
# reboot until something restarts it. This OpenRC service runs after the docker
# service at boot, polls `docker info`, and restarts Docker until the daemon is
# responsive. Self-heals on EVERY reboot (refresh, manual, or Proxmox host
# reboot), not just during provisioning.
# Idempotent: rewrites the unit and re-asserts the runlevel on each run.
# No-op on non-OpenRC systems.
# Args:
#   $1 - CTID (defaults to global $CTID)
configure_docker_watchdog() {
  local ctid="${1:-${CTID}}"

  # Only meaningful on OpenRC (Alpine) systems.
  if ! ct_exec --timeout 15 "${ctid}" 'command -v rc-update >/dev/null 2>&1' 2>/dev/null; then
    echo "Skipping Docker watchdog (non-OpenRC system)."
    return 0
  fi

  echo "Configuring Docker boot watchdog..."

  # Write the OpenRC unit with a quoted heredoc so the in-script $variables are
  # NOT expanded by the host shell (same pattern as configure_arping_service).
  pct exec "${ctid}" -- sh -c 'cat > /etc/init.d/docker-watchdog << '"'"'WATCHDOG'"'"'
#!/sbin/openrc-run

description="Retry Docker startup at boot until the daemon is responsive"

depend() {
    after docker
}

start() {
    ebegin "Verifying Docker daemon is responsive"
    i=0
    max=12
    while [ "$i" -lt "$max" ]; do
        if docker info >/dev/null 2>&1; then
            eend 0
            return 0
        fi
        i=$((i + 1))
        ewarn "Docker not responsive (attempt $i/$max) - restarting docker"
        rc-service docker restart >/dev/null 2>&1 || rc-service docker start >/dev/null 2>&1 || true
        sleep 5
    done
    docker info >/dev/null 2>&1
    eend $? "Docker daemon did not become responsive after $max attempts"
}
WATCHDOG
chmod +x /etc/init.d/docker-watchdog
rc-update add docker-watchdog default 2>/dev/null || true'

  echo "  [✓] Docker boot watchdog configured"
}

# Apply the standard CT configuration sequence.
# Consolidates the 8 idempotent config steps shared by createCT and refreshCT
# into a single call.  Each step prints its own [✓] output.
# Args:
#   $1 - CTID (defaults to global $CTID)
#   $2 - CT hostname (defaults to $CT_HOSTNAME or $HOSTNAME)
#   $3 - GPU passthrough flag ("true" to enable, optional)
apply_ct_configuration() {
  local ctid="${1:-${CTID}}"
  local hostname="${2:-${CT_HOSTNAME:-${HOSTNAME}}}"
  local gpu="${3:-false}"

  ensure_packages_and_ca "${ctid}"
  configure_timezone
  ensure_docker_runlevel "${ctid}"
  configure_docker_watchdog "${ctid}"
  configure_docker_logging "${hostname}"
  configure_telegraf "${hostname}"
  configure_syslog_forwarding "${hostname}"
  configure_registry_logins
  configure_step_ca "${hostname}"
  configure_arping_service "${hostname}"

  if [[ "$gpu" == "true" ]]; then
    configure_gpu_passthrough
  fi
}

# Configure Authentik forward auth for a CT
# Detects caddy.forward_auth labels in the CT's docker-compose.yaml and
# auto-provisions a per-host forward auth setup in Authentik via REST API:
#   1. Proxy Provider (mode: forward_single, external_host = https://<hostname>)
#   2. Application (linked to the provider)
#   3. Outpost assignment (adds provider to the configured outpost)
# Per-host (forward_single): one provider/application per protected hostname. This
# works regardless of whether the app and Authentik share a parent domain, because
# the proxy session cookie is scoped to the application host itself.
# Individual apps handle their own authorization; Authentik only authenticates.
# Idempotent: skips if the host application already exists with a provider attached
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

  if ! grep -qE 'caddy\.(route\.[0-9]+_)?forward_auth' "$compose_file" 2>/dev/null; then
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

  # Single-application: one provider per host (mode forward_single).
  # forward_domain is unusable here because Authentik (e.g. oidc.thesaints.de) and many
  # protected hosts (e.g. home.thesaints.home) live under different parent domains; a
  # domain-level cookie cannot span them. forward_single sets the proxy session cookie on
  # the application host itself, so the parent domains no longer need to match.
  local app_host
  app_host="$hostname_lower"
  local slug
  slug=$(echo "$app_host" | tr '.' '-')

  # Helper: Authentik API GET
  ak_get() {
    curl -sk --connect-timeout 10 --max-time 60 -H "Authorization: Bearer ${ak_token}" -H "Accept: application/json" \
      "${ak_api}${1}" 2>/dev/null
  }

  # Helper: Authentik API POST
  ak_post() {
    curl -sk --connect-timeout 10 --max-time 60 -X POST -H "Authorization: Bearer ${ak_token}" \
      -H "Content-Type: application/json" -H "Accept: application/json" \
      "${ak_api}${1}" -d "${2}" 2>/dev/null
  }

  # Helper: Authentik API PATCH
  ak_patch() {
    curl -sk --connect-timeout 10 --max-time 60 -X PATCH -H "Authorization: Bearer ${ak_token}" \
      -H "Content-Type: application/json" -H "Accept: application/json" \
      "${ak_api}${1}" -d "${2}" 2>/dev/null
  }

  # Step 1: Check if domain application already exists with a provider
  local existing_app
  existing_app=$(ak_get "/core/applications/?slug=${slug}")

  if echo "$existing_app" | jq -e --arg s "$slug" '.results[] | select(.slug == $s) | .provider != null' >/dev/null 2>&1; then
    echo "  [✓] Authentik: host '${app_host}' already configured"
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

  # Step 3: Create per-host Proxy Provider (forward_single)
  echo "  Creating proxy provider: ${app_host}"
  local provider_payload
  provider_payload=$(jq -n \
    --arg name "${app_host}" \
    --arg auth_flow "$auth_flow_uuid" \
    --arg inval_flow "$inval_flow_uuid" \
    --arg ext_host "https://${app_host}" \
    '{
      name: $name,
      authorization_flow: $auth_flow,
      invalidation_flow: $inval_flow,
      external_host: $ext_host,
      mode: "forward_single"
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
    --arg name "${app_host}" \
    --arg slug "$slug" \
    --argjson provider "$provider_pk" \
    --arg launch_url "https://${app_host}" \
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

  echo "  [✓] Authentik forward auth configured (host: ${app_host})"
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

# Detect transient registry/network errors that are worth retrying.
# Args:
#   $1 - text to inspect (typically captured docker output)
# Returns: 0 if the text matches a known transient error, 1 otherwise
is_transient_registry_error() {
  echo "$1" | grep -qiE 'TLS handshake timeout|i/o timeout|Client\.Timeout exceeded|temporary failure|no such host|connection reset|unexpected EOF|context deadline exceeded|deadline exceeded|429 Too Many Requests|500 Internal Server Error|timeout awaiting'
}

# Pull all images for a CT's compose stack with exponential backoff.
# Detects all profiles so every image (incl. published/newt) is cached locally,
# allowing a subsequent 'compose up --pull missing' to start without network.
# Args:
#   $1 - CTID (optional, defaults to global CTID)
# Returns: 0 on success, 1 on failure
compose_pull() {
  local ctid="${1:-${CTID}}"

  # Get all profiles defined in the compose file and build --profile flags
  local profile_flags
  profile_flags=$(ct_exec --timeout 30 "${ctid}" 'cd /mnt/docker && docker compose config --profiles 2>/dev/null' | \
    while read -r profile; do echo -n "--profile $profile "; done)

  local max_attempts=5
  local attempt output backoff
  local pull_cmd="cd /mnt/docker && docker compose ${profile_flags}pull"

  for ((attempt=1; attempt<=max_attempts; attempt++)); do
    echo "  Pulling images (attempt ${attempt}/${max_attempts})..."

    if output=$(ct_exec --timeout 600 "${ctid}" "${pull_cmd}" 2>&1); then
      [[ -n "$output" ]] && echo "$output"
      return 0
    fi

    [[ -n "$output" ]] && echo "$output"

    # Only retry transient registry/network failures
    if ! is_transient_registry_error "$output"; then
      echo "  [!] Non-transient pull error; aborting."
      return 1
    fi

    if [[ $attempt -lt $max_attempts ]]; then
      # On attempt 3, restart Docker once as a last-resort recovery
      if [[ $attempt -eq 3 ]]; then
        echo "  [!] Persistent transient error; restarting Docker once..."
        ct_exec --timeout 120 "${ctid}" 'service docker restart >/dev/null 2>&1 || true'
        local waited=0
        while ! ct_exec --timeout 10 "${ctid}" 'docker info >/dev/null 2>&1' 2>/dev/null; do
          waited=$((waited + 5))
          if [[ $waited -ge 120 ]]; then
            echo "  [!] Docker daemon not responsive after restart (${waited}s)"
            return 1
          fi
          sleep 5
        done
      else
        backoff=$((10 * (1 << (attempt - 1))))
        echo "  [!] Transient registry/network error; retrying in ${backoff}s..."
        sleep "${backoff}"
      fi
    fi
  done

  echo "  [!] Image pull failed after ${max_attempts} attempts."
  return 1
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

  # Determine TLS provider env requirements for this CT domain
  local domain ssl_type dns_provider dns_api_token dns_account_id
  domain=$(extract_domain_from_hostname "$hostname")
  ssl_type=$(config_get_ssl_type "$domain")
  dns_provider=$(config_get_dns_provider "$domain")
  dns_api_token=$(config_get_dns_api_token "$domain")
  dns_account_id=$(config_get_dns_account_id "$domain")
  
  # Update .env file with newt values
  local hostname_lower
  hostname_lower=$(echo "$hostname" | tr '[:upper:]' '[:lower:]')
  local env_file="/mnt/docker/${hostname_lower}/.env"
  
  if [[ -f "$env_file" ]]; then
    set_or_add_env() {
      local key="$1"
      local value="$2"
      if grep -q "^${key}=" "$env_file"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$env_file"
      else
        echo "${key}=${value}" >> "$env_file"
      fi
    }

    remove_env() {
      local key="$1"
      sed -i "/^${key}=/d" "$env_file"
    }

    # Update or add NEWT values
    set_or_add_env "NEWT_ID" "${newt_id}"
    set_or_add_env "NEWT_SECRET" "${newt_secret}"
    set_or_add_env "NEWT_ENDPOINT" "${newt_endpoint}"

    # Keep DNS provider credentials aligned with the CT domain SSL config.
    if [[ "$ssl_type" == "letsencrypt" && "$dns_provider" == "dnsimple" && -n "$dns_api_token" ]]; then
      set_or_add_env "DNSIMPLE_API_ACCESS_TOKEN" "${dns_api_token}"
      # Optional account id; an empty value lets the provider fall back to a whoami lookup.
      set_or_add_env "DNSIMPLE_ACCOUNT_ID" "${dns_account_id}"
    else
      # Avoid leaking DNSimple vars into non-dnsimple or internal domains.
      remove_env "DNSIMPLE_API_ACCESS_TOKEN"
      remove_env "DNSIMPLE_ACCOUNT_ID"
    fi
  fi
  
  # Build compose command with optional published profile
  local profile_flag=""
  if [[ -n "$newt_id" && -n "$newt_secret" && -n "$newt_endpoint" ]]; then
    profile_flag="--profile published"
    echo "  Newt tunnel enabled (published profile)"
  fi

  # Images are pre-pulled by compose_pull (see reset_docker), so use the default
  # --pull missing here: start from cached images and avoid a redundant network hit.
  local max_attempts=3
  local attempt output
  local compose_cmd="cd /mnt/docker && docker compose ${profile_flag} up -d --pull missing --remove-orphans"

  for ((attempt=1; attempt<=max_attempts; attempt++)); do
    echo "  Starting services (attempt ${attempt}/${max_attempts})..."

    if output=$(ct_exec --timeout 300 "${ctid}" "${compose_cmd}" 2>&1); then
      [[ -n "$output" ]] && echo "$output"
      return 0
    fi

    [[ -n "$output" ]] && echo "$output"

    # Retry transient registry/network failures
    if is_transient_registry_error "$output"; then
      if [[ $attempt -lt $max_attempts ]]; then
        # Back off first; only restart Docker as a last resort on the final retry.
        if [[ $attempt -eq $((max_attempts - 1)) ]]; then
          echo "  [!] Persistent transient error; restarting Docker and retrying..."
          ct_exec --timeout 120 "${ctid}" 'service docker restart >/dev/null 2>&1 || true'
          # Wait for Docker daemon to be responsive before retrying
          local waited=0
          while ! ct_exec --timeout 10 "${ctid}" 'docker info >/dev/null 2>&1' 2>/dev/null; do
            waited=$((waited + 5))
            if [[ $waited -ge 120 ]]; then
              echo "  [!] Docker daemon not responsive after restart (${waited}s)"
              return 1
            fi
            sleep 5
          done
        else
          local backoff=$((10 * attempt))
          echo "  [!] Transient registry/network error; retrying in ${backoff}s..."
          sleep "${backoff}"
        fi
        continue
      fi
    fi

    return 1
  done

  return 1
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
  
  ct_exec --timeout 300 "${ctid}" "cd /mnt/docker && docker compose ${profile_flags} down"
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

# Flush local DNS cache on the Proxmox host (best effort)
# Handles common resolver stacks. Non-fatal if no known cache service exists.
# Returns: 0 always
flush_local_dns_cache() {
  local flushed=false

  # systemd-resolved
  if command -v resolvectl >/dev/null 2>&1; then
    if resolvectl flush-caches >/dev/null 2>&1; then
      flushed=true
    fi
  elif command -v systemd-resolve >/dev/null 2>&1; then
    if systemd-resolve --flush-caches >/dev/null 2>&1; then
      flushed=true
    fi
  fi

  # nscd
  if command -v nscd >/dev/null 2>&1; then
    if nscd -i hosts >/dev/null 2>&1; then
      flushed=true
    fi
  fi

  # dnsmasq / unbound cache via service manager
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet dnsmasq 2>/dev/null && systemctl reload dnsmasq >/dev/null 2>&1; then
      flushed=true
    fi
    if systemctl is-active --quiet unbound 2>/dev/null && systemctl reload unbound >/dev/null 2>&1; then
      flushed=true
    fi
  fi

  if [[ "$flushed" == "true" ]]; then
    echo "  Local DNS cache flushed"
  else
    echo "  [i] No local DNS cache service detected to flush"
  fi

  return 0
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
  # Retry a few times — DHCP may not be ready immediately after reboot
  local ip_retries=5
  ct_ip=""
  while [[ -z "$ct_ip" && $ip_retries -gt 0 ]]; do
    ct_ip=$(ct_exec --timeout 15 "${ctid}" 'ip -4 addr show eth0 2>/dev/null | grep "inet " | tr -s " " | cut -d" " -f3 | cut -d"/" -f1' 2>/dev/null)
    if [[ -z "$ct_ip" ]]; then
      ip_retries=$((ip_retries - 1))
      [[ $ip_retries -gt 0 ]] && sleep 2
    fi
  done
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

  # For non-primary domains, refresh split DNS mapping before resolution checks.
  local primary_domain hostname_domain
  primary_domain=$(config_get_primary_domain)
  hostname_domain=$(extract_domain_from_hostname "$hostname")
  if [[ -n "$primary_domain" && "${hostname_domain,,}" != "${primary_domain,,}" ]]; then
    if config_splitdns_configured; then
      echo "  Refreshing split DNS configuration..."
      "${SCRIPT_DIR}/forwardDNSCT.sh" || echo "  [!] Split DNS refresh failed (non-fatal)"
    else
      echo "  [i] splitdns.hostname not configured, skipping split DNS refresh"
    fi
  fi
  
  # -------------------------
  # Check DNS
  # -------------------------
  flush_local_dns_cache

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

  flush_local_dns_cache
  
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

# Check the health of a single Proxmox storage.
# Verifies the storage exists/is active and, when it is a ZFS pool, that the pool
# is ONLINE and not resilvering (i.e. its redundancy is intact). Non-ZFS storages
# (dir, lvmthin, nfs, ...) have no ZFS redundancy concept here and only get the
# existence check.
# Args: $1 = storage id
# Output: on failure, echoes a human-readable reason to stdout
# Returns: 0 if healthy, 1 if missing/inactive/degraded/resilvering
check_storage_health() {
  local storage="$1"
  local health

  if [[ -z "$storage" ]]; then
    echo "no storage specified"
    return 1
  fi

  if ! pvesm status 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$storage"; then
    echo "storage '${storage}' not found or not active"
    return 1
  fi

  if command -v zpool >/dev/null 2>&1 && zpool list "$storage" >/dev/null 2>&1; then
    health=$(zpool list -H -o health "$storage" 2>/dev/null)
    if [[ "$health" != "ONLINE" ]]; then
      echo "ZFS pool '${storage}' health is ${health:-UNKNOWN} (redundancy lost)"
      return 1
    fi
    if zpool status "$storage" 2>/dev/null | grep -qiE 'resilver in progress'; then
      echo "ZFS pool '${storage}' is resilvering (redundancy not yet restored)"
      return 1
    fi
  fi

  return 0
}

# Check the health of every storage VOLUME backing a container.
# Inspects the CT's rootfs and any volume-backed mount points (mpN of the form
# "storage:volume"); bind mounts (host paths starting with "/") are ignored.
# Each distinct storage is validated with check_storage_health.
# Args:
#   $1 = CTID
#   $2 = mode: "fatal" (exit 1 on first problem) or "warn" (print warning, continue)
# Returns: 0 when all healthy or mode=warn; exits 1 when mode=fatal and a problem found.
check_ct_storage_health() {
  local ctid="$1"
  local mode="${2:-warn}"
  local config storages storage reason

  config=$(pct config "$ctid" 2>/dev/null) || {
    echo "  [!] Cannot read config for CT ${ctid}; skipping storage health check" >&2
    return 0
  }

  storages=$(echo "$config" \
    | grep -E '^(rootfs|mp[0-9]+):' \
    | sed -E 's/^[^:]+:[[:space:]]*//' \
    | grep -v '^/' \
    | sed -E 's/:.*//' \
    | sort -u)

  for storage in $storages; do
    if ! reason=$(check_storage_health "$storage"); then
      if [[ "$mode" == "fatal" ]]; then
        echo "  [✗] CT ${ctid}: storage health check failed: ${reason}" >&2
        exit 1
      fi
      echo "  [!] CT ${ctid}: storage health warning: ${reason}" >&2
    fi
  done

  return 0
}

# Get container status
# Args: $1 = CTID (optional, defaults to $CTID)
# Returns: status string (running, stopped, etc.)
get_ct_status() {
  local ctid="${1:-$CTID}"
  pct status "$ctid" 2>/dev/null | awk '{print $2}'
}

# Wait for a CT to become unlocked AND running, polling with exponential backoff.
# Proxmox holds a config lock (e.g. "lock: backup") during backup/snapshot/migrate
# operations, which blocks pct stop/set/start. This waits the lock out instead of
# failing immediately.
# Args:
#   $1 = CTID (optional, defaults to $CTID)
#   $2 = timeout in seconds (optional, default: 300)
# Returns: 0 once unlocked and running; 1 if still locked/not running at timeout.
wait_for_ct_unlock() {
  local ctid="${1:-$CTID}"
  local timeout="${2:-300}"
  local deadline=$(( $(date +%s) + timeout ))
  local delay=5
  local lock_reason announced=false

  while true; do
    lock_reason=$(pct config "${ctid}" 2>/dev/null | grep -oP '^lock:\s*\K\S+' || true)

    if [[ -z "$lock_reason" ]] && [[ "$(get_ct_status "$ctid")" == "running" ]]; then
      [[ "$announced" == "true" ]] && echo "  [✓] CT ${ctid} is unlocked and running"
      return 0
    fi

    local now remaining
    now=$(date +%s)
    if [[ $now -ge $deadline ]]; then
      if [[ -n "$lock_reason" ]]; then
        echo "  [!] CT ${ctid} still locked (lock: ${lock_reason}) after ${timeout}s"
      else
        echo "  [!] CT ${ctid} not running after ${timeout}s"
      fi
      return 1
    fi

    if [[ "$announced" != "true" ]]; then
      if [[ -n "$lock_reason" ]]; then
        echo "  CT ${ctid} is locked (lock: ${lock_reason}); waiting up to ${timeout}s for it to clear..."
      else
        echo "  CT ${ctid} is not running yet; waiting up to ${timeout}s..."
      fi
      announced=true
    fi

    # Do not sleep past the deadline
    remaining=$(( deadline - now ))
    [[ $delay -gt $remaining ]] && delay=$remaining
    sleep "$delay"

    # Exponential backoff, capped at 60s
    delay=$(( delay * 2 ))
    [[ $delay -gt 60 ]] && delay=60
  done
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

# Mirror the shared configure library into the CT before configure.sh runs.
# Source of truth: ${SCRIPT_DIR}/configure on the Proxmox host. The folder is
# COPIED (not symlinked/mounted) into ${DIR_DOCKER}/_config/shared because only
# files physically under the per-CT ${DIR_DOCKER} are visible inside the CT —
# anything sourced as /mnt/docker/_config/shared/*.sh must live there for real.
#
# Idempotent: the destination is fully mirrored (rm -rf + cp -a) on every run.
# Non-fatal: a CT without a _config/ dir, or a missing source library, is skipped.
#
# Args: none (uses globals SCRIPT_DIR, DIR_DOCKER)
sync_config_shared() {
  local src="${SCRIPT_DIR}/configure"
  local dest="${DIR_DOCKER}/_config/shared"

  # Only CTs that ship a _config/ (i.e. have a configure.sh) need the library.
  if [[ ! -d "${DIR_DOCKER}/_config" ]]; then
    return 0
  fi

  if [[ ! -d "$src" ]]; then
    echo "  [i] No shared configure library at ${src} - skipping"
    return 0
  fi

  rm -rf "$dest"
  mkdir -p "$dest"
  cp -a "${src}/." "${dest}/"
  echo "  [✓] Synced shared configure library -> _config/shared"
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

  echo ""
  echo "--- configure.sh (${CT_HOSTNAME}) ---"

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
  if ct_exec --timeout 120 "cd /mnt/docker && ${env_prefix}sh ./_config/configure.sh '${CT_HOSTNAME}'" 2>&1; then
    echo "--- [✓] configure.sh completed ---"
    echo ""
  else
    echo "--- [!] configure.sh failed (exit code $?) ---"
    echo ""
    return 1
  fi
}


# Update or create .env file with required configuration values
# Merges values from commonCT.json while preserving user-defined variables
#
# Values and their sources:
#   HOSTNAME            - Argument passed to createCT.sh (e.g., app.thesaints.home)
#   STEP_CA_URL         - Constructed from domain: https://ca.<domain>/acme/acme/directory
#   STEP_CA_FINGERPRINT - From commonCT.json: ssl.<domain>.fingerprint
#   CADDY_EMAIL         - From commonCT.json: ssl.<domain>.email
#   DNSIMPLE_API_ACCESS_TOKEN - From commonCT.json: ssl.<domain>.dns_api_token (for letsencrypt+dnsimple)
#   DNSIMPLE_ACCOUNT_ID - From commonCT.json: ssl.<domain>.dns_account_id (optional; empty falls back to whoami)
#
update_env_file() {
  local env_file="$1"
  local target_hostname="${CT_HOSTNAME:-${HOSTNAME:-}}"
  if [[ -z "$target_hostname" ]]; then
    echo "ERROR: No hostname available for update_env_file"
    return 1
  fi
  local domain
  domain=$(extract_domain_from_hostname "${target_hostname}")
  local ssl_type
  ssl_type=$(config_get_ssl_type "${domain}")
  local dns_provider dns_api_token dns_account_id
  dns_provider=$(config_get_dns_provider "${domain}")
  dns_api_token=$(config_get_dns_api_token "${domain}")
  dns_account_id=$(config_get_dns_account_id "${domain}")
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

  # Remove a key if present (used for provider-specific cleanup)
  remove_env_key() {
    local key="$1"
    sed -i "/^${key}=/d" "$env_file"
  }
  
  # Update required configuration values
  set_env_value "HOSTNAME" "${target_hostname}" "Site hostname (from CT container)"
  set_env_value "CADDY_EMAIL" "${email}" "Caddy email for ACME (from commonCT.json)"
  
  if [[ "$ssl_type" == "step_ca" ]]; then
    local ca_name
    ca_name=$(config_get_ca_name "${domain}")
    local fingerprint
    fingerprint=$(config_get_fingerprint "${domain}")
    set_env_value "STEP_CA_URL" "https://${ca_name}/acme/acme/directory" "Step CA configuration (from commonCT.json)"
    set_env_value "STEP_CA_FINGERPRINT" "${fingerprint}" ""
  fi

  # Inject DNS provider credentials only for letsencrypt + dnsimple domains.
  if [[ "$ssl_type" == "letsencrypt" && "$dns_provider" == "dnsimple" && -n "$dns_api_token" ]]; then
    set_env_value "DNSIMPLE_API_ACCESS_TOKEN" "${dns_api_token}" "DNSimple DNS challenge credentials (from commonCT.json)"
    set_env_value "DNSIMPLE_ACCOUNT_ID" "${dns_account_id}" "DNSimple account ID (optional; empty falls back to whoami lookup)"
  else
    remove_env_key "DNSIMPLE_API_ACCESS_TOKEN"
    remove_env_key "DNSIMPLE_ACCOUNT_ID"
  fi
  
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

# Copy docker-compose template from config to target file
# Args: $1 = target compose file path
create_compose_template() {
  local compose_file="$1"
  local target_hostname="${CT_HOSTNAME:-${HOSTNAME:-}}"
  if [[ -z "$target_hostname" ]]; then
    echo "ERROR: No hostname available for create_compose_template"
    return 1
  fi
  local domain
  domain=$(extract_domain_from_hostname "${target_hostname}")
  local template
  template=$(config_get_compose_template "${domain}") || return 1
  cp "$template" "$compose_file"
}

# Register/verify container mountpoints
# Idempotent: checks if mounts are correct before modifying
# Args: (none - uses $CTID and CT hostname from $CT_HOSTNAME or $HOSTNAME)
# Sets: DIR_DOCKER, DIR_DOCKER_DATA
setup_mountpoints() {
  echo "Registering mountpoints for CT ${CTID}..."

  local target_hostname="${CT_HOSTNAME:-${HOSTNAME:-}}"
  if [[ -z "$target_hostname" ]]; then
    echo "ERROR: No hostname available for setup_mountpoints"
    return 1
  fi

  local hostname_lower
  hostname_lower=$(echo "$target_hostname" | tr '[:upper:]' '[:lower:]')

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

  # Idempotent mount setup: only reconfigure if mounts are missing or incorrect
  echo "Verifying bind mounts..."
  
  local current_mp0 current_mp1 needs_update=0
  local config_output
  config_output=$(pct config "$CTID" 2>/dev/null)
  
  # Extract current mp0 and mp1 paths (format: mp0: /path/on/host,mp=/path/in/ct)
  # `|| true`: a fresh CT has no mp lines, so grep exits 1; under `set -euo pipefail`
  # the bare assignment would abort the script before the mounts are ever added.
  current_mp0=$(echo "$config_output" | grep -E '^mp0:' | sed -E 's/^mp0:\s*([^,]+),.*/\1/') || true
  current_mp1=$(echo "$config_output" | grep -E '^mp1:' | sed -E 's/^mp1:\s*([^,]+),.*/\1/') || true
  
  # Check if mounts are correct
  if [[ "$current_mp0" != "$DIR_DOCKER" ]] || [[ "$current_mp1" != "$DIR_DOCKER_DATA" ]]; then
    needs_update=1
  fi
  
  if [[ $needs_update -eq 1 ]]; then
    echo "Mountpoints need update (expected: mp0=$DIR_DOCKER, mp1=$DIR_DOCKER_DATA)"
    echo "Current: mp0=$current_mp0, mp1=$current_mp1"
    
    # Remove all existing mountpoints to avoid conflicts
    echo "Removing existing mountpoints..."
    for mp in $(echo "$config_output" | awk -F: '/^mp[0-9]+/ {print $1}'); do
      echo "  deleting $mp"
      pct set "$CTID" -delete "$mp"
    done
    
    # Add correct mounts
    echo "Adding correct bind mounts..."
    pct set "$CTID" -mp0 "${DIR_DOCKER},mp=/mnt/docker"
    pct set "$CTID" -mp1 "${DIR_DOCKER_DATA},mp=/mnt/docker-data"
    echo "Mountpoints updated."
  else
    echo "Mountpoints already correct:"
    echo "  mp0: $current_mp0 → /mnt/docker"
    echo "  mp1: $current_mp1 → /mnt/docker-data"
    echo "No changes needed."
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
