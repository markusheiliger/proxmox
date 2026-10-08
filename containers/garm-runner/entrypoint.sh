#!/usr/bin/env bash
set -euo pipefail

readonly CREDENTIAL_DIR=/run/garm
readonly DELIVERY_MARKER="${CREDENTIAL_DIR}/.delivered"
readonly RUNNER_HOME=/home/runner
readonly RUNNER_USER=runner
readonly CREDENTIAL_WAIT_SECONDS="${GARM_CRED_WAIT_SECONDS:-120}"
readonly DOCKER_WAIT_SECONDS="${WAIT_FOR_DOCKER_SECONDS:-120}"

wait_for_delivery() {
  local deadline=$((SECONDS + CREDENTIAL_WAIT_SECONDS))
  until [[ -f "$DELIVERY_MARKER" ]]; do
    if (( SECONDS >= deadline )); then
      echo "Timed out waiting for GARM JIT credentials." >&2
      return 1
    fi
    sleep 1
  done
}

prepare_dind_access() {
  [[ -n "${DOCKER_HOST:-}" ]] || return 0

  local socket_gid="${DOCKER_SOCK_GID:-}"
  if [[ ! "$socket_gid" =~ ^[1-9][0-9]*$ ]]; then
    echo "DOCKER_SOCK_GID must be a positive integer when DOCKER_HOST is set." >&2
    return 1
  fi

  local socket_group
  socket_group=$(getent group "$socket_gid" | cut -d: -f1 || true)
  if [[ -z "$socket_group" ]]; then
    socket_group="garm-docker-${socket_gid}"
    groupadd --gid "$socket_gid" "$socket_group"
  fi
  usermod --append --groups "$socket_group" "$RUNNER_USER"

  local deadline=$((SECONDS + DOCKER_WAIT_SECONDS))
  until setpriv --reuid="$RUNNER_USER" --regid="$RUNNER_USER" --init-groups \
      docker info >/dev/null 2>&1; do
    if (( SECONDS >= deadline )); then
      echo "Timed out waiting for the private DinD daemon." >&2
      return 1
    fi
    sleep 1
  done
}

install_jit_credentials() {
  if [[ "${JIT_CONFIG_ENABLED:-}" != "true" ]]; then
    echo "This runner image requires GARM JIT configuration." >&2
    return 1
  fi

  local target source
  for target in .runner .credentials .credentials_rsaparams; do
    source="${CREDENTIAL_DIR}/${target#.}"
    if [[ ! -f "$source" ]]; then
      echo "Missing GARM JIT credential file: ${source}" >&2
      return 1
    fi
    ln --symbolic --force "$source" "${RUNNER_HOME}/${target}"
  done
}

prepare_workdir() {
  local workdir="${RUNNER_WORKDIR:-${RUNNER_HOME}/_work}"
  mkdir -p "$workdir"
  chown "$RUNNER_USER:$RUNNER_USER" "$workdir"
}

wait_for_delivery
prepare_dind_access
install_jit_credentials
prepare_workdir

exec setpriv --reuid="$RUNNER_USER" --regid="$RUNNER_USER" --init-groups \
  "${RUNNER_HOME}/run.sh"