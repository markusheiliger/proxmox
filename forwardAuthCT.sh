#!/usr/bin/env bash
#
# forwardAuthCT.sh - Enable or disable Caddy forward auth via Authentik
# Documentation: forwardAuthCT.md
#
# DESCRIPTION:
#   Manages Caddy forward auth labels in docker-compose.yaml files for
#   Proxmox LXC containers. When enabled, Caddy will authenticate requests
#   via the domain-level Authentik forward auth provider before proxying
#   to the backend service.
#
#   The labels are added to services that already have a caddy.reverse_proxy
#   label. After modifying the compose file, the CT is rebooted to apply
#   the changes.
#
#   Also manages the per-host Authentik forward_single application/provider:
#   created/ensured on enable, deleted on --remove, and deleted+recreated on
#   --reset (shared delete step, with confirmation).
#
# USAGE:
#   ./forwardAuthCT.sh [CTID or hostname]           # Enable forward auth
#   ./forwardAuthCT.sh [CTID or hostname] --remove   # Disable: delete Authentik
#                                                    # app/provider (after confirmation),
#                                                    # then strip the Caddy labels.
#   ./forwardAuthCT.sh [CTID or hostname] --reset    # Delete the existing Authentik
#                                                    # app/provider for the host (after
#                                                    # confirmation), then recreate it for
#                                                    # forward auth. Use to replace a stale
#                                                    # native-OIDC combo that shares the slug.
#
# EXAMPLES:
#   ./forwardAuthCT.sh                        # Interactive multi-select, enable
#   ./forwardAuthCT.sh --remove               # Interactive multi-select, disable
#   ./forwardAuthCT.sh 3200                   # Enable on CT 3200
#   ./forwardAuthCT.sh 3200 --remove          # Disable on CT 3200
#   ./forwardAuthCT.sh 3200 --reset           # Reset+recreate Authentik objects on CT 3200
#   ./forwardAuthCT.sh rust.thesaints.home    # Enable by hostname
#
# REQUIREMENTS:
#   - Run on Proxmox VE host as root
#   - Container must be running
#   - Authentik must be configured in commonCT.json
#   - docker-compose.yaml must have caddy.reverse_proxy labels
#
# SEE ALSO:
#   createCT.sh      Create a new container with Docker
#   refreshCT.sh     Refresh and update a container
#   commonCT.sh      Shared idempotent configuration functions
#
set -euo pipefail

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/commonCT.sh"

# Global flags
REMOVE_MODE=false
RESET_MODE=false

# Injector-managed Caddy labels (indented for the YAML labels block).
# The Authentik host is referenced as the ${AUTH_HOSTNAME} Docker Compose variable, written
# into each CT's .env by update_env_file (from commonCT.json authentik.host). Docker Compose
# interpolates it when reading the compose file, so the .env is the single source of truth and
# the labels are rename-safe (renaming the Authentik CT only re-writes .env, never these labels).
# These two entries live inside a `caddy.route` block (single source of truth):
#   - 0_reverse_proxy : always forward the Authentik outpost path to the outpost, so the
#                       OAuth callback is served from the application host and the proxy
#                       session cookie is set there. This is what makes forward_single work
#                       even when the app and Authentik are under different parent domains.
#                       Runs BEFORE forward_auth.
#   - 50_forward_auth : authenticate everything that is not an explicit bypass route.
# Host header: the upstream is dialed at ${AUTH_HOSTNAME} (so TLS SNI/cert match Authentik),
# but the HTTP Host MUST be the application's own host ({http.request.host}). The embedded
# outpost selects the forward_single provider by Host == provider.external_host, and scopes
# the proxy session cookie to that host. Overriding Host to ${AUTH_HOSTNAME} makes the outpost
# match no provider (404 "Not Found") and would set the cookie on the wrong domain.
# The protected service owns the rest of the route via numeric-prefix bands:
#   1_..49_   bypass routes (no auth), evaluated before forward_auth
#   51_..98_  authenticated auxiliary routes
#   99_       the app catch-all reverse_proxy
FORWARD_AUTH_LABELS=(
  'caddy.route.0_reverse_proxy: "/outpost.goauthentik.io/* https://${AUTH_HOSTNAME}"'
  'caddy.route.0_reverse_proxy.header_up: "Host {http.request.host}"'
  'caddy.route.50_forward_auth: "https://${AUTH_HOSTNAME}"'
  'caddy.route.50_forward_auth.uri: "/outpost.goauthentik.io/auth/caddy"'
  'caddy.route.50_forward_auth.header_up: "Host {http.request.host}"'
  'caddy.route.50_forward_auth.copy_headers: "X-Authentik-Username X-Authentik-Groups X-Authentik-Email X-Authentik-Name X-Authentik-Uid"'
  'caddy.route.50_forward_auth.trusted_proxies: private_ranges'
)

