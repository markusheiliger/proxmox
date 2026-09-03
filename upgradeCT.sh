#!/usr/bin/env bash
# Upgrade Alpine LXC CTs across major releases with rootfs rollback.
# Documentation: upgradeCT.md
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/commonCT.sh"

TARGET_RELEASE=""
DRY_RUN=false
FORCE=false
KEEP_FAILED=false
ORIGINAL_STATUS=""
SNAPSHOT_NAME=""
SNAPSHOT_CREATED=false
SNAPSHOT_METHOD=""
ZFS_SNAPSHOT=""
COMMITTED=false
DIAGNOSTIC_LOG=""
PREPARED_CURRENT=""

usage() {
  cat <<'EOF'
Usage: upgradeCT.sh [CTID|hostname] [--target 3.24] [--dry-run] [--force]
                    [--keep-failed]

With a CT argument, upgrades that Alpine CT one release at a time. Without a CT
argument, presents a multi-select list containing only Alpine CTs older than the
target and upgrades the selected CTs serially. The default target is the newest
Alpine 3.x release advertised by pveam. A stopped rootfs rollback point is
created before each CT is changed and retained after success. The first failed
upgrade stops the batch after rollback handling.

  --target VERSION         Target Alpine release (for example, 3.24)
  --dry-run                Print the release path without changing the CT
  --force                  Skip the confirmation prompt
  --keep-failed            Do not roll back a failed upgrade (diagnostics only)
EOF
}

normalize_release() {
  local release="$1"
  release="${release#v}"
  [[ "$release" =~ ^3\.[0-9]+$ ]] || return 1
  printf '%s\n' "$release"
}

release_minor() {
  printf '%s\n' "${1#3.}"
}

build_release_path() {
  local current="$1" target="$2" current_minor target_minor minor
  current_minor=$(release_minor "$current")
  target_minor=$(release_minor "$target")
  (( target_minor >= current_minor )) || return 1
  for ((minor = current_minor + 1; minor <= target_minor; minor++)); do
    printf '3.%d\n' "$minor"
  done
}

detect_default_target() {
  local template
  template=$(pveam available 2>/dev/null | awk '{print $2}' \
    | sed -nE 's/^alpine-(3\.[0-9]+)-.*$/\1/p' \
    | sort -V | tail -1)
  [[ -n "$template" ]] || {
    echo "ERROR: Could not determine the current Alpine release from pveam." >&2
    return 1
  }
  printf '%s\n' "$template"
}

read_ct_release() {
  local rootfs volume root_path
  if [[ "$(get_ct_status "$CTID")" == "running" ]]; then
    ct_exec --timeout 15 "$CTID" 'cut -d. -f1,2 /etc/alpine-release'
    return
  fi

  rootfs=$(pct config "$CTID" 2>/dev/null | sed -n 's/^rootfs:[[:space:]]*//p')
  volume="${rootfs%%,*}"
  root_path=$(pvesm path "$volume" 2>/dev/null) || {
    echo "ERROR: Cannot resolve the root filesystem for stopped CT ${CTID}." >&2
    return 1
  }
  cut -d. -f1,2 "${root_path}/etc/alpine-release"
}

rewrite_repositories_command() {
  local release="$1"
  printf '%s' "cp /etc/apk/repositories /etc/apk/repositories.pre-upgrade && sed -E -i 's#/v3\.[0-9]+/#/v${release}/#g; s#/latest-stable/#/v${release}/#g' /etc/apk/repositories && grep -q '/v${release}/' /etc/apk/repositories"
}

wait_for_running() {
  local deadline=$(( $(date +%s) + 180 ))
  while (( $(date +%s) < deadline )); do
    if [[ "$(get_ct_status "$CTID")" == "running" ]] \
      && ct_exec --timeout 5 "$CTID" 'true' >/dev/null 2>&1; then
      return 0
    fi
    sleep 3
  done
  echo "ERROR: CT ${CTID} did not become ready." >&2
  return 1
}

reboot_and_wait() {
  local old_boot_id="$1" deadline=$(( $(date +%s) + 180 )) current_boot_id
  pct reboot "$CTID"
  while (( $(date +%s) < deadline )); do
    current_boot_id=$(ct_exec --timeout 5 "$CTID" 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null || true)
    if [[ -n "$current_boot_id" && "$current_boot_id" != "$old_boot_id" ]]; then
      return 0
    fi
    sleep 3
  done
  echo "ERROR: CT ${CTID} did not complete its reboot." >&2
  return 1
}

