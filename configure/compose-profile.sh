#!/bin/sh
# Resolve lifecycle-managed profiles or a legacy hardware selector before
# running Docker Compose.
set -eu

SELECTOR="${COMPOSE_PROFILE_SELECTOR:-/mnt/docker/_config/select-compose-profile.sh}"
COMPOSE_FILE="${COMPOSE_PROFILE_FILE:-/mnt/docker/docker-compose.yaml}"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
RESOLVER="${COMPOSE_PROFILE_RESOLVER:-${SCRIPT_DIR}/resolve-compose-profile.py}"
PROFILES_FILE="${COMPOSE_PROFILE_METADATA:-/mnt/pve-imds/profiles.json}"
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
  if [ -f "$COMPOSE_FILE" ] && [ -x "$RESOLVER" ]; then
    "$RESOLVER" --file "$COMPOSE_FILE" --validate >/dev/null
  fi
  unset COMPOSE_PROFILES
  VULKAN_DEVICE=/dev/null
  export VULKAN_DEVICE
  exec docker compose "$@"
fi

has_profiles=false
if [ -f "$COMPOSE_FILE" ] && [ -x "$RESOLVER" ]; then
  has_profiles=$($RESOLVER --file "$COMPOSE_FILE" --profiles-file "$PROFILES_FILE" --detect)
fi

if [ "$has_profiles" = true ] && [ -e "$SELECTOR" ]; then
  echo "ERROR: Compose stack has both managed service profiles and a legacy hardware selector." >&2
  exit 1
fi

if [ "$has_profiles" = true ]; then
  if [ ! -x "$RESOLVER" ]; then
    echo "ERROR: Compose profile resolver is not executable: $RESOLVER" >&2
    exit 1
  fi
  COMPOSE_PROFILES=$($RESOLVER --file "$COMPOSE_FILE" --profiles-file "$PROFILES_FILE")
  if [ -n "$COMPOSE_PROFILES" ]; then
    export COMPOSE_PROFILES
  else
    unset COMPOSE_PROFILES
  fi
elif [ ! -e "$SELECTOR" ]; then
  exec docker compose "$@"
elif [ ! -x "$SELECTOR" ]; then
  echo "ERROR: Compose hardware selector is not executable: $SELECTOR" >&2
  exit 1
else
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
  export COMPOSE_PROFILES
fi
export COMPOSE_PROFILES
exec docker compose "$@"