# Regex (PCRE) matching the injector-managed label keys (the two entries above).
MANAGED_LABEL_REGEX='caddy\.route\.(0_reverse_proxy|50_forward_auth)'

# Add forward auth labels to a compose file
# Idempotent: removes any existing injector-managed labels, then inserts the canonical
# set from FORWARD_AUTH_LABELS so values always match this script (single source of truth).
# Requires the service to use a `caddy.route` block; a simple `caddy.reverse_proxy` is
# auto-migrated to the catch-all band `caddy.route.99_reverse_proxy`. Handle-based or other
# non-conforming label layouts fail fast with guidance to normalize per the ct-compose skill.
add_forward_auth_labels() {
  local compose_file="$1"

  # Match 'caddy:' as a standalone label key (site address), not 'caddy.something:'
  if ! grep -qP '^\s+caddy:\s' "$compose_file" 2>/dev/null; then
    echo "  [!] No caddy site labels found, skipping"
    return 0
  fi

  # The service must use a caddy.route block (forward-auth contract). If it only has a
  # simple caddy.reverse_proxy, migrate it to the catch-all band caddy.route.99_reverse_proxy.
  if ! grep -qP '^\s+caddy\.route\.' "$compose_file" 2>/dev/null; then
    if grep -qP '^\s+caddy\.reverse_proxy(\.|:)' "$compose_file" 2>/dev/null \
       && ! grep -qP '^\s+caddy\.[0-9]+_handle' "$compose_file" 2>/dev/null; then
      local tmpmig
      tmpmig=$(mktemp)
      sed -E 's/^(\s*)caddy\.reverse_proxy/\1caddy.route.99_reverse_proxy/' "$compose_file" > "$tmpmig"
      mv "$tmpmig" "$compose_file"
      echo "  [~] Migrated simple reverse_proxy to caddy.route.99_reverse_proxy"
    else
      echo "  [!] Service does not use a 'caddy.route' block and cannot be auto-migrated."
      echo "      Normalize the caddy labels to a route block per the ct-compose skill"
      echo "      (bands: 1_-49_ bypass, 50_ forward_auth [managed], 51_-98_ authed, 99_ app),"
      echo "      then re-run forward auth."
      return 1
    fi
  fi

  # The managed label set is constant: the Authentik host is the literal ${AUTH_HOSTNAME}
  # Compose variable (resolved from the CT .env by Docker Compose), so nothing is substituted here.
  local canonical_labels=("${FORWARD_AUTH_LABELS[@]}")

  # Idempotency: if the managed labels already match exactly, nothing to do
  if grep -qP "^\s+${MANAGED_LABEL_REGEX}" "$compose_file" 2>/dev/null; then
    local existing canonical
    existing=$(grep -P "^\s+${MANAGED_LABEL_REGEX}" "$compose_file" | sed 's/^[[:space:]]*//' | sort)
    canonical=$(printf '%s\n' "${canonical_labels[@]}" | sort)
    if [[ "$existing" == "$canonical" ]]; then
      echo "  [✓] Forward auth labels already up-to-date"
      return 2  # No changes needed
    fi
    # Remove outdated managed labels first
    local tmpfile
    tmpfile=$(mktemp)
    grep -vP "^\s+${MANAGED_LABEL_REGEX}" "$compose_file" > "$tmpfile"
    mv "$tmpfile" "$compose_file"
    echo "  [~] Removed outdated forward auth labels"
  fi

  # Build the block of lines to insert
  local insert_block=""
  local label
  for label in "${canonical_labels[@]}"; do
    insert_block+="${label}\n"
  done

  # Insert managed labels right after the 'caddy: <hostname>' site line. Ordering inside the
  # route block is by numeric prefix, independent of physical line position.
  local tmpfile
  tmpfile=$(mktemp)
  awk -v insert="$insert_block" '
  { print }
  /^[[:space:]]+caddy:[[:space:]]/ && !/caddy\./ {
    match($0, /^[[:space:]]*/);
    indent = substr($0, RSTART, RLENGTH)

    n = split(insert, lines, "\\n")
    for (i = 1; i <= n; i++) {
      if (lines[i] != "") print indent lines[i]
    }
  }
  ' "$compose_file" > "$tmpfile"

  mv "$tmpfile" "$compose_file"
  echo "  [✓] Forward auth labels applied (${#canonical_labels[@]} labels)"
}

