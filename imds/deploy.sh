#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PVESH="${PVE_IMDS_PVESH:-/usr/bin/pvesh}"
SSH="${PVE_IMDS_SSH:-/usr/bin/ssh}"
LOCAL_NODE="${PVE_IMDS_LOCAL_NODE:-$(hostname -s)}"
BUILD_SCRIPT="${PVE_IMDS_BUILD_SCRIPT:-${SCRIPT_DIR}/build-execfuse.sh}"
INSTALLER="${PVE_IMDS_INSTALLER:-${SCRIPT_DIR}/scripts/install-release.sh}"
CLUSTER_CONFIG_ROOT="${PVE_IMDS_CLUSTER_CONFIG_ROOT:-/etc/pve/nodes}"
VERIFY_RUNTIME_ROOT="${PVE_IMDS_VERIFY_RUNTIME_ROOT:-/usr/local/libexec/pve-imds}"
VERIFY_HEALTH_PATH="${PVE_IMDS_VERIFY_HEALTH_PATH:-/usr/local/sbin/pve-imds-health}"
VERIFY_UNIT_PATH="${PVE_IMDS_VERIFY_UNIT_PATH:-/etc/systemd/system/pve-imds.service}"
VERIFY_PROC_ROOT="${PVE_IMDS_VERIFY_PROC_ROOT:-/proc}"
VERIFY_SYSTEMCTL="${PVE_IMDS_VERIFY_SYSTEMCTL:-systemctl}"
ACTION=install

usage() {
  cat <<'EOF'
Usage: deploy.sh [--verify|--remove|--help]

With no argument, build and install or upgrade pve-imds on every online
Proxmox node. --verify reports installation and health on every cluster node.
--remove uninstalls it after proving no CT configuration still contains an
IMDS bind mount.
EOF
}

case "${1:-}" in
  "") ;;
  --verify) ACTION=verify ;;
  --remove) ACTION=remove ;;
  --help) usage; exit 0 ;;
  *) usage >&2; exit 64 ;;