rollback() {
  local exit_code=$?
  trap - ERR
  [[ "$COMMITTED" == "false" ]] || exit "$exit_code"

  capture_failure_diagnostics || true

  if [[ "$KEEP_FAILED" == "true" ]]; then
    echo "[!] Upgrade failed; CT ${CTID} was left at the failed state by --keep-failed." >&2
    echo "    Rollback point: ${ZFS_SNAPSHOT:-$SNAPSHOT_NAME}" >&2
    echo "    Diagnostics: ${DIAGNOSTIC_LOG}" >&2
    exit "$exit_code"
  fi

  if [[ "$SNAPSHOT_CREATED" != "true" ]]; then
    if [[ "$ORIGINAL_STATUS" == "running" && "$(get_ct_status "$CTID")" != "running" ]]; then
      pct start "$CTID" || true
    fi
    exit "$exit_code"
  fi

  echo "[!] Upgrade failed; rolling CT ${CTID} back to ${SNAPSHOT_NAME}." >&2
  if [[ "$(get_ct_status "$CTID")" == "running" ]]; then
    pct stop "$CTID" || true
  fi
  if [[ "$SNAPSHOT_METHOD" == "zfs" ]]; then
    zfs rollback -r "$ZFS_SNAPSHOT"
  elif ! pct rollback "$CTID" "$SNAPSHOT_NAME"; then
    echo "[✗] Automatic rollback failed. Snapshot '${SNAPSHOT_NAME}' is retained." >&2
    exit "$exit_code"
  fi
  if [[ "$ORIGINAL_STATUS" == "running" ]]; then
    pct start "$CTID"
  fi
  echo "[✓] CT ${CTID} restored to its pre-upgrade snapshot." >&2
  exit "$exit_code"
}

capture_failure_diagnostics() {
  DIAGNOSTIC_LOG="$RUN_LOG_FILE"
  {
    echo "=== upgrade failure diagnostics ==="
    echo "CT ${CTID} (${CT_HOSTNAME}) upgrade failure diagnostics"
    echo "Captured: $(date -Is)"
    pct status "$CTID" 2>&1 || true
    pct exec "$CTID" -- sh -c '
      echo "=== Alpine ==="
      cat /etc/alpine-release 2>&1 || true
      echo "=== Docker packages ==="
      apk info -v 2>&1 | grep -E "^(docker|containerd|runc|iptables|nftables)" || true
      echo "=== OpenRC ==="
      rc-service docker status 2>&1 || true
      rc-update show default 2>&1 | grep -E "docker|containerd|network" || true
      echo "=== daemon.json ==="
      cat /etc/docker/daemon.json 2>&1 || true
      echo "=== processes ==="
      ps w 2>&1 | grep -E "dockerd|containerd" | grep -v grep || true
      echo "=== Docker log ==="
      cat /var/log/docker.log 2>&1 || true
      echo "=== system messages ==="
      tail -n 300 /var/log/messages 2>&1 | grep -Ei "docker|containerd|runc|cgroup|iptables|nft" || true
    ' || true
  }
  echo "[i] Failure diagnostics appended to ${DIAGNOSTIC_LOG}" >&2
}

create_rollback_point() {
  local rootfs volume root_path dataset snapshot_error

  rootfs=$(pct config "$CTID" 2>/dev/null | sed -n 's/^rootfs:[[:space:]]*//p')
  volume="${rootfs%%,*}"
  root_path=$(pvesm path "$volume" 2>/dev/null || true)
  dataset=$(zfs list -H -o name "$root_path" 2>/dev/null || true)
  if [[ -n "$dataset" ]]; then
    ZFS_SNAPSHOT="${dataset}@${SNAPSHOT_NAME}"
    zfs snapshot "$ZFS_SNAPSHOT"
    SNAPSHOT_METHOD="zfs"
    SNAPSHOT_CREATED=true
    echo "  [✓] Rootfs ZFS snapshot created: ${ZFS_SNAPSHOT}"
    return 0
  fi

  if snapshot_error=$(pct snapshot "$CTID" "$SNAPSHOT_NAME" \
    --description "Before Alpine upgrade" 2>&1); then
    SNAPSHOT_METHOD="pct"
    SNAPSHOT_CREATED=true
    echo "  [✓] CT snapshot created: ${SNAPSHOT_NAME}"
    return 0
  fi

  echo "ERROR: Unable to create a rollback point: ${snapshot_error}" >&2
  return 1
}

repair_buildkit_metadata() {
  local release="$1" archive

  if ! ct_exec --timeout 15 "$CTID" \
    'grep -q "fatal error: fault" /var/log/docker.log && grep -q "builder/builder-next" /var/log/docker.log && grep -q "go.etcd.io/bbolt" /var/log/docker.log' \
    >/dev/null 2>&1; then
    return 1
  fi

  archive="/var/lib/docker/buildkit.pre-alpine-${release//./-}-$(date +%Y%m%d%H%M%S)"
  echo "  [!] Docker BuildKit metadata crashed in bbolt; archiving it for recovery..."
  ct_exec --timeout 60 "$CTID" "
    rc-service docker stop >/dev/null 2>&1 || true
    if [ -d /var/lib/docker/buildkit ]; then
      mv /var/lib/docker/buildkit '$archive'
    fi
    rc-service docker start
  "
  echo "  [i] Previous BuildKit cache metadata retained at ${archive}"
}

