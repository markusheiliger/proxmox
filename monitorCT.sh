#!/usr/bin/env bash
#
# monitorCT.sh - Stream Docker Compose logs from a container
# Documentation: monitorCT.md
#
# DESCRIPTION:
#   Streams combined logs from all Docker Compose services running
#   in an LXC container for real-time monitoring and validation.
#
# USAGE:
#   ./monitorCT.sh [CTID or hostname] [OPTIONS]
#
# OPTIONS:
#   -n, --tail LINES    Number of lines to show from end (default: 100)
#   -t, --timestamps    Show timestamps
#   --no-follow         Don't follow logs (show and exit)
#   -s, --service NAME  Filter to specific service(s), can repeat
#
# EXAMPLES:
#   ./monitorCT.sh                         # Interactive selection
#   ./monitorCT.sh 2100                    # Monitor by CTID
#   ./monitorCT.sh app.thesaints.home      # Monitor by hostname
#   ./monitorCT.sh app.thesaints.home -t   # With timestamps
#   ./monitorCT.sh 2100 -n 50              # Last 50 lines
#   ./monitorCT.sh 2100 -s caddy           # Only caddy service
#
# REQUIREMENTS:
#   - Run on Proxmox VE host as root
#   - Container must be running with Docker Compose
#
# SEE ALSO:
#   createCT.sh      Create a new container with Docker
#   refreshCT.sh     Refresh/update container configuration
#   deleteCT.sh      Delete a container
#   commonCT.sh      Shared functions
#
set -euo pipefail

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/commonCT.sh"

# Defaults - use docker compose logs defaults
TAIL_LINES=""
TIMESTAMPS=""
FOLLOW="-f"
SERVICES=()

# -----------------------------
# FUNCTIONS
# -----------------------------

# Show usage
usage() {
  echo "Usage: $0 [CTID or hostname] [OPTIONS]"
  echo ""
  echo "Options:"
  echo "  -n, --tail LINES    Number of lines to show (default: 100)"
  echo "  -t, --timestamps    Show timestamps"
  echo "  --no-follow         Don't follow logs"
  echo "  -s, --service NAME  Filter to specific service(s)"
  echo "  -h, --help          Show this help"
  exit 0
}

# Parse arguments
parse_args() {
  CT_ARG=""
  
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        ;;
      -n|--tail)
        TAIL_LINES="$2"
        shift 2
        ;;
      -t|--timestamps)
        TIMESTAMPS="-t"
        shift
        ;;
      --no-follow)
        FOLLOW=""
        shift
        ;;
      -s|--service)
        SERVICES+=("$2")
        shift 2
        ;;
      -*)
        echo "Unknown option: $1"
        usage
        ;;
      *)
        if [[ -z "$CT_ARG" ]]; then
          CT_ARG="$1"
        else
          # Additional positional args treated as services
          SERVICES+=("$1")
        fi
        shift
        ;;
    esac
  done
}

# Verify compose file exists
verify_compose() {
  get_ct_dirs "$CT_HOSTNAME"
  COMPOSE_FILE="${DIR_DOCKER}/docker-compose.yaml"
  
  if [[ ! -f "$COMPOSE_FILE" ]]; then
    # Try .yml extension
    COMPOSE_FILE="${DIR_DOCKER}/docker-compose.yml"
    if [[ ! -f "$COMPOSE_FILE" ]]; then
      echo "Error: No docker-compose.yaml found in ${DIR_DOCKER}"
      exit 1
    fi
  fi
}

# Stream the logs
stream_logs() {
  echo "Streaming logs from CT ${CTID} (${CT_HOSTNAME})..."
  echo "Compose file: ${COMPOSE_FILE}"
  echo "Press Ctrl+C to stop"
  echo "----------------------------------------"
  
  # Build docker compose command
  # Inside CT, /mnt/docker is mounted directly (not /mnt/docker/<hostname>)
  local cmd="docker compose -f /mnt/docker/docker-compose.yaml logs"
  [[ -n "$TAIL_LINES" ]] && cmd+=" --tail=${TAIL_LINES}"
  [[ -n "$FOLLOW" ]] && cmd+=" ${FOLLOW}"
  [[ -n "$TIMESTAMPS" ]] && cmd+=" ${TIMESTAMPS}"
  
  # Add service filters if specified
  if [[ ${#SERVICES[@]} -gt 0 ]]; then
    cmd+=" ${SERVICES[*]}"
  fi
  
  # Execute in container
  pct exec "$CTID" -- sh -c "$cmd"
}

# -----------------------------
# MAIN
# -----------------------------
main() {
  parse_args "$@"
  
  build_ct_list
  
  if [[ ${#CT_LIST[@]} -eq 0 ]]; then
    echo "No containers found."
    exit 0
  fi
  
  if [[ -z "$CT_ARG" ]]; then
    select_ct_interactive_single "monitor" || exit 1
  else
    resolve_ct_from_input "$CT_ARG" || exit 1
  fi
  
  status_bar_init
  
  status_update "Checking CT ${CTID} is running..."
  ensure_ct_running
  
  status_update "Verifying Docker Compose setup..."
  verify_compose
  
  status_bar_cleanup
  
  echo "Streaming logs for CT ${CTID} (${CT_HOSTNAME})..."
  echo ""
  stream_logs
}

main "$@"
