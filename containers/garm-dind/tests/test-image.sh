#!/usr/bin/env bash
set -euo pipefail

IMAGE="${1:?usage: test-image.sh <image>}"
EXPECTED_DIND_VERSION="${EXPECTED_DIND_VERSION:-29.8.2}"

label_version=$(docker image inspect \
  --format '{{index .Config.Labels "org.opencontainers.image.version"}}' "$IMAGE")
[[ "$label_version" == "$EXPECTED_DIND_VERSION" ]]

docker run --rm --entrypoint /bin/sh "$IMAGE" -ec '
  command -v dockerd >/dev/null
  command -v docker >/dev/null
  dockerd --version
  docker --version
'

entrypoint=$(docker image inspect --format '{{json .Config.Entrypoint}}' "$IMAGE")
[[ "$entrypoint" == '["dockerd-entrypoint.sh"]' ]]