# Remove forward auth labels from a compose file
# Strips only the injector-managed entries; the service's own route block and app
# catch-all are left intact (the app keeps serving, just without authentication).
remove_forward_auth_labels() {
  local compose_file="$1"

  if ! grep -qP "^\s+${MANAGED_LABEL_REGEX}" "$compose_file" 2>/dev/null; then
    echo "  [✓] No forward auth labels present"
    return 2  # No changes needed
  fi

  local tmpfile
  tmpfile=$(mktemp)
  grep -vP "^\s+${MANAGED_LABEL_REGEX}" "$compose_file" > "$tmpfile"
  mv "$tmpfile" "$compose_file"
  echo "  [✓] Forward auth labels removed"
}

# Recreate compose services in the CT to apply label changes
restart_compose() {
  echo "  Recreating Docker Compose services..."

  # Wait for Docker to be ready
  local retries=5
  while ! ct_exec --timeout 10 'docker info >/dev/null 2>&1' 2>/dev/null; do
    retries=$((retries - 1))
    if [[ $retries -le 0 ]]; then
      echo "  [!] Docker not ready in CT, skipping restart"
      return 1
    fi
    sleep 2
  done

  if ! ct_exec --timeout 15 'test -s /mnt/docker/docker-compose.yaml' 2>/dev/null; then
    echo "  [!] No docker-compose.yaml in CT, skipping restart"
    return 1
  fi

  # Validate compose file after modification
  if ! ct_exec --timeout 30 'cd /mnt/docker && docker compose config --quiet' 2>/dev/null; then
    echo "  [!] Warning: docker-compose.yaml validation failed after modification"
    echo "      Check the compose file: pct exec ${CTID} -- sh -c 'cd /mnt/docker && docker compose config'"
    return 1
  fi

  ct_exec --timeout 120 'cd /mnt/docker && docker compose up -d --force-recreate' 2>/dev/null || true
  echo "  [✓] Compose services recreated"
}

# Process a single CT
process_ct() {
  local compose_file="${DIR_DOCKER}/docker-compose.yaml"
  local node stage_dir staged_compose original_compose
  node=$(get_ct_owner_node "$CTID") || return 1

  if ! node_path_is_file "$node" "$compose_file"; then
    echo "  [!] No docker-compose.yaml found at ${node}:${compose_file}"
    return 0
  fi

  stage_dir=$(mktemp -d)
  staged_compose="${stage_dir}/docker-compose.yaml"
  original_compose="${stage_dir}/docker-compose.original.yaml"
  node_download_file "$node" "$compose_file" "$staged_compose"
  cp -a "$staged_compose" "$original_compose"

  local rc=0

  if [[ "$REMOVE_MODE" == "true" ]]; then
    echo "  Removing forward auth labels..."
    remove_forward_auth_labels "$staged_compose" || rc=$?
  else
    local ak_host
    ak_host=$(config_get_authentik_host)
    if [[ -z "$ak_host" ]]; then
      echo "  [!] Authentik host not configured in commonCT.json"
      return 1
    fi

    echo "  Adding forward auth labels..."
    add_forward_auth_labels "$staged_compose" || rc=$?
  fi

  # Only recreate containers if labels were actually changed
  if [[ "$rc" -eq 2 ]]; then
    echo "  [✓] No changes, skipping restart"
    rm -rf "$stage_dir"
    return 0
  fi

  node_upload_file "$node" "$staged_compose" "$compose_file" 0644
  if ! ct_exec --timeout 30 'cd /mnt/docker && docker compose config --quiet' 2>/dev/null; then
    echo "  [!] Modified Compose file is invalid; restoring original"
    node_upload_file "$node" "$original_compose" "$compose_file" 0644 || true
    rm -rf "$stage_dir"
    return 1
  fi

  if ! restart_compose; then
    echo "  [!] Compose recreation failed; restoring original file"
    node_upload_file "$node" "$original_compose" "$compose_file" 0644 || true
    rm -rf "$stage_dir"
    return 1
  fi
  rm -rf "$stage_dir"
}

