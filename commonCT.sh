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
#   reconcile_ct_gpu_config  Reconcile runtime-discovered DRM passthrough
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
#   CT_TAGS                Associative array: CTID -> semicolon-separated tags
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
declare -A CT_NODE
declare -A CT_TAGS
declare -a CT_LIST
CTID=""
CT_HOSTNAME=""

# Execute one argv-safe command on a Proxmox node. Lifecycle scripts are kept
# only on the administrative node; worker nodes need SSH and native PVE tools,
# but never a copy of this repository or commonCT.json.
run_on_node() {
  local node="${1:-}" argument quoted command=""
  shift || true
  [[ -n "$node" && $# -gt 0 ]] || {
    echo "ERROR: run_on_node requires a node and command." >&2
    return 1
  }
  if [[ "$node" == "$(hostname -s)" ]]; then
    "$@"
    return
  fi
  for argument in "$@"; do
    printf -v quoted '%q' "$argument"
    command+="${command:+ }${quoted}"
  done
  ssh -o BatchMode=yes -o ConnectTimeout=10 \
    -o ServerAliveInterval=5 -o ServerAliveCountMax=3 "$node" "$command"
}

run_node_shell() {
  local node="${1:-}" command="${2:-}"
  [[ -n "$node" && -n "$command" ]] || {
    echo "ERROR: run_node_shell requires a node and command." >&2
    return 1
  }
  if [[ "$node" == "$(hostname -s)" ]]; then
    sh -c "$command"
  else
    ssh -o BatchMode=yes -o ConnectTimeout=10 \
      -o ServerAliveInterval=5 -o ServerAliveCountMax=3 "$node" "$command"
  fi
}

online_cluster_nodes() {
  pvesh get /nodes --output-format json 2>/dev/null \
    | jq -r '.[] | select(.status == "online") | .node' \
    | sort
}

# Resolve a CT owner. Cached inventory is preferred, but an existing CT is
# never silently treated as local when inventory has not yet been built.
get_ct_owner_node() {
  local ctid="${1:-${CTID:-}}" resources node
  [[ "$ctid" =~ ^[1-9][0-9]*$ ]] || {
    echo "ERROR: A numeric CTID is required to resolve its owner." >&2
    return 1
  }
  if [[ -n "${CT_NODE[$ctid]:-}" ]]; then
    printf '%s\n' "${CT_NODE[$ctid]}"
    return 0
  fi
  resources=$(pvesh get /cluster/resources --type vm --output-format json 2>/dev/null) || {
    echo "ERROR: Cannot query cluster resources for CT ${ctid}." >&2
    return 1
  }
  node=$(jq -r --argjson id "$ctid" \
    '[.[] | select(.type == "lxc" and .vmid == $id) | .node] | if length == 1 then .[0] else empty end' \
    <<< "$resources")
  [[ -n "$node" ]] || {
    echo "ERROR: Cannot resolve exactly one owner for CT ${ctid}." >&2
    return 1
  }
  CT_NODE["$ctid"]="$node"
  printf '%s\n' "$node"
}

ct_pct() {
  local ctid="${1:-}" subcommand="${2:-}" node
  shift 2 || true
  [[ "$ctid" =~ ^[1-9][0-9]*$ && -n "$subcommand" ]] || {
    echo "ERROR: ct_pct requires a CTID and pct subcommand." >&2
    return 1
  }
  node=$(get_ct_owner_node "$ctid") || return 1
  run_on_node "$node" pct "$subcommand" "$ctid" "$@"
}

pct_config() { ct_pct "$1" config; }
pct_status() { ct_pct "$1" status; }
pct_start() { ct_pct "$1" start "${@:2}"; }
pct_stop() { ct_pct "$1" stop "${@:2}"; }
pct_shutdown() { ct_pct "$1" shutdown "${@:2}"; }
pct_reboot() { ct_pct "$1" reboot "${@:2}"; }
pct_set() { ct_pct "$1" set "${@:2}"; }
pct_destroy() { ct_pct "$1" destroy "${@:2}"; }
pct_snapshot() { ct_pct "$1" snapshot "${@:2}"; }
pct_rollback() { ct_pct "$1" rollback "${@:2}"; }

node_path_exists() { run_on_node "$1" test -e "$2"; }
node_path_is_dir() { run_on_node "$1" test -d "$2"; }
node_path_is_file() { run_on_node "$1" test -f "$2"; }
node_path_is_symlink() { run_on_node "$1" test -L "$2"; }
node_mkdir() { run_on_node "$1" mkdir -p -- "${@:2}"; }
node_realpath() { run_on_node "$1" realpath -e -- "$2"; }
node_du() { run_on_node "$1" du -sh -- "$2"; }

node_download_file() {
  local node="${1:-}" remote_path="${2:-}" local_path="${3:-}"
  [[ -n "$node" && -n "$remote_path" && -n "$local_path" ]] || {
    echo "ERROR: node_download_file requires node, remote path, and local path." >&2
    return 1
  }
  if [[ "$node" == "$(hostname -s)" ]]; then
    cp -a -- "$remote_path" "$local_path"
  else
    ssh -o BatchMode=yes -o ConnectTimeout=10 "$node" cat -- "$remote_path" > "$local_path"
  fi
}

node_upload_file() {
  local node="${1:-}" local_path="${2:-}" remote_path="${3:-}" mode="${4:-0600}"
  local quoted_path quoted_mode command
  [[ -n "$node" && -f "$local_path" && -n "$remote_path" && "$mode" =~ ^0?[0-7]{3,4}$ ]] || {
    echo "ERROR: node_upload_file received invalid arguments." >&2
    return 1
  }
  if [[ "$node" == "$(hostname -s)" ]]; then
    install -D -o root -g root -m "$mode" "$local_path" "$remote_path"
    return
  fi
  printf -v quoted_path '%q' "$remote_path"
  printf -v quoted_mode '%q' "$mode"
  command="set -eu; target=${quoted_path}; tmp=\"\${target}.tmp.\$$\"; umask 077; mkdir -p -- \"\$(dirname -- \"\$target\")\"; cat > \"\$tmp\"; chmod ${quoted_mode} \"\$tmp\"; chown root:root \"\$tmp\"; mv -f -- \"\$tmp\" \"\$target\""
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$node" "$command" < "$local_path"
}

ct_upload_file() {
  local ctid="${1:-}" local_path="${2:-}" ct_path="${3:-}" mode="${4:-0600}"
  local node source_on_node ct_temporary host_temporary
  [[ "$ctid" =~ ^[1-9][0-9]*$ && -f "$local_path" && "$ct_path" == /* && "$mode" =~ ^0?[0-7]{3,4}$ ]] || {
    echo "ERROR: ct_upload_file received invalid arguments." >&2
    return 1
  }
  node=$(get_ct_owner_node "$ctid") || return 1
  source_on_node="$local_path"
  host_temporary=""
  if [[ "$node" != "$(hostname -s)" ]]; then
    host_temporary="/tmp/ct-upload-${ctid}-$$"
    node_upload_file "$node" "$local_path" "$host_temporary" 0600 || return 1
    source_on_node="$host_temporary"
  fi
  ct_temporary="${ct_path}.tmp.$$"
  if ! run_on_node "$node" pct push "$ctid" "$source_on_node" "$ct_temporary" \
    -perms "$mode" -user 0 -group 0; then
    [[ -z "$host_temporary" ]] || run_on_node "$node" rm -f -- "$host_temporary" || true
    return 1
  fi
  if ! run_on_node "$node" pct exec "$ctid" -- mv -f -- "$ct_temporary" "$ct_path"; then
    run_on_node "$node" pct exec "$ctid" -- rm -f -- "$ct_temporary" || true
    [[ -z "$host_temporary" ]] || run_on_node "$node" rm -f -- "$host_temporary" || true
    return 1
  fi
  [[ -z "$host_temporary" ]] || run_on_node "$node" rm -f -- "$host_temporary"
}

node_sync_tree() {
  local node="${1:-}" local_dir="${2:-}" remote_dir="${3:-}" quoted_dir
  [[ -n "$node" && -d "$local_dir" && -n "$remote_dir" ]] || {
    echo "ERROR: node_sync_tree received invalid arguments." >&2
    return 1
  }
  if [[ "$node" == "$(hostname -s)" ]]; then
    rm -rf -- "$remote_dir"
    mkdir -p -- "$remote_dir"
    cp -a "${local_dir}/." "$remote_dir/"
    return
  fi
  printf -v quoted_dir '%q' "$remote_dir"
  tar -C "$local_dir" -cf - . | ssh -o BatchMode=yes -o ConnectTimeout=10 "$node" \
    "set -eu; rm -rf -- ${quoted_dir}; mkdir -p -- ${quoted_dir}; tar -C ${quoted_dir} -xf -"
}

node_fetch_tree() {
  local node="${1:-}" remote_dir="${2:-}" local_dir="${3:-}" quoted_dir
  [[ -n "$node" && -n "$remote_dir" && -n "$local_dir" ]] || {
    echo "ERROR: node_fetch_tree received invalid arguments." >&2
    return 1
  }
  rm -rf -- "$local_dir"
  mkdir -p -- "$local_dir"
  if [[ "$node" == "$(hostname -s)" ]]; then
    cp -a "${remote_dir}/." "$local_dir/"
    return
  fi
  printf -v quoted_dir '%q' "$remote_dir"
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$node" \
    "set -eu; tar -C ${quoted_dir} -cf - ." | tar -C "$local_dir" -xf -
}

node_remove_tree() {
  local node="${1:-}" path="${2:-}" expected="${3:-}" canonical
  if [[ "$path" != "$expected" ]] \
      || [[ "$path" != /mnt/docker/?* && "$path" != /mnt/docker-data/?* ]]; then
    echo "ERROR: Refusing unsafe node cleanup path '${node}:${path}'." >&2
    return 1
  fi
  node_path_exists "$node" "$path" || return 0
  if node_path_is_symlink "$node" "$path"; then
    echo "ERROR: Refusing symlink cleanup path '${node}:${path}'." >&2
    return 1
  fi
  canonical=$(node_realpath "$node" "$path") || return 1
  [[ "$canonical" == "$expected" ]] || {
    echo "ERROR: Cleanup path drifted on ${node}: expected '${expected}', found '${canonical}'." >&2
    return 1
  }
  run_on_node "$node" rm -rf --one-file-system -- "$path"
}

# Status bar state
STATUS_BAR_ENABLED=false
STATUS_BAR_TEXT=""

# Lifecycle run-log state
LIFECYCLE_LOG_ACTIVE=false
LIFECYCLE_LOG_STOPPED=false
RUN_LOG_FILE=""
RUN_LOG_STARTED_AT=""
RUN_LOG_STARTED_EPOCH=""
RUN_LOG_TEE_PID=""

redact_lifecycle_args() {
  local redact_next=false arg name
  for arg in "$@"; do
    if [[ "$redact_next" == "true" ]]; then
      printf ' %q' 'REDACTED'
      redact_next=false
      continue
    fi
    name="${arg%%=*}"
    if [[ "$arg" == *=* && "${name,,}" =~ (password|passwd|token|secret|apikey|api-key) ]]; then
      printf ' %q' "${name}=REDACTED"
    elif [[ "${arg,,}" =~ ^--?(password|passwd|token|secret|apikey|api-key)$ ]]; then
      printf ' %q' "$arg"
      redact_next=true
    else
      printf ' %q' "$arg"
    fi
  done
}

lifecycle_log_init() {
  local script_path="${1:-}" script_name log_dir arguments
  shift || true
  [[ "$LIFECYCLE_LOG_ACTIVE" != "true" ]] || return 0
  [[ -n "$script_path" ]] || { echo "ERROR: Lifecycle logger requires a script path." >&2; return 1; }
  script_name=$(basename "$script_path" .sh)
  log_dir="${LIFECYCLE_LOG_DIR:-${SCRIPT_DIR}/logs}"
  RUN_LOG_FILE="${log_dir}/${script_name}.log"
  (
    umask 077
    mkdir -p "$log_dir" || { echo "ERROR: Cannot create lifecycle log directory: ${log_dir}" >&2; exit 1; }
    chmod 0700 "$log_dir" || { echo "ERROR: Cannot secure lifecycle log directory: ${log_dir}" >&2; exit 1; }
    : > "$RUN_LOG_FILE" || { echo "ERROR: Cannot create lifecycle log: ${RUN_LOG_FILE}" >&2; exit 1; }
    chmod 0600 "$RUN_LOG_FILE" || { echo "ERROR: Cannot secure lifecycle log: ${RUN_LOG_FILE}" >&2; exit 1; }
  ) || return 1
  exec 8>&1 9>&2
  exec > >(tee -a "$RUN_LOG_FILE" >&8) 2>&1
  RUN_LOG_TEE_PID=$!
  LIFECYCLE_LOG_ACTIVE=true
  LIFECYCLE_LOG_STOPPED=false
  RUN_LOG_STARTED_AT=$(date -Is)
  RUN_LOG_STARTED_EPOCH=$(date +%s)
  arguments=$(redact_lifecycle_args "$@")
  printf '=== lifecycle run start ===\n'
  printf 'started=%s script=%s host=%s pid=%s cwd=%q\n' \
    "$RUN_LOG_STARTED_AT" "$script_name" "$(hostname -s)" "$$" "$PWD"
  printf 'arguments:%s\n' "$arguments"
  printf 'log=%s\n' "$RUN_LOG_FILE"
  trap 'lifecycle_signal_handler HUP 129' HUP
  trap 'lifecycle_signal_handler INT 130' INT
  trap 'lifecycle_signal_handler TERM 143' TERM
}

lifecycle_log_stop() {
  local exit_code="${1:-0}" ended_epoch duration
  [[ "$LIFECYCLE_LOG_ACTIVE" == "true" && "$LIFECYCLE_LOG_STOPPED" != "true" ]] || return 0
  ended_epoch=$(date +%s)
  duration=$((ended_epoch - RUN_LOG_STARTED_EPOCH))
  printf '=== lifecycle run end ===\n'
  printf 'ended=%s exit_status=%s duration_seconds=%s\n' "$(date -Is)" "$exit_code" "$duration"
  exec 1>&8 2>&9
  exec 8>&- 9>&-
  if [[ -n "$RUN_LOG_TEE_PID" ]]; then
    wait "$RUN_LOG_TEE_PID" 2>/dev/null || true
  fi
  RUN_LOG_TEE_PID=""
  LIFECYCLE_LOG_ACTIVE=false
  LIFECYCLE_LOG_STOPPED=true
}

lifecycle_exit_handler() {
  local exit_code=$?
  trap - EXIT
  status_bar_cleanup || true
  lifecycle_log_stop "$exit_code" || true
  exit "$exit_code"
}

lifecycle_signal_handler() {
  local signal="${1:-UNKNOWN}" exit_code="${2:-1}"
  trap - HUP INT TERM
  printf 'signal=%s\n' "$signal"
  exit "$exit_code"
}

# -----------------------------
# STATUS BAR FUNCTIONS
# -----------------------------

# Initialize status bar (reserves bottom line of terminal)
# Call this before starting operations that use status_update
status_bar_init() {
  local output_fd=1
  [[ "$LIFECYCLE_LOG_ACTIVE" == "true" ]] && output_fd=8
  [[ -t "$output_fd" ]] || { STATUS_BAR_ENABLED=false; return 0; }
  STATUS_BAR_ENABLED=true
  local rows
  rows=$(tput lines)
  # Clear screen first
  clear >&"$output_fd"
  # Set scroll region to exclude last line
  printf '\e[1;%dr' "$((rows-1))" >&"$output_fd"
  # Move cursor to top-left of scroll region
  printf '\e[1;1H' >&"$output_fd"
  # Clear the status line and set initial text
  printf '\e[%d;1H\e[0;7m Starting...\e[K\e[0m' "$rows" >&"$output_fd"
  # Move cursor back to scroll region
  printf '\e[1;1H' >&"$output_fd"
}

# Update the status bar text
# Args: $1 = status text
status_update() {
  [[ "$STATUS_BAR_ENABLED" != "true" ]] && return
  local output_fd=1
  [[ "$LIFECYCLE_LOG_ACTIVE" == "true" ]] && output_fd=8
  STATUS_BAR_TEXT="$1"
  local rows cols
  rows=$(tput lines)
  cols=$(tput cols)
  # Truncate text if too long
  local text="${1:0:$((cols-2))}"
  # Save cursor, move to status line (outside scroll region), print, restore
  printf '\e7\e[%d;1H\e[0;7m %s\e[K\e[0m\e8' "$rows" "$text" >&"$output_fd"
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
    local output_fd=1
    [[ "$LIFECYCLE_LOG_ACTIVE" == "true" ]] && output_fd=8
    local rows
    rows=$(tput lines)
    # Restore full scroll region
    printf '\e[1;%dr' "$rows" >&"$output_fd"
    # Clear status line
    printf '\e[%d;1H\e[K' "$rows" >&"$output_fd"
    # Move cursor to bottom of restored region
    printf '\e[%d;1H' "$((rows-1))" >&"$output_fd"
    STATUS_BAR_ENABLED=false
  fi
}

# Trap to ensure terminal and lifecycle-log cleanup on exit.
trap lifecycle_exit_handler EXIT

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

# Read one required backup policy value using a jq expression.
config_get_backup_value() {
  local expression="${1:-}"
  [[ -n "$expression" ]] || return 1
  config_exists || return 1
  jq -er "$expression" "${CONFIG_FILE}" 2>/dev/null
}

config_get_backup_storage() { config_get_backup_value '.backup.storage'; }
config_get_backup_tmpdir() { config_get_backup_value '.backup.tmpdir'; }
config_get_backup_temp_storage_id() { config_get_backup_value '.backup.temp_storage.storage_id'; }
config_get_backup_temp_vg() { config_get_backup_value '.backup.temp_storage.vg'; }
config_get_backup_temp_thin_pool() { config_get_backup_value '.backup.temp_storage.thin_pool'; }
config_get_backup_temp_lv() { config_get_backup_value '.backup.temp_storage.lv'; }
config_get_backup_temp_filesystem() { config_get_backup_value '.backup.temp_storage.filesystem'; }
config_get_backup_temp_size_multiplier() { config_get_backup_value '.backup.temp_storage.size_multiplier'; }
config_get_backup_temp_headroom_percent() { config_get_backup_value '.backup.temp_storage.headroom_percent'; }
config_get_backup_mode() { config_get_backup_value '.backup.mode'; }
config_get_backup_schedule() { config_get_backup_value '.backup.schedule'; }
config_get_backup_repeat_missed() { config_get_backup_value '.backup.repeat_missed'; }
config_get_backup_compress() { config_get_backup_value '.backup.compress'; }
config_get_backup_keep_daily() { config_get_backup_value '.backup.retention.keep_daily'; }
config_get_backup_keep_weekly() { config_get_backup_value '.backup.retention.keep_weekly'; }
config_get_backup_keep_monthly() { config_get_backup_value '.backup.retention.keep_monthly'; }
config_get_backup_prune_policy() {
  printf 'keep-daily=%s,keep-weekly=%s,keep-monthly=%s\n' \
    "$(config_get_backup_keep_daily)" \
    "$(config_get_backup_keep_weekly)" \
    "$(config_get_backup_keep_monthly)"
}
config_get_backup_bwlimit_kib() { config_get_backup_value '.backup.bwlimit_kib'; }
config_get_backup_ionice() { config_get_backup_value '.backup.ionice'; }
config_get_backup_notification_mode() { config_get_backup_value '.backup.notification_mode'; }
config_get_backup_snapshot_headroom_percent() { config_get_backup_value '.backup.snapshot_headroom_percent'; }
config_get_backup_job_id() { config_get_backup_value '.backup.job_id'; }
config_get_backup_hook_path() { config_get_backup_value '.backup.hook_path'; }
config_get_backup_state_dir() { config_get_backup_value '.backup.state_dir'; }
config_get_backup_exclude_tags() { config_get_backup_value '.backup.exclude_tags | @json'; }
config_get_backup_vm_enabled() { config_get_backup_value '.backup.vm.enabled'; }
config_get_backup_vm_job_id() { config_get_backup_value '.backup.vm.job_id'; }
config_get_backup_vm_mode() { config_get_backup_value '.backup.vm.mode'; }
config_get_backup_vm_schedule() { config_get_backup_value '.backup.vm.schedule'; }
config_get_backup_vm_repeat_missed() { config_get_backup_value '.backup.vm.repeat_missed'; }
config_get_backup_vm_restore_storage() { config_get_backup_value '.backup.vm.restore_storage'; }

backup_resource_ids() {
  local resource_type="${1:-}" resources="${2:-}" exclude_tags
  [[ "$resource_type" == lxc || "$resource_type" == qemu ]] || {
    echo "ERROR: Backup resource type must be lxc or qemu." >&2
    return 1
  }
  exclude_tags=$(config_get_backup_exclude_tags) || return 1
  if [[ -z "$resources" ]]; then
    resources=$(pvesh get /cluster/resources --type vm --output-format json 2>/dev/null) || return 1
  fi
  jq -r --arg type "$resource_type" --argjson excluded "$exclude_tags" '
    [.[]
      | select(.type == $type)
      | select(((.tags // "") | split(";")) as $tags
          | all($excluded[]; . as $tag | ($tags | index($tag)) == null))
      | .vmid]
    | sort
    | map(tostring)
    | join(",")
  ' <<<"$resources"
}

validate_backup_config() {
  local errors
  config_exists || {
    echo "ERROR: Config file not found: ${CONFIG_FILE}" >&2
    return 1
  }

  if ! errors=$(jq -r '
    def required_string($path; $value):
      if ($value | type) != "string" or ($value | length) == 0 then $path + " must be a non-empty string" else empty end;
    def nonnegative_integer($path; $value):
      if ($value | type) != "number" or ($value | floor) != $value or $value < 0 then $path + " must be a non-negative integer" else empty end;
    def ranged_integer($path; $value; $minimum; $maximum):
      if ($value | type) != "number" or ($value | floor) != $value or $value < $minimum or $value > $maximum
      then $path + " must be an integer from " + ($minimum | tostring) + " to " + ($maximum | tostring) else empty end;
    [
      required_string("backup.storage"; .backup.storage),
      required_string("backup.tmpdir"; .backup.tmpdir),
      required_string("backup.temp_storage.storage_id"; .backup.temp_storage.storage_id),
      required_string("backup.temp_storage.vg"; .backup.temp_storage.vg),
      required_string("backup.temp_storage.thin_pool"; .backup.temp_storage.thin_pool),
      required_string("backup.temp_storage.lv"; .backup.temp_storage.lv),
      (if .backup.temp_storage.filesystem != "ext4" then "backup.temp_storage.filesystem must be ext4" else empty end),
      ranged_integer("backup.temp_storage.size_multiplier"; .backup.temp_storage.size_multiplier; 2; 10),
      ranged_integer("backup.temp_storage.headroom_percent"; .backup.temp_storage.headroom_percent; 1; 90),
      required_string("backup.schedule"; .backup.schedule),
      required_string("backup.job_id"; .backup.job_id),
      required_string("backup.hook_path"; .backup.hook_path),
      required_string("backup.state_dir"; .backup.state_dir),
      (if (.backup.exclude_tags | type) != "array" or (.backup.exclude_tags | length) == 0
        or any(.backup.exclude_tags[]; (type != "string") or length == 0 or test("^[A-Za-z0-9_][A-Za-z0-9_.-]*$") != true)
        then "backup.exclude_tags must be a non-empty array of valid tags" else empty end),
      (if (.backup.vm.enabled | type) != "boolean" then "backup.vm.enabled must be boolean" else empty end),
      required_string("backup.vm.job_id"; .backup.vm.job_id),
      (if .backup.vm.mode != "snapshot" then "backup.vm.mode must be snapshot" else empty end),
      required_string("backup.vm.schedule"; .backup.vm.schedule),
      (if (.backup.vm.repeat_missed | type) != "boolean" then "backup.vm.repeat_missed must be boolean" else empty end),
      required_string("backup.vm.restore_storage"; .backup.vm.restore_storage),
      (if .backup.vm.job_id == .backup.job_id then "backup.vm.job_id must differ from backup.job_id" else empty end),
      (if .backup.mode != "suspend" then "backup.mode must be suspend" else empty end),
      (if .backup.compress != "zstd" then "backup.compress must be zstd" else empty end),
      (if (.backup.repeat_missed | type) != "boolean" then "backup.repeat_missed must be boolean" else empty end),
      nonnegative_integer("backup.retention.keep_daily"; .backup.retention.keep_daily),
      nonnegative_integer("backup.retention.keep_weekly"; .backup.retention.keep_weekly),
      nonnegative_integer("backup.retention.keep_monthly"; .backup.retention.keep_monthly),
      nonnegative_integer("backup.bwlimit_kib"; .backup.bwlimit_kib),
      ranged_integer("backup.ionice"; .backup.ionice; 0; 8),
      (.backup.notification_mode as $notification_mode
        | if (["auto", "legacy-sendmail", "notification-system"] | index($notification_mode)) == null then "backup.notification_mode is invalid" else empty end),
      ranged_integer("backup.snapshot_headroom_percent"; .backup.snapshot_headroom_percent; 1; 90),
      (if (.backup.hook_path | startswith("/")) != true then "backup.hook_path must be absolute" else empty end),
      (if (.backup.tmpdir | startswith("/")) != true then "backup.tmpdir must be absolute" else empty end),
      (if (.backup.temp_storage.storage_id | test("^[A-Za-z0-9][A-Za-z0-9_-]*$")) != true then "backup.temp_storage.storage_id contains unsupported characters" else empty end),
      (if (.backup.temp_storage.vg | test("^[A-Za-z0-9_+.-]+$")) != true then "backup.temp_storage.vg contains unsupported characters" else empty end),
      (if (.backup.temp_storage.thin_pool | test("^[A-Za-z0-9_+.-]+$")) != true then "backup.temp_storage.thin_pool contains unsupported characters" else empty end),
      (if (.backup.temp_storage.lv | test("^[A-Za-z0-9_+.-]+$")) != true then "backup.temp_storage.lv contains unsupported characters" else empty end),
      (if (.backup.state_dir | startswith("/")) != true then "backup.state_dir must be absolute" else empty end),
      (if (.backup.job_id | test("^[A-Za-z0-9][A-Za-z0-9_-]*$")) != true then "backup.job_id contains unsupported characters" else empty end),
      (if (.backup.vm.job_id | test("^[A-Za-z0-9][A-Za-z0-9_-]*$")) != true then "backup.vm.job_id contains unsupported characters" else empty end),
      (if (.backup.vm.restore_storage | test("^[A-Za-z0-9][A-Za-z0-9_-]*$")) != true then "backup.vm.restore_storage contains unsupported characters" else empty end)
    ] | .[]' "${CONFIG_FILE}" 2>&1); then
    echo "ERROR: Cannot parse backup policy in ${CONFIG_FILE}: ${errors}" >&2
    return 1
  fi

  if [[ -n "$errors" ]]; then
    echo "ERROR: Invalid backup policy in ${CONFIG_FILE}:" >&2
    sed 's/^/  - /' <<< "$errors" >&2
    return 1
  fi
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

# Get telemetry OTLP gRPC port
# Returns: port number or empty
config_get_telemetry_otlp_grpc_port() {
  if ! config_exists; then
    return 1
  fi
  jq -r '.telemetry.otlp_grpc_port // empty' "${CONFIG_FILE}" 2>/dev/null
}

# Get telemetry OTLP HTTP port (OTLP/HTTP exporter endpoint, distinct from gRPC otlp_grpc_port)
# Returns: port number or empty
config_get_telemetry_otlp_http_port() {
  if ! config_exists; then
    return 1
  fi
  jq -r '.telemetry.otlp_http_port // empty' "${CONFIG_FILE}" 2>/dev/null
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

# Release the UDM Pro fixed-IP reservation AND local DNS record for a CT.
# Used when a CT's VLAN changes: the old reservation pins an address on the
# previous VLAN's subnet, which prevents a clean DHCP lease on the new VLAN.
# Clearing it BEFORE the reboot lets the CT pull a fresh lease; check_dns_health
# then re-pins the fixed IP + local DNS with the new IP after the reboot.
#
# Idempotent (safe to run when nothing needs releasing).
# Args: $1 - CTID (defaults to $CTID)
# Returns: 0 when there is nothing to release or the release succeeds;
#          1 only on a genuine failure (no MAC, API query error, or PUT failure).
udmpro_release_fixedip() {
  local ctid="${1:-${CTID}}"

  if ! config_udmpro_configured; then
    echo "  [i] UDM Pro not configured; nothing to release"
    return 0
  fi

  # MAC identifies the client across a VLAN change (the CT keeps its MAC).
  local ct_mac
  if ! ct_mac=$(get_ct_mac "${ctid}"); then
    echo "  [!] Could not get MAC from CT ${ctid}"
    return 1
  fi

  local udm_host udm_apikey
  udm_host=$(config_get_udmpro_host)
  udm_apikey=$(config_get_udmpro_apikey)

  echo "  Releasing UDM Pro fixed IP + local DNS for MAC ${ct_mac}..."

  local all_clients
  all_clients=$(curl -sk -H "X-API-KEY: ${udm_apikey}" \
    "https://${udm_host}/proxy/network/api/s/default/rest/user" 2>/dev/null || true)

  if [[ -z "$all_clients" ]] || ! echo "$all_clients" | jq -e '.data' >/dev/null 2>&1; then
    echo "  [!] Failed to query UDM Pro API"
    return 1
  fi

  local client_id
  client_id=$(echo "$all_clients" | jq -r --arg mac "$ct_mac" \
    '.data[] | select((.mac | ascii_downcase) == $mac) | ._id' 2>/dev/null | head -1 || true)

  if [[ -z "$client_id" || "$client_id" == "null" ]]; then
    echo "  [i] No UDM Pro client for MAC ${ct_mac}; nothing to release"
    return 0
  fi

  # Idempotent no-op: skip the PUT when the reservation is already fully cleared.
  local needs_release
  needs_release=$(echo "$all_clients" | jq -r --arg id "$client_id" \
    '.data[] | select(._id == $id)
       | ((.use_fixedip == true)
          or (.local_dns_record_enabled == true)
          or ((.local_dns_record // "") != ""))' 2>/dev/null || echo "true")
  if [[ "$needs_release" != "true" ]]; then
    echo "  [i] UDM Pro fixed IP + local DNS already cleared for ${ct_mac}"
    return 0
  fi

  local release_result
  release_result=$(curl -sk -X PUT -H "X-API-KEY: ${udm_apikey}" -H "Content-Type: application/json" \
    "https://${udm_host}/proxy/network/api/s/default/rest/user/${client_id}" \
    -d '{"use_fixedip": false, "fixed_ip": "", "local_dns_record_enabled": false, "local_dns_record": ""}' 2>/dev/null || true)

  if echo "$release_result" | jq -e '.meta.rc == "ok"' >/dev/null 2>&1; then
    echo "  [✓] UDM Pro fixed IP + local DNS released"
    return 0
  fi

  local error_msg
  error_msg=$(echo "$release_result" | jq -r '.meta.msg // "unknown error"' 2>/dev/null || echo "unknown error")
  echo "  [!] Failed to release fixed IP: ${error_msg}"
  return 1
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

  if [[ "${ct_hostname}" =~ ^ca\. ]]; then
    echo "Skipping Telegraf for CA host."
    return
  fi

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

  local otlp_grpc_port
  otlp_grpc_port=$(config_get_telemetry_otlp_grpc_port)
  local domain
  domain=$(extract_domain_from_hostname "${ct_hostname}")

  echo "Configuring Telegraf metrics collection..."
  echo "  Metrics target: ${telemetry_host}:${otlp_grpc_port}"

  local telegraf_installed
  telegraf_installed=$(ct_exec --timeout 15 'command -v telegraf >/dev/null 2>&1 && echo "yes" || echo "no"')
  if [[ "$telegraf_installed" != "yes" ]]; then
    echo "  Installing telegraf..."
    ct_exec --timeout 120 'apk add --no-cache telegraf'
  else
    echo "  Telegraf already installed"
  fi

  local in_docker_group
  in_docker_group=$(ct_exec --timeout 15 'groups telegraf 2>/dev/null | grep -q docker && echo "yes" || echo "no"')
  if [[ "$in_docker_group" != "yes" ]]; then
    echo "  Adding telegraf user to docker group..."
    ct_exec --timeout 15 'adduser telegraf docker 2>/dev/null || true'
  fi

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
  service_address = \"${telemetry_host}:${otlp_grpc_port}\"
  [outputs.opentelemetry.attributes]
    \"service.name\" = \"${ct_hostname}\"
    \"service.namespace\" = \"${domain}\"

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

[[inputs.docker]]
  endpoint = \"unix:///var/run/docker.sock\"
  gather_services = false
  timeout = \"5s\"
"

  ct_exec --timeout 30 "
    mkdir -p /etc/telegraf
    cat > /etc/telegraf/telegraf.conf << 'TELEGRAF_EOF'
${telegraf_conf}
TELEGRAF_EOF
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
    ct_exec "${CTID}" 'cat > /usr/local/bin/arping-gw.sh << '"'"'SCRIPT'"'"'
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
  local i recovery_output=""

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
  ct_exec --timeout 15 "${ctid}" \
    'if [ -f /var/log/docker.log ]; then cp /var/log/docker.log /var/log/docker.log.pre-recovery; : > /var/log/docker.log; fi' \
    >/dev/null 2>&1 || true
  if ! recovery_output=$(ct_exec --timeout 60 "${ctid}" \
    'rc-service docker restart 2>&1 || rc-service docker start 2>&1' 2>&1); then
    echo "  [!] OpenRC could not restart Docker:"
    printf '%s\n' "$recovery_output" | sed 's/^/        /'
  fi

  for ((i=1; i<=timeout; i++)); do
    if ct_exec --timeout 10 "${ctid}" 'docker info >/dev/null 2>&1' 2>/dev/null; then
      echo "  [✓] Docker daemon recovered and is running"
      return 0
    fi
    sleep 1
  done

  echo "  [✗] Docker daemon FAILED to start in CT ${ctid} after recovery attempt"
  if [[ -n "$recovery_output" ]]; then
    echo "      OpenRC recovery output:"
    printf '%s\n' "$recovery_output" | sed 's/^/        /'
  fi
  echo "      Docker service status and recent log:"
  ct_exec --timeout 30 "${ctid}" \
    'rc-service docker status 2>&1 || true; tail -n 40 /var/log/docker.log 2>/dev/null || true' \
    | sed 's/^/        /' || true
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
  ct_exec "${ctid}" 'cat > /etc/init.d/docker-watchdog << '"'"'WATCHDOG'"'"'
#!/sbin/openrc-run

description="Retry Docker startup at boot until the daemon is responsive"

depend() {
    after docker
}

start() {
    ebegin "Verifying Docker daemon is responsive"
    i=0
  max=3
    while [ "$i" -lt "$max" ]; do
        if docker info >/dev/null 2>&1; then
            eend 0
            return 0
        fi
        i=$((i + 1))
    ewarn "Docker not responsive (attempt $i/$max) - restarting docker"
    rc-service docker restart >/dev/null 2>&1 || rc-service docker start >/dev/null 2>&1 || true
    waited=0
    while [ "$waited" -lt 60 ]; do
      if docker info >/dev/null 2>&1; then
        eend 0
        return 0
      fi
      sleep 5
      waited=$((waited + 5))
    done
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
apply_ct_configuration() {
  local ctid="${1:-${CTID}}"
  local hostname="${2:-${CT_HOSTNAME:-${HOSTNAME}}}"

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
}

# Delete the per-host Authentik forward-auth application + provider combo.
# Shared first step for forwardAuthCT.sh --remove (delete only) and --reset (delete then
# recreate). Prompts for confirmation when an existing application is found; idempotent
# no-op (no prompt) when nothing exists. Also detaches the provider from the configured
# outpost before deletion so no dangling reference is left behind.
# Args:
#   $1 - CT hostname (e.g. pdf.thesaints.home)
# Returns: 0 if deleted or nothing to delete; 1 on error or user decline.
delete_authentik_forward_auth() {
  local ct_hostname="${1:-${CT_HOSTNAME:-${HOSTNAME}}}"

  if ! config_authentik_configured; then
    echo "  [!] Authentik not configured (missing host or apitoken in commonCT.json)"
    return 0
  fi

  local ak_host ak_token ak_outpost
  ak_host=$(config_get_authentik_host)
  ak_token=$(config_get_authentik_token)
  ak_outpost=$(config_get_authentik_outpost)
  local ak_api="https://${ak_host}/api/v3"

  local app_host slug
  app_host=$(echo "$ct_hostname" | tr '[:upper:]' '[:lower:]')
  slug=$(echo "$app_host" | tr '.' '-')

  ak_get() {
    curl -sk --connect-timeout 10 --max-time 60 -H "Authorization: Bearer ${ak_token}" -H "Accept: application/json" \
      "${ak_api}${1}" 2>/dev/null
  }
  ak_patch() {
    curl -sk --connect-timeout 10 --max-time 60 -X PATCH -H "Authorization: Bearer ${ak_token}" \
      -H "Content-Type: application/json" -H "Accept: application/json" \
      "${ak_api}${1}" -d "${2}" 2>/dev/null
  }
  ak_delete() {
    curl -sk --connect-timeout 10 --max-time 60 -X DELETE -o /dev/null -w '%{http_code}' \
      -H "Authorization: Bearer ${ak_token}" "${ak_api}${1}" 2>/dev/null
  }

  local existing_app existing_app_pk existing_provider_pk
  existing_app=$(ak_get "/core/applications/?slug=${slug}")
  existing_app_pk=$(echo "$existing_app" | jq -r --arg s "$slug" '.results[] | select(.slug == $s) | .pk // empty' 2>/dev/null)
  existing_provider_pk=$(echo "$existing_app" | jq -r --arg s "$slug" '.results[] | select(.slug == $s) | .provider // empty' 2>/dev/null)

  if [[ -z "$existing_app_pk" ]]; then
    echo "  [✓] Authentik: no application '${slug}' to delete"
    return 0
  fi

  local prov_label="none"
  if [[ -n "$existing_provider_pk" ]]; then
    prov_label=$(ak_get "/providers/all/${existing_provider_pk}/" | \
      jq -r '((.verbose_name // .meta_model_name // "provider")|tostring) + " (pk=" + (.pk|tostring) + ")"' 2>/dev/null)
    [[ -z "$prov_label" || "$prov_label" == null* ]] && prov_label="provider pk=${existing_provider_pk}"
  fi

  echo "  [!] Existing Authentik application for '${app_host}':"
  echo "        application: slug=${slug} pk=${existing_app_pk}"
  echo "        provider:    ${prov_label}"
  printf "  [?] Delete this Authentik application/provider combo? [y/N] "
  local reply=""
  read -r reply
  if [[ ! "$reply" =~ ^[Yy]$ ]]; then
    echo "  [!] Deletion declined — leaving existing Authentik objects unchanged."
    return 1
  fi

  # Detach the provider from the configured outpost (best-effort) so deletion is clean.
  if [[ -n "$existing_provider_pk" && -n "$ak_outpost" ]]; then
    local op_res op_uuid op_providers op_new
    op_res=$(ak_get "/outposts/instances/?name__iexact=$(printf '%s' "$ak_outpost" | jq -sRr @uri)")
    op_uuid=$(echo "$op_res" | jq -r '.results[0].pk // empty' 2>/dev/null)
    if [[ -n "$op_uuid" ]]; then
      op_providers=$(echo "$op_res" | jq -r '[.results[0].providers[]]' 2>/dev/null)
      if echo "$op_providers" | jq -e --argjson pk "$existing_provider_pk" 'index($pk) != null' >/dev/null 2>&1; then
        op_new=$(echo "$op_providers" | jq --argjson pk "$existing_provider_pk" 'map(select(. != $pk))')
        ak_patch "/outposts/instances/${op_uuid}/" "$(jq -n --argjson p "$op_new" '{providers:$p}')" >/dev/null 2>&1
        echo "    Detached provider from outpost '${ak_outpost}'"
      fi
    fi
  fi

  # Delete the application first (it references the provider), then the provider.
  local del_code
  del_code=$(ak_delete "/core/applications/${slug}/")
  if [[ "$del_code" =~ ^2 ]]; then
    echo "    Deleted application '${slug}' (HTTP ${del_code})"
  else
    echo "  [!] Failed to delete application '${slug}' (HTTP ${del_code})"
    return 1
  fi
  if [[ -n "$existing_provider_pk" ]]; then
    del_code=$(ak_delete "/providers/all/${existing_provider_pk}/")
    if [[ "$del_code" =~ ^2 ]]; then
      echo "    Deleted provider pk=${existing_provider_pk} (HTTP ${del_code})"
    else
      echo "  [!] Failed to delete provider pk=${existing_provider_pk} (HTTP ${del_code}) — continuing"
    fi
  fi
  echo "  [✓] Authentik application/provider for '${app_host}' deleted"
  return 0
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
  local reset_existing="${2:-false}"

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

  # Step 1: If --reset, delete any existing app/provider combo first (shared step with
  # --remove; prompts for confirmation). Otherwise, skip when the host application already
  # has a provider attached.
  if [[ "$reset_existing" == "true" ]]; then
    delete_authentik_forward_auth "$ct_hostname" || return 1
  fi

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

# Emit a machine-readable description of local DRM capability.
probe_local_gpu_capability() {
  local pci_gpu=false class_file class_value device major_hex gid
  local pci_root="${GPU_PCI_ROOT:-/sys/bus/pci/devices}"
  local dri_root="${GPU_DRI_ROOT:-/dev/dri}"
  local render_devices=()

  for class_file in "$pci_root"/*/class; do
    [[ -r "$class_file" ]] || continue
    read -r class_value < "$class_file" || continue
    if [[ "$class_value" == 0x03* ]]; then
      pci_gpu=true
      break
    fi
  done

  shopt -s nullglob
  render_devices=("$dri_root"/renderD*)
  shopt -u nullglob

  if [[ ${#render_devices[@]} -eq 0 ]]; then
    [[ "$pci_gpu" == "true" ]] && echo "STATE broken" || echo "STATE absent"
    return 0
  fi

  for device in "${render_devices[@]}"; do
    [[ -c "$device" ]] || { echo "STATE broken"; return 0; }
    major_hex=$(stat -c '%t' "$device" 2>/dev/null || true)
    if [[ ! "$major_hex" =~ ^[0-9a-fA-F]+$ ]] || (( 16#$major_hex != 226 )); then
      echo "STATE broken"
      return 0
    fi
  done

  echo "STATE available"
  for device in "${render_devices[@]}"; do
    gid=$(stat -c '%g' "$device" 2>/dev/null || true)
    [[ -n "$gid" ]] || { echo "STATE broken"; return 0; }
    echo "DEVICE ${device} ${gid}"
  done
}

# Sets NODE_GPU_STATE and NODE_GPU_RENDER_DEVICES/NODE_GPU_RENDER_GIDS.
detect_node_gpu_capability() {
  local node="${1:-$(hostname -s)}"
  local local_node probe state="" key device gid
  local_node=$(hostname -s)
  NODE_GPU_STATE="indeterminate"
  NODE_GPU_RENDER_DEVICES=()
  NODE_GPU_RENDER_GIDS=()

  if [[ "$node" == "$local_node" ]]; then
    probe=$(probe_local_gpu_capability) || return 1
  else
    probe=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$node" \
      "$(declare -f probe_local_gpu_capability); probe_local_gpu_capability" 2>/dev/null) || {
      echo "ERROR: Cannot discover GPU capability on node '${node}'." >&2
      return 1
    }
  fi

  while read -r key device gid; do
    case "$key" in
      STATE) state="$device" ;;
      DEVICE)
        NODE_GPU_RENDER_DEVICES+=("$device")
        NODE_GPU_RENDER_GIDS+=("$gid")
        ;;
    esac
  done <<< "$probe"

  case "$state" in
    available)
      [[ ${#NODE_GPU_RENDER_DEVICES[@]} -gt 0 ]] || return 1
      NODE_GPU_STATE="available"
      ;;
    absent) NODE_GPU_STATE="absent" ;;
    broken)
      NODE_GPU_STATE="broken"
      echo "ERROR: Node '${node}' has GPU hardware but no usable DRM render device." >&2
      return 1
      ;;
    *)
      echo "ERROR: GPU capability on node '${node}' is indeterminate." >&2
      return 1
      ;;
  esac
}

ct_managed_gpu_disabled() {
  local ctid="$1"
  local target_hostname="${2:-${CT_HOSTNAME:-}}"
  local node marker
  [[ -n "$target_hostname" ]] || target_hostname="${CT_MAP[$ctid]:-}"
  [[ "$target_hostname" == ca.* ]] && return 0
  [[ -n "$target_hostname" ]] || return 1
  node=$(get_ct_owner_node "$ctid") || return 1
  marker="/mnt/docker/${target_hostname}/_config/disable-managed-gpu"
  node_path_is_file "$node" "$marker"
}

resolve_ct_gpu_capability() {
  local ctid="$1"
  local node="$2"
  if ct_managed_gpu_disabled "$ctid"; then
    NODE_GPU_STATE="absent"
    NODE_GPU_RENDER_DEVICES=()
    NODE_GPU_RENDER_GIDS=()
  else
    detect_node_gpu_capability "$node"
  fi
}

ct_gpu_config_matches_capability() {
  local ctid="$1"
  local config_file="/etc/pve/lxc/${ctid}.conf"
  local node has_allow=false has_mount=false
  node=$(get_ct_owner_node "$ctid") || return 1
  run_on_node "$node" grep -Fxq 'lxc.cgroup2.devices.allow: c 226:* rwm' "$config_file" 2>/dev/null && has_allow=true
  run_on_node "$node" grep -Fxq 'lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir' "$config_file" 2>/dev/null && has_mount=true

  if [[ "$NODE_GPU_STATE" == "available" ]] && ! ct_managed_gpu_disabled "$ctid"; then
    [[ "$has_allow" == "true" && "$has_mount" == "true" ]]
  else
    [[ "$has_allow" == "false" && "$has_mount" == "false" ]]
  fi
}

reconcile_stopped_ct_gpu_config() {
  local ctid="$1"
  local config_file="/etc/pve/lxc/${ctid}.conf"
  local node
  node=$(get_ct_owner_node "$ctid") || return 1

  if [[ "$(get_ct_status "$ctid")" != "stopped" ]]; then
    echo "ERROR: CT ${ctid} must be stopped before GPU config reconciliation." >&2
    return 1
  fi

  run_on_node "$node" sed -i \
    -e '\|^lxc.cgroup2.devices.allow: c 226:\* rwm$|d' \
    -e '\|^lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir$|d' \
    "$config_file"

  if [[ "$NODE_GPU_STATE" == "available" ]] && ! ct_managed_gpu_disabled "$ctid"; then
    run_node_shell "$node" "printf '%s\\n' \
      'lxc.cgroup2.devices.allow: c 226:* rwm' \
      'lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir' >> '$config_file'"
    echo "  [✓] CT ${ctid}: exposing ${#NODE_GPU_RENDER_DEVICES[@]} DRM render device(s)"
  else
    echo "  [✓] CT ${ctid}: removed managed DRM passthrough"
  fi
}

reconcile_ct_gpu_config() {
  local ctid="${1:-${CTID}}"
  local node="${2:-$(hostname -s)}"
  local original_status
  original_status=$(get_ct_status "$ctid")

  resolve_ct_gpu_capability "$ctid" "$node" || return 1
  if ct_gpu_config_matches_capability "$ctid"; then
    echo "  [✓] CT ${ctid}: GPU config matches node '${node}' (${NODE_GPU_STATE})"
    return 0
  fi

  if [[ "$original_status" == "running" ]]; then
    pct_stop "$ctid"
    ensure_ct_stopped "$ctid" || return 1
  fi
  reconcile_stopped_ct_gpu_config "$ctid" || return 1
  if [[ "$original_status" == "running" ]]; then
    pct_start "$ctid"
    ensure_ct_running "$ctid" || return 1
  fi
}

finalize_ct_gpu_capability() {
  local ctid="${1:-${CTID}}"
  local node="${2:-}"
  local index device gid group

  if ct_managed_gpu_disabled "$ctid"; then
    echo "  [✓] CT ${ctid}: managed GPU passthrough is disabled"
    return 0
  fi

  [[ -n "$node" ]] || node=$(get_ct_owner_node "$ctid") || return 1
  detect_node_gpu_capability "$node" || return 1
  [[ "$NODE_GPU_STATE" == "available" ]] || return 0

  for index in "${!NODE_GPU_RENDER_DEVICES[@]}"; do
    device="${NODE_GPU_RENDER_DEVICES[$index]}"
    gid="${NODE_GPU_RENDER_GIDS[$index]}"
    group="render"
    [[ "$index" -gt 0 ]] && group="render${index}"
    ct_exec --timeout 15 "$ctid" "addgroup -g '${gid}' '${group}' 2>/dev/null || true; addgroup root '${group}' 2>/dev/null || true"
    if ! ct_exec --timeout 15 "$ctid" "test -c '${device}'" 2>/dev/null; then
      echo "ERROR: ${device} is not accessible inside CT ${ctid}." >&2
      return 1
    fi
  done
  echo "  [✓] CT ${ctid}: all DRM render devices are accessible"
}

# Run Docker Compose inside a CT through the optional hardware-profile wrapper.
# CTs without the delivered wrapper retain the legacy direct Compose behavior.
# Usage: ct_compose [--timeout SECONDS] [--all-profiles] [CTID] ARGS...
ct_compose() {
  local timeout=300 all_profiles=false ctid="${CTID}" argument quoted command
  if [[ "${1:-}" == --timeout ]]; then
    timeout="${2:-}"
    [[ "$timeout" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: Invalid ct_compose timeout." >&2; return 2; }
    shift 2
  fi
  if [[ "${1:-}" == --all-profiles ]]; then
    all_profiles=true
    shift
  fi
  if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
    ctid="$1"
    shift
  fi
  [[ $# -gt 0 ]] || { echo "ERROR: ct_compose requires Compose arguments." >&2; return 2; }

  command='cd /mnt/docker && if [ -x ./_config/shared/compose-profile.sh ]; then exec ./_config/shared/compose-profile.sh'
  [[ "$all_profiles" == true ]] && command+=' --all-profiles'
  command+=' --'
  for argument in "$@"; do
    printf -v quoted '%q' "$argument"
    command+=" ${quoted}"
  done
  command+='; else exec docker compose'
  for argument in "$@"; do
    printf -v quoted '%q' "$argument"
    command+=" ${quoted}"
  done
  command+='; fi'
  ct_exec --timeout "$timeout" "$ctid" "$command"
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

  # Pull every profile without selecting current hardware; pull creates no containers.
  local -a profiles=() pull_args=()
  local profile
  mapfile -t profiles < <(ct_compose --timeout 30 --all-profiles "${ctid}" config --profiles 2>/dev/null)
  for profile in "${profiles[@]}"; do
    [[ -n "$profile" ]] && pull_args+=(--profile "$profile")
  done
  pull_args+=(pull)

  local max_attempts=5
  local attempt output backoff

  for ((attempt=1; attempt<=max_attempts; attempt++)); do
    echo "  Pulling images (attempt ${attempt}/${max_attempts})..."

    if output=$(ct_compose --timeout 600 --all-profiles "${ctid}" "${pull_args[@]}" 2>&1); then
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
  local hostname node
  hostname=$(pct_config "$ctid" 2>/dev/null | awk -F': ' '/^hostname:/ {print $2}')
  node=$(get_ct_owner_node "$ctid") || return 1
  
  # Get newt configuration
  local newt_id newt_secret newt_endpoint
  newt_id=$(config_get_newt_id "$hostname")
  newt_secret=$(config_get_newt_secret "$hostname")
  newt_endpoint=$(config_get_newt_endpoint "$hostname")

  # Reconcile .env through the same consumption-aware path used during mount setup.
  local hostname_lower
  hostname_lower=$(echo "$hostname" | tr '[:upper:]' '[:lower:]')
  local env_file="/mnt/docker/${hostname_lower}/.env"
  
  if node_path_is_file "$node" "$env_file"; then
    local stage_dir stage_env
    stage_dir=$(mktemp -d)
    stage_env="${stage_dir}/.env"
    node_download_file "$node" "$env_file" "$stage_env"
    update_env_file "$stage_env" "/mnt/docker/${hostname_lower}/_config" "$node"
    ct_upload_file "$ctid" "$stage_env" /mnt/docker/.env 0600
    rm -rf "$stage_dir"
  fi
  
  # Build compose command with optional published profile
  local -a profile_args=()
  if [[ -n "$newt_id" && -n "$newt_secret" && -n "$newt_endpoint" ]]; then
    profile_args=(--profile published)
    echo "  Newt tunnel enabled (published profile)"
  fi

  # Images are pre-pulled by compose_pull (see reset_docker), so use the default
  # --pull missing here: start from cached images and avoid a redundant network hit.
  local max_attempts=3
  local attempt output
  local -a compose_args=("${profile_args[@]}" up -d --pull missing --remove-orphans)

  for ((attempt=1; attempt<=max_attempts; attempt++)); do
    echo "  Starting services (attempt ${attempt}/${max_attempts})..."

    if output=$(ct_compose --timeout 300 "${ctid}" "${compose_args[@]}" 2>&1); then
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

  local -a profiles=() down_args=()
  local profile
  mapfile -t profiles < <(ct_compose --timeout 30 --all-profiles "${ctid}" config --profiles 2>/dev/null)
  for profile in "${profiles[@]}"; do
    [[ -n "$profile" ]] && down_args+=(--profile "$profile")
  done
  down_args+=(down)
  ct_compose --timeout 300 --all-profiles "${ctid}" "${down_args[@]}"
}

# Reboot a container
# Waits for container to come back up and become responsive
# Args:
#   $1 - CTID (optional, defaults to global CTID)
reboot_ct() {
  local ctid="${1:-${CTID}}"
  
  echo "Rebooting CT ${ctid}..."
  pct_reboot "${ctid}"
  
  # Wait for CT status to be running
  echo "  Waiting for CT to start..."
  local timeout=30
  local running=false
  for ((i=1; i<=timeout; i++)); do
    if pct_status "${ctid}" 2>/dev/null | grep -q "status: running"; then
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
    if ct_exec --timeout 5 "${ctid}" 'true' 2>/dev/null; then
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

# Hard-restart a CT: full pct stop + pct start so Proxmox tears down and
# recreates the veth. Required for a net0 VLAN tag change to actually take
# effect — `pct reboot` does not reliably re-wire the interface onto the new
# VLAN bridge (the repo already uses stop/start for changes that must be
# re-initialized cleanly, e.g. resize and GPU mount changes).
# Args: $1 - CTID (defaults to $CTID)
# Returns: 0 when running + responsive, 1 otherwise.
restart_ct_hard() {
  local ctid="${1:-${CTID}}"
  local timeout=60 i

  echo "  Stopping CT ${ctid}..."
  pct_stop "${ctid}" 2>/dev/null
  local stopped=false
  for ((i=1; i<=timeout; i++)); do
    if pct_status "${ctid}" 2>/dev/null | grep -q "status: stopped"; then
      stopped=true; break
    fi
    sleep 1
  done
  if [[ "$stopped" != "true" ]]; then
    echo "  [!] CT ${ctid} did not stop within ${timeout}s"
    return 1
  fi

  echo "  Starting CT ${ctid}..."
  pct_start "${ctid}" 2>/dev/null
  local running=false
  for ((i=1; i<=timeout; i++)); do
    if pct_status "${ctid}" 2>/dev/null | grep -q "status: running"; then
      running=true; break
    fi
    sleep 1
  done
  if [[ "$running" != "true" ]]; then
    echo "  [!] CT ${ctid} did not start within ${timeout}s"
    return 1
  fi

  echo "  Waiting for CT ${ctid} to become responsive..."
  local responsive=false
  for ((i=1; i<=timeout; i++)); do
    if ct_exec --timeout 5 "${ctid}" 'true' 2>/dev/null; then
      responsive=true; break
    fi
    sleep 1
  done
  if [[ "$responsive" != "true" ]]; then
    echo "  [!] CT ${ctid} not responsive within ${timeout}s"
    return 1
  fi

  echo "  [✓] CT ${ctid} restarted (running and responsive)"
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
# Read a CT's current IPv4 address on eth0 (from inside the CT). Retries a few
# times because DHCP may not be ready immediately after a (re)start.
# Args: $1 - CTID (defaults to $CTID)
# Prints: the IPv4 address (nothing on failure). Returns 0 if found, 1 otherwise.
read_ct_ip() {
  local ctid="${1:-${CTID}}"
  local ip="" retries=5
  while [[ -z "$ip" && $retries -gt 0 ]]; do
    ip=$(ct_exec --timeout 15 "${ctid}" 'ip -4 addr show eth0 2>/dev/null | grep "inet " | tr -s " " | cut -d" " -f3 | cut -d"/" -f1' 2>/dev/null)
    if [[ -z "$ip" ]]; then
      retries=$((retries - 1))
      [[ $retries -gt 0 ]] && sleep 2
    fi
  done
  [[ -n "$ip" ]] || return 1
  printf '%s' "$ip"
}

# Get a CT's net0 MAC address (lowercased) from its Proxmox config.
# Args: $1 - CTID (defaults to $CTID)
# Prints: the MAC (nothing on failure). Returns 0 if found, 1 otherwise.
get_ct_mac() {
  local ctid="${1:-${CTID}}"
  local mac
  mac=$(pct_config "${ctid}" 2>/dev/null | grep -oP 'hwaddr=\K[^,]+' | tr '[:upper:]' '[:lower:]')
  [[ -n "$mac" ]] || return 1
  printf '%s' "$mac"
}

check_dns_health() {
  local ctid="${1:-${CTID}}"
  local hostname="${2:-${CT_HOSTNAME}}"
  
  echo "Checking DNS health for ${hostname}..."
  
  # -------------------------
  # Get CT info
  # -------------------------
  local ct_ip ct_mac
  
  # Get IP from inside the CT (retries a few times — DHCP may lag a reboot).
  if ! ct_ip=$(read_ct_ip "${ctid}"); then
    echo "  [!] Could not get IP from CT ${ctid}"
    return 1
  fi
  
  # Get MAC from CT config
  if ! ct_mac=$(get_ct_mac "${ctid}"); then
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

  # Refresh split DNS mapping before resolution checks. This runs for:
  #   - any CT whose domain is NOT the primary domain (its record lives in a
  #     per-domain split-DNS zone owned by forwardDNSCT.sh), and
  #   - the split-DNS host itself, so a fresh/`--reset` rebuild self-heals the
  #     per-domain zone configs (conf.d/<domain>.conf) that only forwardDNSCT.sh
  #     generates — nothing else repopulates them.
  local primary_domain hostname_domain splitdns_hostname
  primary_domain=$(config_get_primary_domain)
  hostname_domain=$(extract_domain_from_hostname "$hostname")
  splitdns_hostname=$(config_get_splitdns_hostname)
  if [[ ( -n "$primary_domain" && "${hostname_domain,,}" != "${primary_domain,,}" ) \
        || ( -n "$splitdns_hostname" && "${hostname,,}" == "${splitdns_hostname,,}" ) ]]; then
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

# Execute an argv-safe command on a Proxmox node. Bridge policy is node-local,
# so callers must not infer it from the cluster-wide resource configuration.
bridge_policy_node_exec() {
  local node="${1:-}" argument quoted command=""
  shift || true
  [[ -n "$node" && $# -gt 0 ]] || {
    echo "ERROR: bridge_policy_node_exec requires a node and command." >&2
    return 1
  }
  if declare -F run_on_node >/dev/null 2>&1; then
    run_on_node "$node" "$@"
    return
  fi
  if [[ "$node" == "$(hostname -s)" ]]; then
    "$@"
    return
  fi
  for argument in "$@"; do
    printf -v quoted '%q' "$argument"
    command+="${command:+ }${quoted}"
  done
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$node" "$command"
}

# Print one TAB-separated "bridge entities" record for each vmbr<number>
# paragraph in /etc/network/interfaces that has a standalone entities: label.
# The label is case-insensitive and may follow descriptive text in a comment.
bridge_policy_entries() {
  local node="${1:-}" interfaces
  [[ -n "$node" ]] || { echo "ERROR: Bridge policy node is required." >&2; return 1; }
  interfaces=$(bridge_policy_node_exec "$node" cat /etc/network/interfaces) || {
    echo "ERROR: Cannot read /etc/network/interfaces on ${node}." >&2
    return 1
  }
  awk -v node="$node" '
    BEGIN { RS=""; FS="\n"; OFS="\t"; invalid=0 }
    {
      bridge=""; entities=""; labels=0
      for (i=1; i<=NF; i++) {
        line=$i; sub(/\r$/, "", line)
        probe=line; sub(/^[[:space:]]+/, "", probe)
        if (probe ~ /^iface[[:space:]]+vmbr[0-9]+[[:space:]]/) {
          split(probe, fields, /[[:space:]]+/)
          bridge=fields[2]
        }
      }
      for (i=1; i<=NF; i++) {
        line=$i; sub(/\r$/, "", line); lower=tolower(line)
        if (match(lower, /(^|[^[:alnum:]_])entities[[:space:]]*:/)) {
          matched=substr(line, RSTART, RLENGTH)
          colon=index(matched, ":")
          value=substr(line, RSTART + colon)
          sub(/^[[:space:]]*/, "", value); sub(/[[:space:]]*$/, "", value)
          labels++
          entities=value
        }
      }
      if (bridge != "" && labels > 1) {
        printf "ERROR: Bridge %s on %s has multiple entities: labels.\n", bridge, node > "/dev/stderr"
        invalid=1
      } else if (bridge != "" && labels == 1) {
        print bridge, entities
      }
    }
    END { exit invalid }
  ' <<< "$interfaces"
}

# Resolve one bridge using exact identity, then CT/VM type, then wildcard *.
# Results are returned in BRIDGE_POLICY_* globals to avoid mixing diagnostics
# with command-substitution output.
bridge_policy_select() {
  local node="${1:-}" resource_type="${2:-}" resource_id="${3:-}" resource_name="${4:-}"
  local entries line bridge entities token normalized rank reason suffix number
  local best_bridge="" best_rank=99 best_number=2147483647 best_reason=""
  local policies=""
  local -a entity_tokens=()
  declare -A seen_bridges=()

  BRIDGE_POLICY_SELECTED=""
  BRIDGE_POLICY_RANK=""
  BRIDGE_POLICY_REASON=""
  resource_type="${resource_type^^}"
  [[ "$resource_type" == CT || "$resource_type" == VM ]] || {
    echo "ERROR: Bridge policy type must be CT or VM (got '${resource_type}')." >&2
    return 1
  }
  [[ "$resource_id" =~ ^[1-9][0-9]*$ && -n "$resource_name" ]] || {
    echo "ERROR: Bridge policy requires a numeric ID and hostname/name." >&2
    return 1
  }
  if ! entries=$(bridge_policy_entries "$node"); then
    return 1
  fi
  [[ -n "$entries" ]] || {
    echo "ERROR: No vmbr<number> entities: policies found on ${node}." >&2
    return 1
  }

  while IFS=$'\t' read -r bridge entities; do
    [[ -n "$bridge" ]] || continue
    if [[ -n "${seen_bridges[$bridge]:-}" ]]; then
      echo "ERROR: Bridge ${bridge} has more than one policy stanza on ${node}." >&2
      return 1
    fi
    seen_bridges[$bridge]=1
    [[ -n "$entities" ]] || {
      echo "ERROR: Bridge ${bridge} on ${node} has an empty entities: policy." >&2
      return 1
    }
    policies+="${policies:+; }${bridge}=[${entities}]"
    rank=99; reason=""
    normalized="${entities//,/ }"
    read -r -a entity_tokens <<< "$normalized"
    for token in "${entity_tokens[@]}"; do
      [[ "$token" == "*" || "$token" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
        echo "ERROR: Bridge ${bridge} on ${node} has invalid entity token '${token}'." >&2
        return 1
      }
      if [[ "$token" == "$resource_id" ]]; then
        rank=1; reason="ID ${resource_id}"
      elif [[ "${token,,}" == "${resource_name,,}" && $rank -gt 1 ]]; then
        rank=1; reason="hostname/name ${resource_name}"
      elif [[ "$token" == "$resource_type" && $rank -gt 2 ]]; then
        rank=2; reason="type ${resource_type}"
      elif [[ "$token" == "*" && $rank -gt 3 ]]; then
        rank=3; reason="wildcard *"
      fi
    done
    [[ "$rank" -lt 99 ]] || continue
    suffix="${bridge#vmbr}"
    number=$((10#$suffix))
    if (( rank < best_rank || (rank == best_rank && number < best_number) )); then
      best_bridge="$bridge"; best_rank="$rank"; best_number="$number"; best_reason="$reason"
    fi
  done <<< "$entries"

  [[ -n "$best_bridge" ]] || {
    echo "ERROR: No bridge policy on ${node} matches ${resource_type} ${resource_id} (${resource_name})." >&2
    echo "       Discovered policies: ${policies}" >&2
    return 1
  }
  BRIDGE_POLICY_SELECTED="$best_bridge"
  BRIDGE_POLICY_RANK="$best_rank"
  BRIDGE_POLICY_REASON="$best_reason"
}

bridge_policy_validate_runtime() {
  local node="${1:-}" bridge="${2:-}"
  [[ "$bridge" =~ ^vmbr[0-9]+$ ]] || {
    echo "ERROR: Invalid selected bridge '${bridge}'." >&2
    return 1
  }
  if ! bridge_policy_node_exec "$node" test -d "/sys/class/net/${bridge}/bridge"; then
    echo "ERROR: Selected bridge ${bridge} does not exist as a Linux bridge on ${node}." >&2
    return 1
  fi
}

bridge_policy_resolve() {
  local node="${1:-}" resource_type="${2:-}" resource_id="${3:-}" resource_name="${4:-}"
  bridge_policy_select "$node" "$resource_type" "$resource_id" "$resource_name" || return 1
  bridge_policy_validate_runtime "$node" "$BRIDGE_POLICY_SELECTED" || return 1
}

# Replace only bridge= and, when requested for an isolated restore, link_down=.
bridge_policy_rewrite_nic() {
  local value="${1:-}" bridge="${2:-}" force_link_down="${3:-false}"
  local part result="" bridge_fields=0 link_fields=0
  local -a parts=()
  [[ -n "$value" && "$bridge" =~ ^vmbr[0-9]+$ ]] || return 1
  IFS=',' read -r -a parts <<< "$value"
  for part in "${parts[@]}"; do
    [[ -n "$part" ]] || { echo "ERROR: Malformed empty NIC field in '${value}'." >&2; return 1; }
    if [[ "$part" == bridge=* ]]; then
      bridge_fields=$((bridge_fields + 1))
      part="bridge=${bridge}"
    elif [[ "$part" == link_down=* && "$force_link_down" == true ]]; then
      link_fields=$((link_fields + 1))
      part="link_down=1"
    fi
    result+="${result:+,}${part}"
  done
  (( bridge_fields <= 1 && link_fields <= 1 )) || {
    echo "ERROR: Malformed duplicate bridge/link_down fields in '${value}'." >&2
    return 1
  }
  (( bridge_fields == 1 )) || result+=",bridge=${bridge}"
  if [[ "$force_link_down" == true && $link_fields -eq 0 ]]; then
    result+=",link_down=1"
  fi
  printf '%s' "$result"
}

# Reconcile every netN of a CT or VM to one policy-selected bridge.
bridge_policy_reconcile_guest() {
  local node="${1:-}" resource_type="${2:-}" resource_id="${3:-}" bridge="${4:-}"
  local dry_run="${5:-false}" force_link_down="${6:-false}" config line key value target
  local tool option nic_count=0 change_count=0
  case "${resource_type^^}" in
    CT) tool=pct; option=- ;;
    VM) tool=qm; option=-- ;;
    *) echo "ERROR: Cannot reconcile unknown resource type '${resource_type}'." >&2; return 1 ;;
  esac
  config=$(bridge_policy_node_exec "$node" "$tool" config "$resource_id") || return 1
  while IFS= read -r line; do
    [[ "$line" =~ ^net[0-9]+:[[:space:]] ]] || continue
    key="${line%%:*}"
    value="${line#*: }"
    nic_count=$((nic_count + 1))
    target=$(bridge_policy_rewrite_nic "$value" "$bridge" "$force_link_down") || return 1
    [[ "$target" != "$value" ]] || continue
    change_count=$((change_count + 1))
    if [[ "$dry_run" == true ]]; then
      echo "  [dry-run] ${key}: ${value} -> ${target}"
    else
      bridge_policy_node_exec "$node" "$tool" set "$resource_id" "${option}${key}" "$target"
      if [[ "$force_link_down" == true ]]; then
        echo "  [~] ${key}: bridge -> ${bridge}, link_down -> 1"
      else
        echo "  [~] ${key}: bridge -> ${bridge}"
      fi
    fi
  done <<< "$config"
  (( nic_count > 0 )) || {
    echo "ERROR: ${resource_type^^} ${resource_id} has no netN devices to reconcile." >&2
    return 1
  }
  if (( change_count == 0 )); then
    echo "  [✓] All ${nic_count} NIC(s) already use ${bridge}"
  fi
}

# Ensure swap is half of memory
# Checks current CT config and adjusts swap if needed
# Requires: CTID to be set
ensure_swap() {
  local current_memory current_swap expected_swap
  
  # Get current memory and swap from CT config
  current_memory=$(pct_config "${CTID}" 2>/dev/null | grep -oP '^memory:\s*\K\d+' || echo "0")
  current_swap=$(pct_config "${CTID}" 2>/dev/null | grep -oP '^swap:\s*\K\d+' || echo "0")
  expected_swap=$((current_memory / 2))
  
  if [[ "$current_swap" -ne "$expected_swap" ]]; then
    echo "Adjusting swap: ${current_swap} MB -> ${expected_swap} MB (half of ${current_memory} MB RAM)"
    pct_set "${CTID}" -swap "${expected_swap}"
    echo "  [\u2713] Swap adjusted"
  fi
}

# Apply (or remove) the VLAN tag on the CT's primary NIC (net0).
# Args: $1 = CTID, $2 = desired VLAN id.
#   empty  -> leave the CT's VLAN configuration untouched (no-op)
#   0      -> remove any VLAN tag (unassign from all VLANs)
#   1-4094 -> set tag=<id> on net0
# Idempotent: reads the current net0, and only calls 'pct set' when the
# resulting device string actually changes. The change takes effect on the
# CT's next (re)start, which both createCT and refreshCT perform.
# Decide whether applying VLAN $2 to CT $1's net0 would actually change it.
# Side-effect free: never calls 'pct set'. Prints the resulting target net0
# device string to stdout so callers (apply_vlan_tag) can reuse it.
# Returns 0 when a change is PENDING (target differs from the current net0);
# returns 1 when nothing would change: VLAN not requested (empty), invalid id,
# no net0 device, or the tag already matches. This is the single source of
# truth for the change decision and is used both by apply_vlan_tag and by
# refreshCT to gate the mandatory UDM Pro fixed-IP release on a real VLAN change.
vlan_change_pending() {
  local ctid="$1" vlan="$2"

  # Not requested -> no change
  [[ -z "$vlan" ]] && return 1

  # Invalid id -> no change (apply_vlan_tag emits the user-facing error)
  if [[ ! "$vlan" =~ ^(0|[1-9][0-9]*)$ ]] || (( vlan > 4094 )); then
    return 1
  fi

  local current_net0
  current_net0=$(pct_config "${ctid}" 2>/dev/null | grep -oP '^net0:\s*\K.*' || echo "")
  [[ -z "$current_net0" ]] && return 1

  # Strip any existing tag=<n> segment (net0 always starts with name=..., so a
  # tag is preceded by a comma; the extra clauses are purely defensive).
  local base_net0="$current_net0"
  base_net0=$(echo "$base_net0" | sed -E 's/,tag=[0-9]+//; s/tag=[0-9]+,//; s/^tag=[0-9]+$//')

  local target_net0="$base_net0"
  if (( vlan >= 1 )); then
    target_net0="${base_net0},tag=${vlan}"
  fi

  printf '%s' "$target_net0"
  [[ "$target_net0" != "$current_net0" ]]
}

apply_vlan_tag() {
  local ctid="$1" vlan="$2"

  # Not requested -> leave the VLAN configuration untouched
  if [[ -z "$vlan" ]]; then
    return 0
  fi

  # Defensive re-validation (callers also validate at argument-parse time)
  if [[ ! "$vlan" =~ ^(0|[1-9][0-9]*)$ ]] || (( vlan > 4094 )); then
    echo "ERROR: --vlan must be an integer in range 0-4094 (got '${vlan}')" >&2
    return 1
  fi

  local current_net0
  current_net0=$(pct_config "${ctid}" 2>/dev/null | grep -oP '^net0:\s*\K.*' || echo "")
  if [[ -z "$current_net0" ]]; then
    echo "  [!] CT ${ctid} has no net0 device; skipping VLAN change" >&2
    return 0
  fi

  # vlan_change_pending is the single source of truth: it prints the target
  # net0 string and returns 0 only when a real change is pending.
  local target_net0
  if ! target_net0=$(vlan_change_pending "${ctid}" "${vlan}"); then
    if (( vlan == 0 )); then
      echo "  [i] VLAN already unassigned (net0 has no tag)"
    else
      echo "  [i] VLAN already set to ${vlan}"
    fi
    return 0
  fi

  pct_set "${ctid}" -net0 "${target_net0}"
  if (( vlan == 0 )); then
    echo "  [i] VLAN tag removed from CT ${ctid} (unassigned)"
  else
    echo "  [i] VLAN tag set to ${vlan} on CT ${ctid}"
  fi
}

# After a VLAN change + hard restart, ensure the CT obtains a lease on the NEW
# VLAN. Polls eth0 until it has an IPv4 address that DIFFERS from old_ip; if it
# has not converged within the initial passive window, actively nudges the CT to
# re-acquire DHCP and polls again. When old_ip is empty, any non-empty address
# is accepted. Diagnostics go to stderr so stdout carries only the new IP.
# Args: $1 - CTID, $2 - OLD_IP (may be empty)
# Prints: the new IP. Returns 0 on success, 1 if no new IP within the timeouts.
acquire_new_ip() {
  local ctid="$1" old_ip="$2"
  local ip="" i

  # Phase 1: passive wait — a clean stop/start already triggers a fresh DORA.
  for ((i=0; i<15; i++)); do
    ip=$(ct_exec --timeout 10 "${ctid}" 'ip -4 addr show eth0 2>/dev/null | grep "inet " | tr -s " " | cut -d" " -f3 | cut -d"/" -f1' 2>/dev/null)
    if [[ -n "$ip" && "$ip" != "$old_ip" ]]; then
      printf '%s' "$ip"; return 0
    fi
    sleep 3
  done

  # Phase 2: active nudge — restart networking (OpenRC/busybox) or, failing that,
  # flush the stale address and force a fresh udhcpc lease.
  echo "  [i] No new lease yet; forcing a DHCP re-acquire on eth0..." >&2
  ct_exec --timeout 45 "${ctid}" 'if [ -e /etc/init.d/networking ]; then service networking restart >/dev/null 2>&1 || rc-service networking restart >/dev/null 2>&1 || true; else ip addr flush dev eth0 2>/dev/null; udhcpc -i eth0 -n -q -t 8 -T 3 >/dev/null 2>&1 || true; fi' 2>/dev/null

  for ((i=0; i<10; i++)); do
    ip=$(ct_exec --timeout 10 "${ctid}" 'ip -4 addr show eth0 2>/dev/null | grep "inet " | tr -s " " | cut -d" " -f3 | cut -d"/" -f1' 2>/dev/null)
    if [[ -n "$ip" && "$ip" != "$old_ip" ]]; then
      printf '%s' "$ip"; return 0
    fi
    sleep 3
  done

  return 1
}

# Roll a CT back to its pre-Phase-A state after a failed VLAN change: restore the
# original net0 (old tag), re-pin the old fixed IP on UDM Pro, and hard-restart
# so the CT reclaims its old-VLAN address. Best-effort — logs what it could not
# restore for manual follow-up.
# Args: $1 CTID, $2 hostname, $3 original_net0, $4 old_ip (may be empty)
rollback_vlan_change() {
  local ctid="$1" hostname="$2" original_net0="$3" old_ip="$4"

  echo "  [!] Rolling back VLAN change for CT ${ctid}..."

  if [[ -n "$original_net0" ]]; then
    if pct_set "${ctid}" -net0 "${original_net0}" 2>/dev/null; then
      echo "    Restored net0: ${original_net0}"
    else
      echo "    [!] Failed to restore net0 (manual check needed)"
    fi
  fi

  # Re-pin the old reservation so the old VLAN's DHCP hands back the old IP.
  if [[ -n "$old_ip" ]]; then
    local ct_mac
    if ct_mac=$(get_ct_mac "${ctid}"); then
      udmpro_make_static "${ct_mac}" "${old_ip}" "${hostname}" \
        || echo "    [!] Failed to restore UDM Pro reservation for ${old_ip}"
    fi
  fi

  if ! restart_ct_hard "${ctid}"; then
    echo "    [!] CT ${ctid} did not come back cleanly during rollback (manual check needed)"
    return 1
  fi

  # Best-effort verify the CT reclaimed its old address.
  local now_ip
  now_ip=$(read_ct_ip "${ctid}" || true)
  if [[ -n "$old_ip" && "$now_ip" == "$old_ip" ]]; then
    echo "    [✓] Rollback complete — CT ${ctid} back on ${old_ip}"
  else
    echo "    [!] Rollback finished but CT ${ctid} IP is '${now_ip:-<none>}' (expected '${old_ip:-<any>}')"
  fi
  return 0
}

# PHASE A — isolated VLAN switch. Handles a pending VLAN change end-to-end BEFORE
# the routine refresh runs: release the UDM Pro reservation, apply the tag, hard
# restart onto the new VLAN, wait for a fresh new-subnet lease, and re-pin the
# reservation with the new IP. On failure past the mutation point, rolls the CT
# back to its original VLAN/IP/reservation.
# Args: $1 CTID, $2 hostname, $3 desired VLAN (empty / 0 / 1-4094)
# Returns: 0 when nothing to do OR the change succeeded; 1 on fatal failure
#          (rolled back where applicable — caller should mark the CT failed).
reconcile_vlan_change() {
  local ctid="$1" hostname="$2" vlan="$3"

  # Signals to the caller whether this phase performed a full stop/start, so the
  # routine refresh can skip its own (now-redundant) reboot and avoid extra
  # restart churn. Reset on every call (including the no-op path).
  VLAN_PHASE_RESTARTED=false

  # No VLAN requested or no actual change -> nothing to do.
  vlan_change_pending "${ctid}" "${vlan}" >/dev/null || return 0

  echo "VLAN change requested for CT ${ctid} — handling as an isolated phase..."

  # Capture pre-change state for a possible rollback.
  local original_net0 old_ip
  original_net0=$(pct_config "${ctid}" 2>/dev/null | grep -oP '^net0:\s*\K.*' || echo "")
  old_ip=$(read_ct_ip "${ctid}" || true)
  echo "  Pre-change state: net0='${original_net0}' ip='${old_ip:-<none>}'"

  # 1) Release the UDM Pro reservation. This runs before the tag write, so a
  #    failure here needs no rollback (nothing has changed yet).
  if ! udmpro_release_fixedip "${ctid}"; then
    echo "  [✗] Could not release UDM Pro fixed IP — VLAN left unchanged"
    return 1
  fi

  # 2) Write the new tag (config only; takes effect on the restart below).
  apply_vlan_tag "${ctid}" "${vlan}"

  # 3) Hard restart so Proxmox recreates the veth on the new VLAN bridge.
  if ! restart_ct_hard "${ctid}"; then
    echo "  [✗] CT ${ctid} failed to restart onto the new VLAN"
    rollback_vlan_change "${ctid}" "${hostname}" "${original_net0}" "${old_ip}"
    return 1
  fi

  # 4) Ensure the CT obtained a fresh lease on the new VLAN (IP != old_ip).
  local new_ip
  if ! new_ip=$(acquire_new_ip "${ctid}" "${old_ip}"); then
    echo "  [✗] CT ${ctid} did not obtain a new IP on the new VLAN"
    rollback_vlan_change "${ctid}" "${hostname}" "${original_net0}" "${old_ip}"
    return 1
  fi
  echo "  [✓] CT ${ctid} moved to the new VLAN — IP ${new_ip} (was ${old_ip:-<none>})"
  VLAN_PHASE_RESTARTED=true

  # 5) Re-pin the reservation + local DNS with the new IP (non-fatal; Phase B's
  #    check_dns_health retries).
  local ct_mac
  if ct_mac=$(get_ct_mac "${ctid}"); then
    udmpro_make_static "${ct_mac}" "${new_ip}" "${hostname}" \
      || echo "  [!] Re-pin of fixed IP failed (non-fatal; check_dns_health will retry)"
  fi

  return 0
}

# Build list of all containers
# Populates CT_MAP, CT_STATUS, CT_NODE, CT_TAGS, and CT_LIST.
build_ct_list() {
  CT_MAP=()
  CT_LIST=()
  CT_STATUS=()
  CT_NODE=()
  CT_TAGS=()

  local resources id status name node tags
  resources=$(pvesh get /cluster/resources --type vm --output-format json 2>/dev/null) || {
    echo "ERROR: Cannot query cluster containers." >&2
    return 1
  }
  while IFS=$'\t' read -r id status name node tags; do
    [[ "$id" =~ ^[1-9][0-9]*$ && -n "$name" && -n "$node" ]] || continue
    CT_MAP["$id"]="$name"
    CT_STATUS["$id"]="${status:-unknown}"
    CT_NODE["$id"]="$node"
    CT_TAGS["$id"]="$tags"
    CT_LIST+=("$id")
  done < <(jq -r '.[] | select(.type == "lxc") | [.vmid, (.status // "unknown"), (.name // ""), (.node // ""), (.tags // "")] | @tsv' \
    <<< "$resources" | sort -n)
}

ct_has_tag() {
  local ctid="$1" expected_tag="$2" tag
  while IFS= read -r tag; do
    [[ "$tag" == "$expected_tag" ]] && return 0
  done < <(tr ';' '\n' <<<"${CT_TAGS[$ctid]:-}")
  return 1
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
    item_text=$(printf "%-${item_width}s" "${hostname} [${status}@${CT_NODE[$id]}]")
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

# Select an online destination node other than the source node.
# Sets TARGET_NODE.
select_target_node() {
  local source_node="${1:-$(hostname -s)}"
  local nodes_json node
  local options=()

  nodes_json=$(pvesh get /nodes --output-format json 2>/dev/null) || {
    echo "ERROR: Cannot query cluster nodes." >&2
    return 1
  }

  while IFS= read -r node; do
    [[ -n "$node" && "$node" != "$source_node" ]] || continue
    options+=("$node" "online" "OFF")
  done < <(jq -r '.[] | select(.status == "online") | .node' <<< "$nodes_json" | sort)

  if [[ ${#options[@]} -eq 0 ]]; then
    echo "ERROR: No online target node is available." >&2
    return 1
  fi

  TARGET_NODE=$(whiptail --title "Target Node" \
    --radiolist "Move CT to:" 14 60 6 \
    "${options[@]}" \
    3>&1 1>&2 2>&3) || return 1
  [[ -n "$TARGET_NODE" ]] || return 1
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
    item_text=$(printf "%-${item_width}s" "${hostname} [${status}@${CT_NODE[$id]}]")
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
  local input="$1" id
  local matches=()
  
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
    for id in "${CT_LIST[@]}"; do
      if [[ "${CT_MAP[$id]}" == "$CT_HOSTNAME" ]]; then
        matches+=("$id")
      fi
    done

    if [[ ${#matches[@]} -eq 0 ]]; then
      echo "ERROR: No CT found with hostname '${CT_HOSTNAME}'."
      return 1
    fi
    if [[ ${#matches[@]} -ne 1 ]]; then
      echo "ERROR: Hostname '${CT_HOSTNAME}' matches multiple CTs: ${matches[*]}. Use a numeric CTID."
      return 1
    fi
    CTID="${matches[0]}"
  fi
  
  return 0
}

# Refresh only the VMID membership of managed backup jobs when they exist.
reconcile_backup_job_selections() {
  local job_id resource_type vmids
  validate_backup_config >/dev/null || return 1
  for resource_type in lxc qemu; do
    if [[ "$resource_type" == lxc ]]; then
      job_id=$(config_get_backup_job_id)
    else
      job_id=$(config_get_backup_vm_job_id)
    fi
    pvesh get "/cluster/backup/${job_id}" >/dev/null 2>&1 || continue
    vmids=$(backup_resource_ids "$resource_type") || return 1
    if [[ -n "$vmids" ]]; then
      pvesh set "/cluster/backup/${job_id}" --vmid "$vmids" --enabled 1 >/dev/null
    else
      pvesh set "/cluster/backup/${job_id}" --enabled 0 >/dev/null
    fi
  done
}

reconcile_backup_job_vmids() { reconcile_backup_job_selections; }

# Check the health of a single Proxmox storage.
# Verifies the storage exists/is active and, when it is a ZFS pool, that the pool
# is ONLINE and not resilvering (i.e. its redundancy is intact). Non-ZFS storages
# (dir, lvmthin, nfs, ...) have no ZFS redundancy concept here and only get the
# existence check.
# Args: $1 = storage id
# Output: on failure, echoes a human-readable reason to stdout
# Returns: 0 if healthy, 1 if missing/inactive/degraded/resilvering
probe_local_storage_mount_contract() {
  local expected_path source root_source
  local errors=()
  root_source=$(findmnt -n -o SOURCE --target / 2>/dev/null || true)

  for expected_path in /DATA /mnt/docker /mnt/docker-data; do
    if [[ -L "$expected_path" ]]; then
      errors+=("'${expected_path}' must not be a symlink")
      continue
    fi
    if ! mountpoint -q "$expected_path"; then
      errors+=("'${expected_path}' is not a mountpoint")
      continue
    fi
    [[ -w "$expected_path" ]] || errors+=("'${expected_path}' is not writable")
    source=$(findmnt -n -o SOURCE --target "$expected_path" 2>/dev/null || true)
    if [[ -z "$source" || "$source" == "$root_source" ]]; then
      errors+=("'${expected_path}' falls through to the root filesystem")
    fi
    if [[ "$expected_path" == "/DATA" && "$source" != "DATA" ]]; then
      errors+=("'/DATA' must be backed by ZFS pool DATA (found '${source:-unknown}')")
    fi
  done

  printf '%s\n' "${errors[@]}"
  [[ ${#errors[@]} -eq 0 ]]
}

validate_node_storage_contract() {
  local node="${1:-$(hostname -s)}"
  local local_node
  local node_context=" on node '${node}'"
  [[ "${CONTRACT_NODE_HEADER_ACTIVE:-false}" != "true" ]] || node_context=""
  local_node=$(hostname -s)
  local errors=()
  local storage config status type path content shared disabled nodes mount_errors

  for storage in DATA DOCKER DOCKER-DATA; do
    if ! config=$(pvesh get "/storage/${storage}" --output-format json 2>/dev/null); then
      errors+=("storage '${storage}' is missing from the Proxmox configuration")
      continue
    fi

    type=$(jq -r '.type // ""' <<< "$config")
    content=$(jq -r '.content // ""' <<< "$config")
    shared=$(jq -r '.shared // 0' <<< "$config")
    disabled=$(jq -r '.disable // 0' <<< "$config")
    nodes=$(jq -r '.nodes // ""' <<< "$config")

    [[ "$shared" == "0" ]] || errors+=("storage '${storage}' must be node-local (shared=0)")
    [[ "$disabled" == "0" ]] || errors+=("storage '${storage}' is disabled")
    if [[ -n "$nodes" ]] && ! tr ',' '\n' <<< "$nodes" | grep -Fxq "$node"; then
      errors+=("storage '${storage}' is not assigned to node '${node}'")
    fi
    if ! tr ',' '\n' <<< "$content" | grep -Fxq rootdir; then
      errors+=("storage '${storage}' must support rootdir content")
    fi

    case "$storage" in
      DATA)
        path=$(jq -r '.mountpoint // ""' <<< "$config")
        [[ "$type" == "zfspool" ]] || errors+=("storage 'DATA' must be type zfspool (found '${type:-unset}')")
        [[ "$(jq -r '.pool // ""' <<< "$config")" == "DATA" ]] || errors+=("storage 'DATA' must use pool DATA")
        [[ "$path" == "/DATA" ]] || errors+=("storage 'DATA' must use mountpoint /DATA (found '${path:-unset}')")
        ;;
      DOCKER)
        path=$(jq -r '.path // ""' <<< "$config")
        [[ "$type" == "dir" ]] || errors+=("storage 'DOCKER' must be type dir (found '${type:-unset}')")
        [[ "$path" == "/mnt/docker" ]] || errors+=("storage 'DOCKER' must use path /mnt/docker (found '${path:-unset}')")
        [[ "$(jq -r '."create-base-path" // 1' <<< "$config")" == "0" ]] || errors+=("storage 'DOCKER' must set create-base-path=0")
        ;;
      DOCKER-DATA)
        path=$(jq -r '.path // ""' <<< "$config")
        [[ "$type" == "dir" ]] || errors+=("storage 'DOCKER-DATA' must be type dir (found '${type:-unset}')")
        [[ "$path" == "/mnt/docker-data" ]] || errors+=("storage 'DOCKER-DATA' must use path /mnt/docker-data (found '${path:-unset}')")
        [[ "$(jq -r '."create-base-path" // 1' <<< "$config")" == "0" ]] || errors+=("storage 'DOCKER-DATA' must set create-base-path=0")
        ;;
    esac

    if ! status=$(pvesh get "/nodes/${node}/storage/${storage}/status" --output-format json 2>/dev/null); then
      errors+=("storage '${storage}' status is unavailable on node '${node}'")
    elif [[ "$(jq -r '.active // 0' <<< "$status")" != "1" ]]; then
      errors+=("storage '${storage}' is not active on node '${node}'")
    fi
  done

  if [[ "$node" == "$local_node" ]]; then
    if ! mount_errors=$(probe_local_storage_mount_contract); then
      while IFS= read -r path_error; do
        [[ -n "$path_error" ]] && errors+=("$path_error")
      done <<< "$mount_errors"
    fi
  else
    if ! mount_errors=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$node" \
      "$(declare -f probe_local_storage_mount_contract); probe_local_storage_mount_contract" 2>/dev/null); then
      if [[ -z "$mount_errors" ]]; then
        errors+=("cannot validate physical mounts over SSH")
      else
        while IFS= read -r path_error; do
          [[ -n "$path_error" ]] && errors+=("$path_error")
        done <<< "$mount_errors"
      fi
    fi
  fi

  if [[ ${#errors[@]} -gt 0 ]]; then
    echo "ERROR: Storage contract validation failed${node_context}:" >&2
    printf '  - %s\n' "${errors[@]}" >&2
    return 1
  fi

  echo "  [✓] Storage contract valid${node_context}"
  return 0
}

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

# Validate local-lvm as a CT rootfs target and enforce projected thin-pool headroom.
# Args: $1 = node, $2 = additional provisioned GiB, $3 = minimum free percent
validate_rootfs_target_capacity() {
  local node="${1:-$(hostname -s)}"
  local additional_gib="${2:-0}"
  local reserve_percent="${3:-20}"
  local config status type content shared disabled nodes vg thinpool
  local pool_size_bytes data_percent metadata_percent virtual_bytes used_bytes committed_bytes projected_bytes limit_bytes
  local node_context=" on node '${node}'"
  [[ "${CONTRACT_NODE_HEADER_ACTIVE:-false}" != "true" ]] || node_context=""

  [[ "$additional_gib" =~ ^[0-9]+([.][0-9]+)?$ ]] \
    || { echo "ERROR: Additional rootfs capacity must be a non-negative GiB value." >&2; return 1; }
  [[ "$reserve_percent" =~ ^[0-9]+$ && "$reserve_percent" -lt 100 ]] \
    || { echo "ERROR: Rootfs reserve percent must be an integer below 100." >&2; return 1; }

  config=$(pvesh get /storage/local-lvm --output-format json 2>/dev/null) || {
    echo "ERROR: Storage 'local-lvm' is missing from the Proxmox configuration." >&2
    return 1
  }
  type=$(jq -r '.type // ""' <<< "$config")
  content=$(jq -r '.content // ""' <<< "$config")
  shared=$(jq -r '.shared // 0' <<< "$config")
  disabled=$(jq -r '.disable // 0' <<< "$config")
  nodes=$(jq -r '.nodes // ""' <<< "$config")
  vg=$(jq -r '.vgname // ""' <<< "$config")
  thinpool=$(jq -r '.thinpool // ""' <<< "$config")

  [[ "$type" == "lvmthin" ]] || { echo "ERROR: Storage 'local-lvm' must be type lvmthin." >&2; return 1; }
  tr ',' '\n' <<< "$content" | grep -Fxq rootdir \
    || { echo "ERROR: Storage 'local-lvm' must support rootdir content." >&2; return 1; }
  [[ "$shared" == "0" && "$disabled" == "0" ]] \
    || { echo "ERROR: Storage 'local-lvm' must be enabled and node-local." >&2; return 1; }
  if [[ -n "$nodes" ]] && ! tr ',' '\n' <<< "$nodes" | grep -Fxq "$node"; then
    echo "ERROR: Storage 'local-lvm' is not assigned to node '${node}'." >&2
    return 1
  fi
  [[ "$vg" == "pve" && "$thinpool" == "data" ]] \
    || { echo "ERROR: Storage 'local-lvm' must use thin pool pve/data." >&2; return 1; }

  status=$(pvesh get "/nodes/${node}/storage/local-lvm/status" --output-format json 2>/dev/null) || {
    echo "ERROR: Storage 'local-lvm' status is unavailable on node '${node}'." >&2
    return 1
  }
  [[ "$(jq -r '.active // 0' <<< "$status")" == "1" ]] \
    || { echo "ERROR: Storage 'local-lvm' is not active on node '${node}'." >&2; return 1; }

  if [[ "$node" == "$(hostname -s)" ]]; then
    pool_size_bytes=$(lvs --noheadings --units b --nosuffix -o lv_size pve/data 2>/dev/null | xargs || true)
    data_percent=$(lvs --noheadings --nosuffix -o data_percent pve/data 2>/dev/null | xargs || true)
    metadata_percent=$(lvs --noheadings --nosuffix -o metadata_percent pve/data 2>/dev/null | xargs || true)
    virtual_bytes=$(lvs --noheadings --units b --nosuffix -o lv_size,pool_lv 2>/dev/null \
      | awk '$2 == "data" { sum += $1 } END { printf "%.0f", sum + 0 }' || true)
  else
    read -r pool_size_bytes data_percent metadata_percent < <(ssh -o BatchMode=yes -o ConnectTimeout=10 "$node" \
      "lvs --noheadings --units b --nosuffix -o lv_size,data_percent,metadata_percent pve/data 2>/dev/null" | xargs || true)
    virtual_bytes=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$node" \
      "lvs --noheadings --units b --nosuffix -o lv_size,pool_lv 2>/dev/null | awk '\$2 == \"data\" { sum += \$1 } END { printf \"%.0f\", sum + 0 }'" || true)
  fi
  [[ "$pool_size_bytes" =~ ^[0-9]+([.][0-9]+)?$ \
    && "$data_percent" =~ ^[0-9]+([.][0-9]+)?$ \
    && "$metadata_percent" =~ ^[0-9]+([.][0-9]+)?$ \
    && "$virtual_bytes" =~ ^[0-9]+$ ]] || {
    echo "ERROR: Cannot determine pve/data capacity${node_context}." >&2
    return 1
  }
  awk -v metadata="$metadata_percent" 'BEGIN { exit !(metadata < 80) }' || {
    echo "ERROR: pve/data metadata usage${node_context} is ${metadata_percent}% (limit: 80%)." >&2
    return 1
  }

  used_bytes=$(awk -v size="$pool_size_bytes" -v used="$data_percent" 'BEGIN { printf "%.0f", size * used / 100 }')
  if (( virtual_bytes > used_bytes )); then
    committed_bytes="$virtual_bytes"
  else
    committed_bytes="$used_bytes"
  fi
  projected_bytes=$(awk -v used="$committed_bytes" -v gib="$additional_gib" 'BEGIN { printf "%.0f", used + gib * 1073741824 }')
  limit_bytes=$(awk -v size="$pool_size_bytes" -v reserve="$reserve_percent" 'BEGIN { printf "%.0f", size * (100 - reserve) / 100 }')
  if (( projected_bytes > limit_bytes )); then
    echo "ERROR: local-lvm${node_context} lacks ${reserve_percent}% headroom after adding ${additional_gib} GiB." >&2
    return 1
  fi

  echo "  [✓] local-lvm capacity valid${node_context} (${reserve_percent}% reserve)"
}

# Verify that the separate Proxmox OS filesystem is not already under pressure.
# CT rootfs allocation does not consume this filesystem; this is a node-health gate.
validate_os_root_headroom() {
  local node="${1:-$(hostname -s)}"
  local reserve_percent="${2:-20}"
  local available_percent
  local node_context=" on node '${node}'"
  [[ "${CONTRACT_NODE_HEADER_ACTIVE:-false}" != "true" ]] || node_context=""

  [[ "$reserve_percent" =~ ^[0-9]+$ && "$reserve_percent" -lt 100 ]] \
    || { echo "ERROR: OS root reserve percent must be an integer below 100." >&2; return 1; }
  if [[ "$node" == "$(hostname -s)" ]]; then
    available_percent=$(df -P / | awk 'NR == 2 { gsub(/%/, "", $5); print 100 - $5 }')
  else
    available_percent=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$node" \
      "df -P / | awk 'NR == 2 { gsub(/%/, \"\", \$5); print 100 - \$5 }'" || true)
  fi
  [[ "$available_percent" =~ ^[0-9]+$ ]] \
    || { echo "ERROR: Cannot determine OS root capacity${node_context}." >&2; return 1; }
  (( available_percent >= reserve_percent )) || {
    echo "ERROR: OS root filesystem${node_context} has ${available_percent}% free (minimum: ${reserve_percent}%)." >&2
    return 1
  }
  echo "  [✓] OS root capacity valid${node_context} (${available_percent}% free)"
}

# Check the health of every storage VOLUME backing a container.
# Inspects the CT's rootfs and any volume-backed mount points (mpN of the form
# "storage:volume"); bind mounts (host paths starting with "/") are ignored.
# Each distinct storage is validated with check_storage_health.
# Args:
#   $1 = CTID
#   $2 = legacy mode argument (ignored; storage health is always advisory)
# Returns: always 0; unhealthy storage is reported as a warning.
check_ct_storage_health() {
  local ctid="$1"
  local config storages storage reason node

  node=$(get_ct_owner_node "$ctid" 2>/dev/null || true)
  config=$(pct_config "$ctid" 2>/dev/null) || {
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
    reason=""
    if [[ "$node" == "$(hostname -s)" ]]; then
      reason=$(check_storage_health "$storage") || true
    else
      reason=$(run_node_shell "$node" "$(declare -f check_storage_health); check_storage_health '$storage'" 2>/dev/null) || true
    fi
    if [[ -n "$reason" ]]; then
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
  pct_status "$ctid" 2>/dev/null | awk '{print $2}'
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
    lock_reason=$(pct_config "${ctid}" 2>/dev/null | grep -oP '^lock:\s*\K\S+' || true)

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
    pct_start "$ctid"
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
  
  local node
  node=$(get_ct_owner_node "$ctid") || return 1

  if [[ -n "$ct_timeout" ]]; then
    local rc=0
    run_on_node "$node" timeout "${ct_timeout}" pct exec "$ctid" -- sh -c "$cmd" || rc=$?
    if [[ $rc -eq 124 ]]; then
      echo "  [!] Timeout: command exceeded ${ct_timeout}s in CT ${ctid}" >&2
    fi
    return $rc
  else
    run_on_node "$node" pct exec "$ctid" -- sh -c "$cmd"
  fi
}

# Check if container exists
# Args: $1 = CTID
# Returns: 0 if exists, 1 if not
ct_exists() {
  local ctid="$1"
  get_ct_owner_node "$ctid" &>/dev/null
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
  local node
  node=$(get_ct_owner_node "$CTID") || return 1

  # Only CTs that ship a _config/ (i.e. have a configure.sh) need the library.
  if ! node_path_is_dir "$node" "${DIR_DOCKER}/_config"; then
    return 0
  fi

  if [[ ! -d "$src" ]]; then
    echo "  [i] No shared configure library at ${src} - skipping"
    return 0
  fi

  node_sync_tree "$node" "$src" "$dest"
  echo "  [✓] Synced shared configure library -> _config/shared"

  configure_compose_profile_boot "$CTID"
}

# Reconcile profile-aware Compose stacks after Docker starts on Alpine boot.
# CTs without a selector are explicitly kept free of this optional service.
configure_compose_profile_boot() {
  local ctid="${1:-${CTID}}"
  if ! ct_exec --timeout 10 "$ctid" 'test -x /mnt/docker/_config/select-compose-profile.sh'; then
    ct_exec --timeout 15 "$ctid" \
      'if [ -e /etc/init.d/compose-profile ]; then rc-update del compose-profile default >/dev/null 2>&1 || true; rm -f /etc/init.d/compose-profile; fi'
    return 0
  fi

  ct_exec --timeout 30 "$ctid" 'cat > /etc/init.d/compose-profile <<'"'"'OPENRC'"'"'
#!/sbin/openrc-run
description="Select hardware profile and reconcile Docker Compose"

depend() {
  need docker
  after networking
}

start() {
  ebegin "Reconciling Docker Compose hardware profile"
  cd /mnt/docker || return 1
  ./_config/shared/compose-profile.sh up -d --pull missing --remove-orphans
  eend $?
}
OPENRC
chmod 0755 /etc/init.d/compose-profile
rc-update add compose-profile default >/dev/null 2>&1'
  echo "  [✓] Compose hardware-profile boot reconciliation configured"
}

# Run per-CT configure.sh script (if present)
# Looks for ${DIR_DOCKER}/_config/configure.sh on the Proxmox host and runs it
# inside the CT via ct_exec. The script must be idempotent.
#
# The CT's .env file (/mnt/docker/.env inside the CT) is the single source of
# truth for configuration: configure.sh sources it directly (via load_env_file
# from the shared lib) to obtain any values it needs — including AUTH_* OIDC
# integration values written by update_env_file. There is no separate in-process
# secret injection; everything flows through the .env that Docker Compose also reads.
#
# Args: none (uses global CTID, CT_HOSTNAME, DIR_DOCKER)
# Returns: 0 on success or if no script exists, 1 on failure (non-fatal)
run_configure_script() {
  local configure_script="${DIR_DOCKER}/_config/configure.sh"
  local node
  node=$(get_ct_owner_node "$CTID") || return 1

  if ! node_path_is_file "$node" "$configure_script"; then
    return 0
  fi

  echo ""
  echo "--- configure.sh (${CT_HOSTNAME}) ---"

  # Ensure the script is executable
  run_on_node "$node" chmod +x -- "$configure_script"

  # Wait for Docker containers to be healthy (up to 120s)
  echo "  Waiting for containers to be healthy..."
  local retries=24
  while ! ct_compose --timeout 10 ps --status running --quiet 2>/dev/null | head -1 | grep -q .; do
    retries=$((retries - 1))
    if [[ $retries -le 0 ]]; then
      echo "  [!] Containers not healthy after 120s, running configure.sh anyway"
      break
    fi
    sleep 5
  done

  # Run the script inside the CT. configure.sh sources the CT .env itself for any
  # values it needs (single source of truth), so no env vars are injected here.
  if ct_exec --timeout 120 "cd /mnt/docker && sh ./_config/configure.sh '${CT_HOSTNAME}'" 2>&1; then
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
  local ct_config_dir="${2:-$(dirname "$env_file")/_config}"
  local config_node="${3:-}"
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
  local newt_id newt_secret newt_endpoint
  newt_id=$(config_get_newt_id "$target_hostname")
  newt_secret=$(config_get_newt_secret "$target_hostname")
  newt_endpoint=$(config_get_newt_endpoint "$target_hostname")
  
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

  ensure_env_key() {
    local key="$1"
    grep -q "^${key}=" "$env_file" || echo "${key}=" >> "$env_file"
  }

  compose_references_env_key() {
    local key="$1"
    local compose_file="${ct_config_dir%/_config}/docker-compose.yaml"
    local reference="\${${key}}"

    if [[ -n "$config_node" ]]; then
      node_path_is_file "$config_node" "$compose_file" \
        && run_on_node "$config_node" grep -Fq "$reference" "$compose_file"
    else
      [[ -f "$compose_file" ]] && grep -Fq "$reference" "$compose_file"
    fi
  }
  
  # Update required configuration values.
  # HOSTFQDN carries the CT's FQDN for compose interpolation. We deliberately do NOT
  # use HOSTNAME here: HOSTNAME is a well-known shell variable (exported in some
  # contexts), and Compose gives the process environment precedence over the .env,
  # so a leaked shell HOSTNAME could silently override the .env value. HOSTFQDN has
  # no such collision. remove_env_key cleans up the legacy HOSTNAME line on refresh.
  set_env_value "HOSTFQDN" "${target_hostname}" "Site FQDN (from CT container)"
  remove_env_key "HOSTNAME"
  if compose_references_env_key "CADDY_EMAIL"; then
    set_env_value "CADDY_EMAIL" "${email}" "Caddy email for ACME (from commonCT.json)"
  else
    remove_env_key "CADDY_EMAIL"
  fi

  # Authentik / OIDC provider values (product-agnostic AUTH_* names; the CT .env is
  # the single source of truth, consumed by both compose interpolation and the per-CT
  # configure.sh). AUTH_HOSTNAME is non-secret and is referenced by compose
  # forward-auth labels, so it is written whenever an Authentik host is configured.
  # The admin API token and flow slugs are only needed by a CT that self-registers
  # an OIDC app from its _config/configure.sh (i.e. one that sources lib-authentik),
  # so they are written ONLY for those CTs — keeping the admin token off the disk of
  # every CT that never uses it.
  local auth_host
  auth_host=$(config_get_authentik_host)
  if [[ -n "$auth_host" ]]; then
    set_env_value "AUTH_HOSTNAME" "${auth_host}" "Authentik/OIDC provider hostname (from commonCT.json authentik.host)"
  else
    remove_env_key "AUTH_HOSTNAME"
  fi

  local auth_token auth_authorization_flow auth_invalidation_flow has_auth_config=false
  if [[ -n "$config_node" ]]; then
    if node_path_is_file "$config_node" "${ct_config_dir}/configure.sh" \
       && run_on_node "$config_node" grep -q 'lib-authentik' "${ct_config_dir}/configure.sh" 2>/dev/null; then
      has_auth_config=true
    fi
  elif [[ -f "${ct_config_dir}/configure.sh" ]] \
       && grep -q 'lib-authentik' "${ct_config_dir}/configure.sh" 2>/dev/null; then
    has_auth_config=true
  fi
  if [[ -n "$auth_host" && "$has_auth_config" == true ]]; then
    auth_token=$(config_get_authentik_token)
    auth_authorization_flow=$(config_get_authentik_authorization_flow)
    auth_invalidation_flow=$(config_get_authentik_invalidation_flow)
    set_env_value "AUTH_API_TOKEN" "${auth_token}" "Authentik admin API token for OIDC self-registration (from commonCT.json authentik.apitoken)"
    set_env_value "AUTH_AUTHORIZATION_FLOW" "${auth_authorization_flow}" "Authentik authorization flow slug (from commonCT.json)"
    set_env_value "AUTH_INVALIDATION_FLOW" "${auth_invalidation_flow}" "Authentik invalidation flow slug (from commonCT.json)"
  else
    remove_env_key "AUTH_API_TOKEN"
    remove_env_key "AUTH_AUTHORIZATION_FLOW"
    remove_env_key "AUTH_INVALIDATION_FLOW"
  fi

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
  
  # OTLP/HTTP telemetry endpoint for application SDKs (from commonCT.json).
  # Resolved here so compose files never hardcode the telemetry host/port.
  local telemetry_host otlp_http_port otlp_grpc_port
  telemetry_host=$(config_get_telemetry_hostname)
  otlp_http_port=$(config_get_telemetry_otlp_http_port)
  otlp_grpc_port=$(config_get_telemetry_otlp_grpc_port)
  if [[ -n "$telemetry_host" && -n "$otlp_http_port" ]] \
     && { compose_references_env_key "OTEL_EXPORTER_OTLP_ENDPOINT" \
       || compose_references_env_key "OTEL_EXPORTER_OTLP_PROTOCOL"; }; then
    set_env_value "OTEL_EXPORTER_OTLP_ENDPOINT" "http://${telemetry_host}:${otlp_http_port}" "OTLP/HTTP telemetry endpoint (from commonCT.json)"
    # The endpoint above is the OTLP/HTTP port; OTEL SDKs default to gRPC, so the
    # protocol must be declared explicitly or exporters silently fail (gRPC frames
    # against an HTTP receiver). http/protobuf makes the SDK POST to /v1/{traces,metrics,logs}.
    set_env_value "OTEL_EXPORTER_OTLP_PROTOCOL" "http/protobuf" "OTLP protocol matching the OTLP/HTTP endpoint port"
  else
    remove_env_key "OTEL_EXPORTER_OTLP_ENDPOINT"
    remove_env_key "OTEL_EXPORTER_OTLP_PROTOCOL"
  fi

  # OTLP/gRPC telemetry endpoint (from commonCT.json). Consumed by components that
  # export OTLP over gRPC rather than HTTP - notably Caddy's native `tracing` module
  # (gRPC-only) and the per-CT `telemetry` sidecar collector. Kept separate from the
  # SDK HTTP endpoint above because they target different receiver ports (4317 vs 4318).
  if [[ -n "$telemetry_host" && -n "$otlp_grpc_port" ]] \
     && { compose_references_env_key "OTEL_EXPORTER_OTLP_GRPC_ENDPOINT" \
       || compose_references_env_key "OTEL_EXPORTER_OTLP_INSECURE"; }; then
    set_env_value "OTEL_EXPORTER_OTLP_GRPC_ENDPOINT" "http://${telemetry_host}:${otlp_grpc_port}" "OTLP/gRPC telemetry endpoint (from commonCT.json)"
    # The collector's gRPC receiver is plaintext (no TLS); declare insecure so gRPC
    # exporters do not attempt a TLS handshake against a cleartext endpoint.
    set_env_value "OTEL_EXPORTER_OTLP_INSECURE" "true" "Use plaintext for the OTLP/gRPC exporter (collector receiver is non-TLS)"
  else
    remove_env_key "OTEL_EXPORTER_OTLP_GRPC_ENDPOINT"
    remove_env_key "OTEL_EXPORTER_OTLP_INSECURE"
  fi

  if compose_references_env_key "NEWT_ID" \
     || compose_references_env_key "NEWT_SECRET" \
     || compose_references_env_key "NEWT_ENDPOINT"; then
    if [[ -n "$newt_id" && -n "$newt_secret" && -n "$newt_endpoint" ]]; then
      set_env_value "NEWT_ID" "$newt_id" "Newt/Pangolin tunnel configuration (from commonCT.json)"
      set_env_value "NEWT_SECRET" "$newt_secret" ""
      set_env_value "NEWT_ENDPOINT" "$newt_endpoint" ""
    else
      if ! grep -q '^NEWT_\(ID\|SECRET\|ENDPOINT\)=' "$env_file"; then
        echo -e "\n# Newt/Pangolin tunnel configuration (for 'published' profile)" >> "$env_file"
      fi
      ensure_env_key "NEWT_ID"
      ensure_env_key "NEWT_SECRET"
      ensure_env_key "NEWT_ENDPOINT"
    fi
  else
    remove_env_key "NEWT_ID"
    remove_env_key "NEWT_SECRET"
    remove_env_key "NEWT_ENDPOINT"
    sed -i "/^# Newt\/Pangolin tunnel configuration/d" "$env_file"
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

  local node stage_dir stage_compose stage_env
  node=$(get_ct_owner_node "$CTID") || return 1

  node_mkdir "$node" "$DIR_DOCKER" "$DIR_DOCKER_DATA"

  echo "Created:"
  echo "  $DIR_DOCKER"
  echo "  $DIR_DOCKER_DATA"

  COMPOSE_FILE="${DIR_DOCKER}/docker-compose.yaml"
  ENV_FILE="${DIR_DOCKER}/.env"

  stage_dir=$(mktemp -d)
  stage_compose="${stage_dir}/docker-compose.yaml"
  stage_env="${stage_dir}/.env"
  if ! node_path_is_file "$node" "$COMPOSE_FILE"; then
    echo "Creating template docker-compose.yaml at $COMPOSE_FILE"
    create_compose_template "$stage_compose"
    node_upload_file "$node" "$stage_compose" "$COMPOSE_FILE" 0644
  fi

  echo "Updating .env at $ENV_FILE"
  if node_path_is_file "$node" "$ENV_FILE"; then
    node_download_file "$node" "$ENV_FILE" "$stage_env"
  else
    : > "$stage_env"
  fi
  update_env_file "$stage_env" "${DIR_DOCKER}/_config" "$node"
  ct_upload_file "$CTID" "$stage_env" /mnt/docker/.env 0600
  rm -rf "$stage_dir"

  # Idempotent mount setup: only reconfigure if mounts are missing or incorrect
  echo "Verifying bind mounts..."
  
  local current_mp0 current_mp1 needs_update=0
  local config_output
  config_output=$(pct_config "$CTID" 2>/dev/null)
  
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
      pct_set "$CTID" -delete "$mp"
    done
    
    # Add correct mounts
    echo "Adding correct bind mounts..."
    pct_set "$CTID" -mp0 "${DIR_DOCKER},mp=/mnt/docker"
    pct_set "$CTID" -mp1 "${DIR_DOCKER_DATA},mp=/mnt/docker-data"
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

# Quote one value for the POSIX shell used by pct exec.
compose_permission_shell_quote() {
  local value="${1//\'/\'\\\'\'}"
  printf "'%s'" "$value"
}

compose_permission_ct_exec() {
  local executor="${COMPOSE_PERMISSION_EXECUTOR:-ct_exec}"
  "$executor" "$@"
}

compose_permission_render() {
  local ctid="$1"
  if [[ "${COMPOSE_PERMISSION_EXECUTOR:-ct_exec}" == ct_exec ]]; then
    ct_compose --timeout 30 "$ctid" config --format json
  else
    compose_permission_ct_exec --timeout 30 "$ctid" \
      'cd /mnt/docker && if [ -x ./_config/shared/compose-profile.sh ]; then ./_config/shared/compose-profile.sh config --format json; else docker compose config --format json; fi'
  fi
}

compose_permission_render_env_files() {
  local ctid="$1"
  if [[ "${COMPOSE_PERMISSION_EXECUTOR:-ct_exec}" == ct_exec ]]; then
    ct_compose --timeout 30 "$ctid" config --format json --no-env-resolution
  else
    compose_permission_ct_exec --timeout 30 "$ctid" \
      'cd /mnt/docker && if [ -x ./_config/shared/compose-profile.sh ]; then ./_config/shared/compose-profile.sh config --format json --no-env-resolution; else docker compose config --format json --no-env-resolution; fi'
  fi
}

# Resolve a managed CT-local bind source through the CT's actual mp configuration.
# Prints the canonical host mount root and source path, tab-separated.
compose_permission_host_mapping() {
  local ctid="$1" source="$2" line spec host_root ct_root suffix candidate canonical_root canonical_candidate

  while IFS= read -r line; do
    [[ "$line" =~ ^mp[0-9]+:[[:space:]] ]] || continue
    spec="${line#*: }"
    host_root="${spec%%,*}"
    ct_root=$(tr ',' '\n' <<< "$spec" | sed -n 's/^mp=//p' | head -1)
    [[ -n "$host_root" && -n "$ct_root" && "$source" == "$ct_root"/* ]] || continue

    suffix="${source#"$ct_root"}"
    candidate="${host_root}${suffix}"
    [[ -d "$host_root" && ! -L "$host_root" && ! -L "$candidate" ]] || return 1
    canonical_root=$(readlink -f -- "$host_root") || return 1
    canonical_candidate=$(readlink -m -- "$candidate") || return 1
    [[ "$canonical_candidate" == "$canonical_root"/* ]] || return 1
    printf '%s\t%s\n' "$canonical_root" "$canonical_candidate"
    return 0
  done < <(pct_config "$ctid" 2>/dev/null)

  return 1
}

# Remove empty host-root descendants that block an unprivileged CT from
# recreating a Compose bind source. The mount root itself is never removed.
remove_empty_host_root_bind_ancestors() {
  local ctid="$1" source="$2" mapping host_root host_source cursor owner

  mapping=$(compose_permission_host_mapping "$ctid" "$source") || return 1
  IFS=$'\t' read -r host_root host_source <<< "$mapping"
  cursor="$host_source"
  while [[ "$cursor" != "$host_root" ]]; do
    if [[ ! -e "$cursor" ]]; then
      cursor=$(dirname "$cursor")
      continue
    fi
    [[ -d "$cursor" && ! -L "$cursor" ]] || return 1
    owner=$(stat -c %u:%g -- "$cursor") || return 1
    [[ "$owner" == "0:0" ]] || return 1
    [[ -z "$(find "$cursor" -mindepth 1 -print -quit)" ]] || return 1
    rmdir -- "$cursor" || return 1
    cursor=$(dirname "$cursor")
  done
  echo "  [i] Recreating empty host-root bind source inside CT: ${source}"
}

create_compose_bind_source() {
  local ctid="$1" source="$2" owner="$3" quoted_source="$4"
  local mapping host_root host_source original_mode

  if compose_permission_ct_exec --timeout 30 "$ctid" \
    "mkdir -p ${quoted_source} && chown ${owner} ${quoted_source}"; then
    return 0
  fi

  remove_empty_host_root_bind_ancestors "$ctid" "$source" || return 1
  mapping=$(compose_permission_host_mapping "$ctid" "$source") || return 1
  IFS=$'\t' read -r host_root host_source <<< "$mapping"
  original_mode=$(stat -c %a -- "$host_root") || return 1
  (
    trap 'chmod "$original_mode" -- "$host_root"' EXIT
    chmod o+w -- "$host_root"
    compose_permission_ct_exec --timeout 30 "$ctid" \
      "mkdir -p ${quoted_source} && chown ${owner} ${quoted_source}"
  )
}

# Resolve the effective numeric UID:GID for a rendered Compose service.
# Precedence: repository override, Compose user, PUID/PGID, image Config.User.
resolve_compose_service_user() {
  local ctid="$1" compose_json="$2" service="$3"
  local image override user_spec puid pgid quoted_image quoted_user uid gid

  image=$(jq -r --arg service "$service" '.services[$service].image // empty' <<< "$compose_json")
  [[ -n "$image" ]] || {
    echo "Service '${service}' has writable binds but no image" >&2
    return 1
  }
  override=$(jq -r --arg service "$service" \
    '.services[$service].labels["permissions.thesaints.user"] // empty' <<< "$compose_json")
  user_spec=$(jq -r --arg service "$service" '.services[$service].user // empty' <<< "$compose_json")
  puid=$(jq -r --arg service "$service" '.services[$service].environment.PUID // empty' <<< "$compose_json")
  pgid=$(jq -r --arg service "$service" '.services[$service].environment.PGID // empty' <<< "$compose_json")

  if [[ -n "$override" ]]; then
    user_spec="$override"
  elif [[ -z "$user_spec" && ( -n "$puid" || -n "$pgid" ) ]]; then
    [[ "$puid" =~ ^[0-9]+$ && "$pgid" =~ ^[0-9]+$ ]] || {
      echo "Service '${service}' must define numeric PUID and PGID together" >&2
      return 1
    }
    printf '%s:%s\n' "$puid" "$pgid"
    return 0
  elif [[ -z "$user_spec" ]]; then
    quoted_image=$(compose_permission_shell_quote "$image")
    user_spec=$(compose_permission_ct_exec --timeout 30 "$ctid" \
      "docker image inspect --format '{{.Config.User}}' ${quoted_image}" 2>/dev/null) || {
      echo "Could not inspect user for service '${service}' image '${image}'" >&2
      return 1
    }
    if [[ -z "$user_spec" ]]; then
      echo '0:0'
      return 0
    fi
  fi

  if [[ "$user_spec" =~ ^[0-9]+:[0-9]+$ ]]; then
    printf '%s\n' "$user_spec"
    return 0
  fi
  if [[ "$user_spec" =~ ^[0-9]+$ ]]; then
    printf '%s:0\n' "$user_spec"
    return 0
  fi

  quoted_image=$(compose_permission_shell_quote "$image")
  quoted_user=$(compose_permission_shell_quote "$user_spec")
  uid=$(compose_permission_ct_exec --timeout 60 "$ctid" \
    "docker run --rm --user ${quoted_user} --entrypoint id ${quoted_image} -u" 2>/dev/null) || {
    echo "Could not resolve user '${user_spec}' for service '${service}'" >&2
    return 1
  }
  gid=$(compose_permission_ct_exec --timeout 60 "$ctid" \
    "docker run --rm --user ${quoted_user} --entrypoint id ${quoted_image} -g" 2>/dev/null) || {
    echo "Could not resolve group for user '${user_spec}' in service '${service}'" >&2
    return 1
  }
  [[ "$uid" =~ ^[0-9]+$ && "$gid" =~ ^[0-9]+$ ]] || {
    echo "Service '${service}' resolved to invalid UID:GID '${uid}:${gid}'" >&2
    return 1
  }
  printf '%s:%s\n' "$uid" "$gid"
}

# Validate and reconcile all repository-managed Compose bind permissions. Every
# mutation runs inside the CT, so LXC applies the active node's idmap.
reconcile_compose_permissions() {
  local ctid="${1:-$CTID}" mode="${2:-apply}" compose_json compose_env_json service owner source create_host_path skip recursive quoted_source
  local existing_owner services_for_source secret_path raw_env_path quoted_secret quoted_parent planned_source uid gid
  local -A source_owners=() source_services=() source_recursive=() source_create=() source_missing=()
  local -A raw_env_seen=() secret_seen=()
  local -a sources=() secrets=() raw_env_files=()

  [[ "$mode" == "apply" || "$mode" == "--check" ]] || {
    echo "  [!] Invalid permission reconciliation mode '${mode}'" >&2
    return 1
  }

  compose_json=$(compose_permission_render "$ctid" 2>/dev/null) || {
    echo "  [!] Could not render Compose permission plan" >&2
    return 1
  }
  compose_env_json=$(compose_permission_render_env_files "$ctid" 2>/dev/null) || {
    echo "  [!] Could not render Compose env_file permission plan" >&2
    return 1
  }

  while IFS= read -r service; do
    owner=$(resolve_compose_service_user "$ctid" "$compose_json" "$service") || return 1
    skip=$(jq -r --arg service "$service" \
      '.services[$service].labels["permissions.thesaints.skip"] // empty' <<< "$compose_json")
    recursive=$(jq -r --arg service "$service" \
      '.services[$service].labels["permissions.thesaints.recursive"] // "true"' <<< "$compose_json")
    [[ "$recursive" == "true" || "$recursive" == "false" ]] || {
      echo "  [!] Service '${service}' has invalid permissions.thesaints.recursive '${recursive}'" >&2
      return 1
    }

    while IFS=$'\t' read -r source create_host_path; do
      [[ -n "$source" ]] || continue
      if [[ ",$skip," == *",$source,"* ]]; then
        echo "  [i] ${service}: explicitly skipping ${source}"
        continue
      fi
      case "$source" in
        /mnt/docker/?*|/mnt/docker-data/?*) ;;
        *)
          echo "  [!] Refusing writable bind outside managed CT paths: ${service}:${source}" >&2
          return 1
          ;;
      esac
      existing_owner="${source_owners[$source]:-}"
      if [[ -n "$existing_owner" && "$existing_owner" != "$owner" ]]; then
        services_for_source="${source_services[$source]}"
        echo "  [!] Conflicting writers for ${source}: ${services_for_source}=${existing_owner}, ${service}=${owner}" >&2
        return 1
      fi
      if [[ -z "$existing_owner" ]]; then
        for planned_source in "${sources[@]}"; do
          if [[ "$source" == "$planned_source"/* || "$planned_source" == "$source"/* ]]; then
            echo "  [!] Overlapping writable bind sources are unsafe: ${planned_source} and ${source}" >&2
            return 1
          fi
        done
        sources+=("$source")
        source_owners[$source]="$owner"
        source_recursive[$source]="$recursive"
        source_create[$source]="$create_host_path"
      elif [[ "${source_recursive[$source]}" != "$recursive" ]]; then
        echo "  [!] Conflicting recursive policy for shared source ${source}" >&2
        return 1
      elif [[ "${source_create[$source]}" != "$create_host_path" ]]; then
        echo "  [!] Conflicting create_host_path policy for shared source ${source}" >&2
        return 1
      fi
      source_services[$source]="${source_services[$source]:+${source_services[$source]},}${service}"
    done < <(jq -r --arg service "$service" '
      .services[$service].volumes // [] | .[]
      | select(type == "object" and .type == "bind" and (.read_only != true))
      | [.source, (.bind.create_host_path // true)] | @tsv
    ' <<< "$compose_json")
  done < <(jq -r '
    .services | to_entries[]
    | select([.value.volumes[]?
        | select(type == "object" and .type == "bind" and (.read_only != true))]
        | length > 0)
    | .key
  ' <<< "$compose_json")

  while IFS= read -r secret_path; do
    [[ -n "$secret_path" ]] || continue
    case "$secret_path" in
      /mnt/docker/_secrets/?*)
        if [[ -z "${secret_seen[$secret_path]:-}" ]]; then
          secrets+=("$secret_path")
          secret_seen[$secret_path]=true
        fi
        ;;
      *)
        echo "  [!] Refusing Compose secret outside /mnt/docker/_secrets: ${secret_path}" >&2
        return 1
        ;;
    esac
  done < <(jq -r '.secrets // {} | to_entries[] | .value.file // empty' <<< "$compose_json")

  while IFS= read -r raw_env_path; do
    [[ -n "$raw_env_path" ]] || continue
    case "$raw_env_path" in
      /mnt/docker/_secrets/?*) ;;
      *)
        echo "  [!] Refusing Compose env_file outside /mnt/docker/_secrets: ${raw_env_path}" >&2
        return 1
        ;;
    esac
    if [[ -n "${secret_seen[$raw_env_path]:-}" ]]; then
      echo "  [!] Secret file uses conflicting env_file and mounted-secret modes: ${raw_env_path}" >&2
      return 1
    fi
    if [[ -z "${raw_env_seen[$raw_env_path]:-}" ]]; then
      raw_env_files+=("$raw_env_path")
      raw_env_seen[$raw_env_path]=true
    fi
  done < <(jq -r '
    .services // {} | to_entries[] | .value.env_file[]?
    | if type == "string" then . elif type == "object" then .path // empty else empty end
    | if startswith("./") then "/mnt/docker/" + .[2:]
      elif startswith("/") then .
      else "/mnt/docker/" + .
      end
  ' <<< "$compose_env_json")

  # Validate every source before the first mutation.
  for source in "${sources[@]}"; do
    quoted_source=$(compose_permission_shell_quote "$source")
    if ! compose_permission_ct_exec --timeout 15 "$ctid" "
      candidate=${quoted_source}
      while test ! -e \"\$candidate\"; do candidate=\$(dirname \"\$candidate\"); done
      canonical=\$(readlink -f \"\$candidate\") &&
      case \"\$canonical\" in /mnt/docker|/mnt/docker/?*|/mnt/docker-data|/mnt/docker-data/?*) exit 0 ;; *) exit 1 ;; esac
    " >/dev/null 2>&1; then
      echo "  [!] Missing or unsafe writable bind source: ${source}" >&2
      return 1
    fi
    if ! compose_permission_ct_exec --timeout 15 "$ctid" "test -e ${quoted_source}" >/dev/null 2>&1; then
      [[ "${source_create[$source]}" == "true" ]] || {
        echo "  [!] Writable bind source is missing and create_host_path is false: ${source}" >&2
        return 1
      }
      source_missing[$source]=true
    fi
  done
  for secret_path in "${secrets[@]}"; do
    quoted_secret=$(compose_permission_shell_quote "$secret_path")
    if ! compose_permission_ct_exec --timeout 15 "$ctid" \
      "test -f ${quoted_secret} && test ! -L ${quoted_secret} &&
       canonical=\$(readlink -f ${quoted_secret}) &&
       case \"\$canonical\" in /mnt/docker/_secrets/?*) exit 0 ;; *) exit 1 ;; esac" >/dev/null 2>&1; then
      echo "  [!] Missing or unsafe Compose secret: ${secret_path}" >&2
      return 1
    fi
  done
  for raw_env_path in "${raw_env_files[@]}"; do
    quoted_secret=$(compose_permission_shell_quote "$raw_env_path")
    if ! compose_permission_ct_exec --timeout 15 "$ctid" \
      "test -f ${quoted_secret} && test ! -L ${quoted_secret} &&
       canonical=\$(readlink -f ${quoted_secret}) &&
       case \"\$canonical\" in /mnt/docker/_secrets/?*) exit 0 ;; *) exit 1 ;; esac" >/dev/null 2>&1; then
      echo "  [!] Missing or unsafe Compose env_file: ${raw_env_path}" >&2
      return 1
    fi
  done

  if [[ "$mode" == "--check" ]]; then
    for source in "${sources[@]}"; do
      echo "  [check] ${source_services[$source]}: ${source} -> ${source_owners[$source]}${source_missing[$source]:+ (create directory)}"
    done
    for secret_path in "${secrets[@]}"; do
      echo "  [check] Compose secret: ${secret_path}"
    done
    for raw_env_path in "${raw_env_files[@]}"; do
      echo "  [check] Compose raw env_file: ${raw_env_path}"
    done
    return 0
  fi

  for source in "${sources[@]}"; do
    quoted_source=$(compose_permission_shell_quote "$source")
    owner="${source_owners[$source]}"
    uid="${owner%%:*}"
    gid="${owner#*:}"
    if [[ "${source_missing[$source]:-}" == "true" ]]; then
      create_compose_bind_source "$ctid" "$source" "$owner" "$quoted_source" || return 1
    fi
    if [[ "${source_recursive[$source]}" == "true" ]]; then
      if ! compose_permission_ct_exec --timeout 300 "$ctid" "
        if find ${quoted_source} \( ! -user ${uid} -o ! -group ${gid} \) -print -quit | grep -q .; then
          chown -R ${owner} ${quoted_source}
        fi
      "; then
        [[ "${source_create[$source]}" == "true" ]] || return 1
        remove_empty_host_root_bind_ancestors "$ctid" "$source" || return 1
        create_compose_bind_source "$ctid" "$source" "$owner" "$quoted_source" || return 1
      fi
    else
      compose_permission_ct_exec --timeout 30 "$ctid" \
        "current=\$(stat -c %u:%g ${quoted_source}) && { test \"\$current\" = ${owner} || chown ${owner} ${quoted_source}; }" || return 1
    fi
    echo "  [✓] ${source_services[$source]}: ${source} -> ${owner}"
  done
  for secret_path in "${secrets[@]}"; do
    quoted_secret=$(compose_permission_shell_quote "$secret_path")
    quoted_parent=$(compose_permission_shell_quote "$(dirname "$secret_path")")
    compose_permission_ct_exec --timeout 30 "$ctid" \
      "chown 0:0 ${quoted_parent} ${quoted_secret} && chmod 700 ${quoted_parent} && chmod 444 ${quoted_secret}" || return 1
    echo "  [✓] Compose secret permissions: ${secret_path}"
  done
  for raw_env_path in "${raw_env_files[@]}"; do
    quoted_secret=$(compose_permission_shell_quote "$raw_env_path")
    quoted_parent=$(compose_permission_shell_quote "$(dirname "$raw_env_path")")
    compose_permission_ct_exec --timeout 30 "$ctid" \
      "chown 0:0 ${quoted_parent} ${quoted_secret} && chmod 700 ${quoted_parent} && chmod 400 ${quoted_secret}" || return 1
    echo "  [✓] Compose raw env_file permissions: ${raw_env_path}"
  done
}