ensure_upgrade_docker() {
  local release="$1"

  if ensure_docker_running "$CTID" 30; then
    return 0
  fi
  repair_buildkit_metadata "$release" || return 1
  ensure_docker_running "$CTID" 30
}

upgrade_release() {
  local release="$1" actual boot_id
  echo "Upgrading Alpine to ${release}..."
  ct_exec --timeout 30 "$CTID" "$(rewrite_repositories_command "$release")"
  ct_exec --timeout 900 "$CTID" 'apk update && apk upgrade --available --no-cache'
  boot_id=$(ct_exec --timeout 15 "$CTID" 'cat /proc/sys/kernel/random/boot_id')
  reboot_and_wait "$boot_id"
  actual=$(read_ct_release)
  [[ "$actual" == "$release" ]] || {
    echo "ERROR: Expected Alpine ${release} after reboot, found ${actual}." >&2
    return 1
  }
  ensure_upgrade_docker "$release"
  echo "  [✓] Alpine ${release} is running"
}

verify_workload() {
  ensure_docker_runlevel "$CTID"
  configure_docker_watchdog "$CTID"
  ensure_docker_running "$CTID" 30
  ct_exec --timeout 30 "$CTID" 'docker compose version >/dev/null && cd /mnt/docker && docker compose config --quiet'
  ct_exec --timeout 120 "$CTID" 'cd /mnt/docker && docker compose up -d --remove-orphans'
  echo "  [✓] Docker and Compose workload verified"
}

warn_storage_health() {
  check_ct_storage_health "$CTID" warn
}

collect_upgrade_candidates() {
  local target="$1" id current
  local candidates=()

  for id in "${CT_LIST[@]}"; do
    CTID="$id"
    if ! current=$(normalize_release "$(read_ct_release 2>/dev/null)" 2>/dev/null); then
      continue
    fi
    if (( $(release_minor "$current") < $(release_minor "$target") )); then
      candidates+=("$id")
    fi
  done

  CT_LIST=("${candidates[@]}")
}

reset_upgrade_state() {
  ORIGINAL_STATUS=""
  SNAPSHOT_NAME=""
  SNAPSHOT_CREATED=false
  SNAPSHOT_METHOD=""
  ZFS_SNAPSHOT=""
  COMMITTED=false
  DIAGNOSTIC_LOG=""
  PREPARED_CURRENT=""
}

prepare_upgrade() {
  local id="$1" target="$2" current lock

  CTID="$id"
  CT_HOSTNAME="${CT_MAP[$CTID]}"
  ORIGINAL_STATUS=$(get_ct_status "$CTID")
  [[ "$ORIGINAL_STATUS" == "running" || "$ORIGINAL_STATUS" == "stopped" ]] || {
    echo "ERROR: Unsupported CT status '${ORIGINAL_STATUS}'." >&2
    return 1
  }
  lock=$(pct config "$CTID" 2>/dev/null | sed -n 's/^lock:[[:space:]]*//p' || true)
  [[ -z "$lock" ]] || {
    echo "ERROR: CT ${CTID} is locked (${lock})." >&2
    return 1
  }
  current=$(normalize_release "$(read_ct_release)") || {
    echo "ERROR: CT ${CTID} is not running a supported Alpine 3.x release." >&2
    return 1
  }
  if (( $(release_minor "$target") < $(release_minor "$current") )); then
    echo "ERROR: Downgrades are not supported (${current} -> ${target})." >&2
    return 1
  fi

  PREPARED_CURRENT="$current"
}

