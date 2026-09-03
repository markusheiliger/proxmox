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

# Load a docker-compose .env file into the environment, treating each value as a
# LITERAL string (no shell expansion, command substitution, or quote evaluation).
# This makes the CT's .env the single source of truth for configure.sh, mirroring
# how Docker Compose itself reads it. The naive `. ./.env` is unsafe here because
# busybox sh would interpret spaces, '#', quotes and '$' in values.
#
# Parsing rules (kept close to Compose's .env semantics):
#   - blank lines and lines whose first non-space char is '#' are skipped
#   - a leading `export ` prefix is tolerated and stripped
#   - the key is everything left of the first '=' (trimmed); the value is the rest
#   - one layer of matching surrounding single or double quotes is removed
#   - the value is exported verbatim; it is never evaluated by the shell
# Args: $1 = path to the .env file (missing file is a no-op)
load_env_file() {
  _lef_file="$1"
  [ -f "$_lef_file" ] || return 0
  while IFS= read -r _lef_line || [ -n "$_lef_line" ]; do
    # Strip a trailing CR (in case the file has CRLF line endings).
    _lef_line=${_lef_line%$(printf '\r')}
    # Skip blank lines and comments (allow leading whitespace before '#').
    case "$_lef_line" in
      ''|'#'*) continue ;;
      *) ;;
    esac
    _lef_trim=${_lef_line#"${_lef_line%%[![:space:]]*}"}
    case "$_lef_trim" in
      ''|'#'*) continue ;;
    esac
    # Tolerate an optional `export ` prefix.
    case "$_lef_trim" in
      export\ *) _lef_trim=${_lef_trim#export } ;;
    esac
    # A line without '=' is not a valid assignment; skip it.
    case "$_lef_trim" in
      *=*) ;;
      *) continue ;;
    esac
    _lef_key=${_lef_trim%%=*}
    _lef_val=${_lef_trim#*=}
    # Trim surrounding whitespace from the key only.
    _lef_key=${_lef_key#"${_lef_key%%[![:space:]]*}"}
    _lef_key=${_lef_key%"${_lef_key##*[![:space:]]}"}
    [ -n "$_lef_key" ] || continue
    # Remove one layer of matching surrounding quotes from the value.
    case "$_lef_val" in
      \"*\") _lef_val=${_lef_val#\"}; _lef_val=${_lef_val%\"} ;;
      \'*\') _lef_val=${_lef_val#\'}; _lef_val=${_lef_val%\'} ;;
    esac
    export "${_lef_key}=${_lef_val}"
  done < "$_lef_file"
}
