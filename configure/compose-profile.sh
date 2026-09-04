#!/bin/sh
# Select an optional hardware profile before running Docker Compose.
# Per-stack selector contract: /mnt/docker/_config/select-compose-profile.sh
# prints exactly: <profile>|<device>, where device is empty unless required.
set -eu

SELECTOR="${COMPOSE_PROFILE_SELECTOR:-/mnt/docker/_config/select-compose-profile.sh}"
MODE="selected"

if [ "${1:-}" = "--all-profiles" ]; then
  MODE="all"
  shift
fi

if [ "${1:-}" = "--" ]; then
  shift
fi

if [ "$#" -eq 0 ]; then
  echo "ERROR: compose-profile.sh requires Docker Compose arguments." >&2
  exit 2
fi

if [ "$MODE" = "all" ]; then
  unset COMPOSE_PROFILES
  VULKAN_DEVICE=/dev/null
  export VULKAN_DEVICE
  exec docker compose "$@"
fi

if [ ! -e "$SELECTOR" ]; then
  exec docker compose "$@"
fi
if [ ! -x "$SELECTOR" ]; then
  echo "ERROR: Compose hardware selector is not executable: $SELECTOR" >&2
  exit 1
fi

selection=$($SELECTOR)
case "$selection" in
  *'|'*'|'*)
    echo "ERROR: Compose hardware selector returned malformed output." >&2
    exit 1
    ;;
  *'|'*) ;;
  *)
    echo "ERROR: Compose hardware selector did not return profile|device." >&2
    exit 1
    ;;
esac

profile=${selection%%|*}
device=${selection#*|}
case "$profile" in
  no-discrete-gpu)
    if [ -n "$device" ]; then
      echo "ERROR: no-discrete-gpu profile must not specify a device." >&2
      exit 1
    fi
    unset VULKAN_DEVICE
    ;;
  vulkan)
    if ! printf '%s\n' "$device" | grep -Eq '^/dev/dri/renderD[0-9]+$'; then
      echo "ERROR: Vulkan selector returned an unsafe device path." >&2
      exit 1
    fi
    if [ ! -c "$device" ] || [ ! -r "$device" ] || [ ! -w "$device" ]; then
      echo "ERROR: Vulkan device is not accessible: $device" >&2
      exit 1
    fi
    VULKAN_DEVICE=$device
    export VULKAN_DEVICE
    ;;
  *)
    echo "ERROR: Unsupported hardware profile: $profile" >&2
    exit 1
    ;;
esac

COMPOSE_PROFILES=$profile
if [ -f /mnt/docker/.env ] \
  && grep -q '^NEWT_ID=.' /mnt/docker/.env \
  && grep -q '^NEWT_SECRET=.' /mnt/docker/.env \
  && grep -q '^NEWT_ENDPOINT=.' /mnt/docker/.env; then
  COMPOSE_PROFILES="${COMPOSE_PROFILES},published"
fi
export COMPOSE_PROFILES
exec docker compose "$@"