print_upgrade_preview() {
  local id="$1" target="$2" current="$3"
  local release_path=()
  mapfile -t release_path < <(build_release_path "$current" "$target")

  echo "CT ${id} (${CT_MAP[$id]}): Alpine ${current} -> ${target}"
  if [[ ${#release_path[@]} -eq 0 ]]; then
    echo "Already at the requested release; no changes needed."
  else
    echo "Release path: ${release_path[*]}"
  fi
}

prepare_upgrade_bridge() {
  local dry_run="${1:-false}"
  bridge_policy_resolve "$(hostname -s)" CT "$CTID" "$CT_HOSTNAME" || return 1
  echo "Bridge policy: ${BRIDGE_POLICY_SELECTED} (${BRIDGE_POLICY_REASON}, rank ${BRIDGE_POLICY_RANK})"
  bridge_policy_reconcile_guest "$(hostname -s)" CT "$CTID" "$BRIDGE_POLICY_SELECTED" "$dry_run"
}

perform_upgrade() {
  local current="$1" target="$2" release
  local release_path=()
  mapfile -t release_path < <(build_release_path "$current" "$target")
  [[ ${#release_path[@]} -gt 0 ]] || return 0

  warn_storage_health
  trap rollback ERR
  if [[ "$(get_ct_status "$CTID")" == "running" ]]; then
    pct shutdown "$CTID" --timeout 60 || pct stop "$CTID"
    ensure_ct_stopped "$CTID"
  fi
  SNAPSHOT_NAME="pre-alpine-${current//./-}-$(date +%Y%m%d%H%M%S)"
  create_rollback_point

  pct start "$CTID"
  wait_for_running
  ensure_upgrade_docker "$current"
  reconcile_compose_permissions "$CTID"
  for release in "${release_path[@]}"; do
    upgrade_release "$release"
  done
  verify_workload

  if [[ "$ORIGINAL_STATUS" == "stopped" ]]; then
    pct shutdown "$CTID" --timeout 60 || pct stop "$CTID"
    ensure_ct_stopped "$CTID"
  fi
  COMMITTED=true
  trap - ERR
  if [[ "$SNAPSHOT_METHOD" == "zfs" ]]; then
    echo "Upgrade completed. Snapshot retained: ${ZFS_SNAPSHOT}"
  else
    echo "Upgrade completed. Snapshot retained: ${SNAPSHOT_NAME}"
  fi
}

main() {
  lifecycle_log_init "${BASH_SOURCE[0]}" "$@"
  local ct_arg="" target answer id current index total has_upgrades=false
  local cts_to_process=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target) [[ $# -ge 2 ]] || { echo "ERROR: --target requires a value." >&2; exit 1; }; TARGET_RELEASE="$2"; shift 2 ;;
      --dry-run) DRY_RUN=true; shift ;;
      --force) FORCE=true; shift ;;
      --keep-failed) KEEP_FAILED=true; shift ;;
      -h|--help) usage; exit 0 ;;
      -*) echo "ERROR: Unknown option '$1'." >&2; usage; exit 1 ;;
      *) [[ -z "$ct_arg" ]] || { echo "ERROR: Only one CT may be upgraded." >&2; exit 1; }; ct_arg="$1"; shift ;;
    esac
  done

  [[ $EUID -eq 0 ]] || { echo "ERROR: Run upgradeCT.sh as root on the Proxmox host." >&2; exit 1; }
  build_ct_list
  target=$(normalize_release "${TARGET_RELEASE:-$(detect_default_target)}") || { echo "ERROR: Invalid target release '${TARGET_RELEASE}'." >&2; exit 1; }

  if [[ -n "$ct_arg" ]]; then
    resolve_ct_from_input "$ct_arg" || exit 1
    cts_to_process=("$CTID")
  else
    collect_upgrade_candidates "$target"
    if [[ ${#CT_LIST[@]} -eq 0 ]]; then
      echo "No containers are eligible for upgrade to Alpine ${target}."
      exit 0
    fi
    select_ct_interactive_multi "upgrade" || exit 1
    cts_to_process=("${SELECTED_CTS[@]}")
  fi

  for id in "${cts_to_process[@]}"; do
    reset_upgrade_state
    prepare_upgrade "$id" "$target" || exit 1
    current="$PREPARED_CURRENT"
    print_upgrade_preview "$id" "$target" "$current"
    prepare_upgrade_bridge true || exit 1
    if (( $(release_minor "$current") < $(release_minor "$target") )); then
      has_upgrades=true
    fi
  done
  [[ "$has_upgrades" == "true" ]] || exit 0
  echo "Rollback protects the CT root filesystem; bind-mounted application data is unchanged."
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[dry-run] No changes made."
    exit 0
  fi

  if [[ "$FORCE" != "true" ]]; then
    read -rp "Create rollback points and upgrade ${#cts_to_process[@]} selected CT(s)? [y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
  fi

  total=${#cts_to_process[@]}
  for index in "${!cts_to_process[@]}"; do
    id="${cts_to_process[$index]}"
    reset_upgrade_state
    prepare_upgrade "$id" "$target" || exit 1
    current="$PREPARED_CURRENT"
    echo "[$((index + 1))/${total}] Upgrading CT ${id} (${CT_MAP[$id]})"
    prepare_upgrade_bridge false || exit 1
    perform_upgrade "$current" "$target"
  done
  echo "All ${total} selected CT(s) upgraded successfully."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi