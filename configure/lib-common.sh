# shellcheck shell=sh
# lib-common.sh — shared POSIX-sh helpers for per-CT _config/configure.sh scripts.
#
# Sourced INSIDE the CT (busybox ash) as:
#     . /mnt/docker/_config/shared/lib-common.sh
#
# SOURCE OF TRUTH: /root/scripts/configure/ on the Proxmox host. This folder is
# mirrored into each CT's ${DIR_DOCKER}/_config/shared/ by sync_config_shared()
# in commonCT.sh. NEVER hand-edit the delivered copy under _config/shared.
#
# This library MUST remain POSIX sh (no bashisms) — it runs under busybox ash.

# Ensure required external tools are installed (idempotent, self-contained).
# Guarantees every CLI a configure.sh relies on is present before use.
# Args: $@ = command names (e.g. jq curl)
ensure_tools() {
  missing=""
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || missing="${missing} ${cmd}"
  done
  [ -z "$missing" ] && return 0
  echo "  Installing required tools:${missing}"
  if command -v apk >/dev/null 2>&1; then
    apk add --no-cache${missing} >/dev/null 2>&1
  elif command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq${missing} >/dev/null 2>&1
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q${missing} >/dev/null 2>&1
  else
    echo "  [!] No supported package manager to install:${missing}"
    return 1
  fi
  for cmd in $missing; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "  [!] Failed to install required tool: $cmd"; return 1; }
  done
  echo "  [✓] Required tools installed:${missing}"
}

# Create a persistent data directory and chown it to a service UID/GID.
# Docker creates missing bind-mount sources as root, so services that run as
# non-root users need their data dirs pre-owned (idempotent on every refresh).
# Args: $1 = path, $2 = uid, $3 = gid
ensure_data_dir() {
  _edd_path="$1"
  _edd_uid="$2"
  _edd_gid="$3"
  [ -n "$_edd_path" ] || { echo "  [!] ensure_data_dir: missing path"; return 1; }
  mkdir -p "$_edd_path"
  chown "${_edd_uid}:${_edd_gid}" "$_edd_path"
}