# -----------------------------
# MAIN
# -----------------------------
main() {
  lifecycle_log_init "${BASH_SOURCE[0]}" "$@"
  local ct_arg=""

  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --remove|-r)
        REMOVE_MODE=true
        shift
        ;;
      --reset)
        RESET_MODE=true
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

  if [[ "$RESET_MODE" == "true" && "$REMOVE_MODE" == "true" ]]; then
    echo "Error: --reset and --remove cannot be combined (reset recreates, remove deletes)."
    exit 1
  fi

  # Verify Authentik config (unless removing)
  if [[ "$REMOVE_MODE" != "true" ]]; then
    if ! config_authentik_configured; then
      echo "Error: Authentik not configured in commonCT.json (missing host or apitoken)"
      exit 1
    fi
  fi
  build_ct_list

  if [[ ${#CT_LIST[@]} -eq 0 ]]; then
    echo "No containers found."
    exit 0
  fi

  # Build list of CTs to process
  local cts_to_process=()

  if [[ -z "$ct_arg" ]]; then
    local action="enable forward auth"
    [[ "$REMOVE_MODE" == "true" ]] && action="disable forward auth"
    select_ct_interactive_multi "$action" || exit 1
    cts_to_process=("${SELECTED_CTS[@]}")
  else
    resolve_ct_from_input "$ct_arg" || exit 1
    cts_to_process=("$CTID")
  fi

  local mode_label="Enabling"
  [[ "$REMOVE_MODE" == "true" ]] && mode_label="Disabling"

  # Process each selected CT
  local total=${#cts_to_process[@]}
  local current=0

  status_bar_init

  for CTID in "${cts_to_process[@]}"; do
    current=$((current + 1))
    CT_HOSTNAME="${CT_MAP[$CTID]}"
    get_ct_dirs "${CT_HOSTNAME}"

    echo ""
    echo "=============================================="
    echo "${mode_label} forward auth: CT ${CTID} (${CT_HOSTNAME}) [${current}/${total}]"
    echo "=============================================="
    echo ""

    status_progress "$current" "$total" "CT ${CTID}: ${mode_label} forward auth..."

    ensure_ct_running || continue

    # Provision/teardown the per-host Authentik forward_single provider/application before
    # touching the Caddy labels.
    #   --remove : delete the Authentik app/provider (shared step), then strip labels.
    #   --reset  : delete the existing app/provider, then recreate it (handled inside
    #              configure_authentik_forward_auth via the reset flag).
    #   default  : create/ensure the app/provider.
    # For --remove the Authentik deletion is non-fatal (declining the prompt still removes
    # the Caddy labels); for the create/reset path a failure skips the CT.
    if [[ "$REMOVE_MODE" == "true" ]]; then
      delete_authentik_forward_auth "$CT_HOSTNAME" || true
      echo ""
    else
      if ! configure_authentik_forward_auth "$CT_HOSTNAME" "$RESET_MODE"; then
        echo "  [!] Authentik forward auth provisioning failed for ${CT_HOSTNAME} — skipping"
        continue
      fi
      echo ""
    fi

    if ! process_ct; then
      echo "  [!] Forward auth update failed for ${CT_HOSTNAME}"
      continue
    fi

    echo ""
    local done_label="enabled"
    [[ "$REMOVE_MODE" == "true" ]] && done_label="disabled"
    echo "Done. CT ${CTID} (${CT_HOSTNAME}) forward auth ${done_label}."
  done

  status_bar_cleanup

  echo ""
  echo "All ${total} container(s) processed."
}

main "$@"