esac
[[ $# -le 1 ]] || { usage >&2; exit 64; }
[[ $EUID -eq 0 ]] || { echo "ERROR: deploy.sh must run as root." >&2; exit 77; }

[[ -x "$PVESH" ]] || { echo "ERROR: pvesh is unavailable: ${PVESH}" >&2; exit 69; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is unavailable." >&2; exit 69; }

nodes_json="$($PVESH get /nodes --output-format json)" || {
  echo "ERROR: cannot query Proxmox nodes." >&2
  exit 69
}
if ! jq -e 'type == "array" and all(.[]; (.node | type == "string") and (.status | type == "string"))' \
  <<<"$nodes_json" >/dev/null; then
  echo "ERROR: Proxmox returned an invalid node inventory." >&2
  exit 69
fi
mapfile -t all_nodes < <(jq -r '.[].node' <<<"$nodes_json" | sort -u)
mapfile -t online_nodes < <(jq -r '.[] | select(.status == "online") | .node' <<<"$nodes_json" | sort)
mapfile -t offline_nodes < <(jq -r '.[] | select(.status != "online") | .node' <<<"$nodes_json" | sort)
(( ${#all_nodes[@]} > 0 )) || { echo "ERROR: no Proxmox nodes found." >&2; exit 69; }
if [[ "$ACTION" != verify && ${#online_nodes[@]} -eq 0 ]]; then
  echo "ERROR: no online Proxmox nodes found." >&2
  exit 69
fi

remote_nodes=false
for node in "${online_nodes[@]}"; do
  [[ "$node" == "$LOCAL_NODE" ]] || remote_nodes=true
done
if [[ "$remote_nodes" == true && ! -x "$SSH" ]]; then
  echo "ERROR: ssh is unavailable: ${SSH}" >&2
  exit 69
fi

emit_verify_script() {
  cat <<'VERIFY_SCRIPT'
set -euo pipefail

[[ $# -eq 5 ]] || exit 64
runtime_root="$1"
health_path="$2"
unit_path="$3"
proc_root="$4"
systemctl_command="$5"
marker="$runtime_root/.pve-imds-managed"
current="$runtime_root/current"

artifact_count=0
for artifact in "$marker" "$current" "$unit_path" "$health_path"; do
  [[ -e "$artifact" || -L "$artifact" ]] && artifact_count=$((artifact_count + 1))
done
if ((artifact_count == 0)); then
  printf 'NOT INSTALLED\t-\t-\tmanaged artifacts are absent\n'
  exit 0
fi
if ((artifact_count != 4)) || [[ ! -f "$marker" || -L "$marker" || ! -L "$current" \
  || ! -f "$unit_path" || -L "$unit_path" || ! -f "$health_path" \
  || -L "$health_path" || ! -x "$health_path" ]]; then
  printf 'BROKEN\t-\t-\tmanaged installation is incomplete\n'
  exit 0
fi
if [[ "$(cat "$marker" 2>/dev/null || true)" != pve-imds ]]; then
  printf 'BROKEN\t-\t-\tmanaged installation marker is invalid\n'
  exit 0
fi

current_target="$(readlink "$current")"
if [[ "$current_target" =~ ^releases/([a-f0-9]{16})$ ]]; then
  current_release="${BASH_REMATCH[1]}"
else
  printf 'BROKEN\t-\t-\tcurrent release link is invalid\n'
  exit 0
fi
if [[ ! -x "$runtime_root/$current_target/execfuse" ]]; then
  printf 'BROKEN\t%s\t-\tcurrent release executable is absent\n' "$current_release"
  exit 0
fi

if ! health_output="$($health_path 2>&1)"; then
  health_output="${health_output//$'\n'/; }"
  health_output="${health_output//$'\t'/ }"
  printf 'UNHEALTHY\t%s\t-\t%s\n' "$current_release" "${health_output:-health check failed}"
  exit 0
fi

main_pid="$($systemctl_command show pve-imds.service -p MainPID --value 2>/dev/null || true)"
if [[ ! "$main_pid" =~ ^[1-9][0-9]*$ ]]; then
  printf 'BROKEN\t%s\t-\tactive service has no main process\n' "$current_release"
  exit 0
fi
running_executable="$(readlink -f "$proc_root/$main_pid/exe" 2>/dev/null || true)"
active_release="${running_executable#"$runtime_root/releases/"}"
active_release="${active_release%/execfuse}"
if [[ "$running_executable" != "$runtime_root/releases/$active_release/execfuse" \
  || ! "$active_release" =~ ^[a-f0-9]{16}$ ]]; then
  printf 'BROKEN\t%s\t-\trunning executable is outside a managed release\n' "$current_release"
  exit 0
fi

if [[ "$active_release" != "$current_release" ]]; then
  printf 'STAGED\t%s\t%s\tactive release differs from current release\n' \
    "$current_release" "$active_release"
else
  printf 'HEALTHY\t%s\t%s\tservice and metadata are healthy\n' \
    "$current_release" "$active_release"
fi
VERIFY_SCRIPT
}

run_verify() {
  local node="$1"
  if [[ "$node" == "$LOCAL_NODE" ]]; then
    emit_verify_script | bash -s -- "$VERIFY_RUNTIME_ROOT" "$VERIFY_HEALTH_PATH" \
      "$VERIFY_UNIT_PATH" "$VERIFY_PROC_ROOT" "$VERIFY_SYSTEMCTL"
  else
    emit_verify_script | "$SSH" -o BatchMode=yes -o ConnectTimeout=10 \
      -o ServerAliveInterval=5 -o ServerAliveCountMax=3 "$node" 'bash -s' -- \
      "$VERIFY_RUNTIME_ROOT" "$VERIFY_HEALTH_PATH" "$VERIFY_UNIT_PATH" \
      "$VERIFY_PROC_ROOT" "$VERIFY_SYSTEMCTL"
  fi
}

if [[ "$ACTION" == verify ]]; then
  declare -A node_status=()
  declare -A node_detail=()
  declare -A node_current=()
  declare -A node_active=()
  declare -A node_is_online=()
  declare -A status_count=()
  statuses=(HEALTHY STAGED "NOT INSTALLED" BROKEN UNHEALTHY UNREACHABLE UNVERIFIED)
  for status in "${statuses[@]}"; do
    status_count["$status"]=0
  done
  for node in "${online_nodes[@]}"; do
    node_is_online["$node"]=true
  done

  failed=false
  for node in "${all_nodes[@]}"; do
    if [[ "${node_is_online[$node]:-false}" != true ]]; then
      status="UNVERIFIED"
      current_release="-"
      active_release="-"
      detail="node is offline"
    elif result="$(run_verify "$node")"; then
      IFS=$'\t' read -r status current_release active_release detail <<<"$result"
      if [[ ! " ${statuses[*]} " == *" ${status} "* || -z "$detail" ]]; then
        status="BROKEN"
        current_release="-"
        active_release="-"
        detail="verification returned an invalid response"
      fi
    else
      status="UNREACHABLE"
      current_release="-"
      active_release="-"
      detail="verification command failed"
    fi
    node_status["$node"]="$status"
    node_current["$node"]="$current_release"
    node_active["$node"]="$active_release"
    node_detail["$node"]="$detail"
    status_count["$status"]=$((status_count["$status"] + 1))
    [[ "$status" == HEALTHY ]] || failed=true
  done

  for node in "${all_nodes[@]}"; do
    status="${node_status[$node]}"
    if [[ "$status" == HEALTHY || "$status" == STAGED ]]; then
      printf '%s: %s current=%s active=%s - %s\n' "$node" "$status" \
        "${node_current[$node]}" "${node_active[$node]}" "${node_detail[$node]}"
    else
      printf '%s: %s - %s\n' "$node" "$status" "${node_detail[$node]}"
    fi
  done
  printf 'Summary:'
  for status in "${statuses[@]}"; do
    printf ' %s=%d' "${status// /_}" "${status_count[$status]}"
  done
  printf '\n'
  [[ "$failed" == false ]]
  exit
fi

for source_path in \
  "$BUILD_SCRIPT" \
  "$INSTALLER" \
  "$SCRIPT_DIR/scripts/pve-imds-health" \
  "$SCRIPT_DIR/systemd/pve-imds.service" \
  "$SCRIPT_DIR/lib/pve-imds-generate" \
  "$SCRIPT_DIR/lib/hook-common.sh" \
  "$SCRIPT_DIR/filters/redact.jq" \
  "$SCRIPT_DIR/filters/profiles.jq" \
  "$SCRIPT_DIR/hooks/check_args" \
  "$SCRIPT_DIR/hooks/getattr" \
  "$SCRIPT_DIR/hooks/readdir" \
  "$SCRIPT_DIR/hooks/open" \
  "$SCRIPT_DIR/hooks/read_file"; do
  [[ -f "$source_path" ]] || { echo "ERROR: missing source file: ${source_path}" >&2; exit 66; }
done

run_installer() {
  local node="$1" bundle="$2" release_id="$3" remote_command
  if [[ "$node" == "$LOCAL_NODE" ]]; then
    "$INSTALLER" "$bundle" "$release_id"
    return
  fi
  remote_command='set -e; d=$(mktemp -d); trap '\''rm -rf "$d"'\'' EXIT; tar -C "$d" -xf -; release_id=$(cat "$d/release-id"); "$d/install-release.sh" "$d" "$release_id"'
  tar -C "$bundle" -cf - . | "$SSH" -o BatchMode=yes -o ConnectTimeout=10 \
    -o ServerAliveInterval=5 -o ServerAliveCountMax=3 "$node" "$remote_command"
}

run_remove() {
  local node="$1"
  if [[ "$node" == "$LOCAL_NODE" ]]; then
    "$INSTALLER" --remove
  else
    "$SSH" -o BatchMode=yes -o ConnectTimeout=10 \
      -o ServerAliveInterval=5 -o ServerAliveCountMax=3 "$node" \
      'bash -s -- --remove' <"$INSTALLER"
  fi
}

node_architecture() {
  local node="$1"
  if [[ "$node" == "$LOCAL_NODE" ]]; then
    dpkg --print-architecture
  else
    "$SSH" -o BatchMode=yes -o ConnectTimeout=10 \
      -o ServerAliveInterval=5 -o ServerAliveCountMax=3 "$node" \
      'dpkg --print-architecture'
  fi
}

if [[ "$ACTION" == remove ]]; then
  consumers="$(find "$CLUSTER_CONFIG_ROOT" -path '*/lxc/*.conf' -type f -exec \
    awk '/^mp[0-9]+:/ && ($0 ~ /(^|[, ])\/run\/pve-imds\/[0-9]+([, ]|$)/ || $0 ~ /(^|,)mp=\/run\/pve-imds(,|$)/) { print FILENAME ":" NR ":" $0 }' {} + 2>/dev/null || true)"
  if [[ -n "$consumers" ]]; then
    echo "ERROR: refusing removal while CT configurations consume IMDS:" >&2
    printf '%s\n' "$consumers" >&2
    exit 73
  fi

  failed=false
  for node in "${online_nodes[@]}"; do
    echo "Removing pve-imds from ${node}..."
    run_remove "$node" || failed=true
  done
  for node in "${offline_nodes[@]}"; do
    echo "PENDING: ${node} is offline and was not removed." >&2
    failed=true
  done
  [[ "$failed" == false ]]
  exit
fi

for command in curl make pkg-config tar sha256sum install jq; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "ERROR: missing local build prerequisite: ${command}" >&2
    echo "Install build-essential pkg-config libfuse-dev curl jq first." >&2
    exit 69
  }
done
pkg-config --exists fuse || {
  echo "ERROR: libfuse development files are unavailable; install libfuse-dev." >&2
  exit 69
}

local_architecture="$(dpkg --print-architecture)"
[[ "$local_architecture" == amd64 ]] || {
  echo "ERROR: unsupported build architecture: ${local_architecture}" >&2
  exit 69
}
for node in "${online_nodes[@]}"; do
  architecture="$(node_architecture "$node")" || {
    echo "ERROR: cannot determine architecture for ${node}." >&2
    exit 69
  }
  [[ "$architecture" == "$local_architecture" ]] || {
    echo "ERROR: ${node} uses unsupported architecture ${architecture}; expected ${local_architecture}." >&2
    exit 69
  }
done

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
bundle="${work_dir}/bundle"
release="${bundle}/release"
mkdir -p "$release/hooks" "$release/lib" "$release/filters"

"$BUILD_SCRIPT" "$release/execfuse"
install -m 0755 "$SCRIPT_DIR"/hooks/{check_args,getattr,readdir,open,read_file} "$release/hooks/"
install -m 0755 "$SCRIPT_DIR/lib/pve-imds-generate" "$release/lib/"
install -m 0644 "$SCRIPT_DIR/lib/hook-common.sh" "$release/lib/"
install -m 0644 "$SCRIPT_DIR"/filters/{redact.jq,profiles.jq} "$release/filters/"

manifest="${work_dir}/checksums.sha256"
(
  cd "$release"
  find . -type f -print0 | sort -z | xargs -0 sha256sum >"$manifest"
)
install -m 0644 "$manifest" "$release/checksums.sha256"
install -m 0755 "$INSTALLER" "$bundle/install-release.sh"
install -m 0755 "$SCRIPT_DIR/scripts/pve-imds-health" "$bundle/pve-imds-health"
install -m 0644 "$SCRIPT_DIR/systemd/pve-imds.service" "$bundle/pve-imds.service"
(
  cd "$bundle"
  sha256sum release/checksums.sha256 pve-imds-health pve-imds.service >bundle-checksums.sha256
)
release_id="$(sha256sum "$bundle/bundle-checksums.sha256" | awk '{print substr($1, 1, 16)}')"
printf '%s\n' "$release_id" >"$bundle/release-id"

failed=false
for node in "${online_nodes[@]}"; do
  echo "Deploying pve-imds ${release_id} to ${node}..."
  if run_installer "$node" "$bundle" "$release_id"; then
    :
  elif [[ $? -eq 10 ]]; then
    echo "PENDING: ${node} staged ${release_id}; restart deferred for active CT binds." >&2
    failed=true
  else
    echo "ERROR: deployment failed on ${node}." >&2
    failed=true
  fi
done
for node in "${offline_nodes[@]}"; do
  echo "PENDING: ${node} is offline and was not deployed." >&2
  failed=true
done

[[ "$failed" == false ]]