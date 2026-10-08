#!/usr/bin/env bash
set -euo pipefail

IMAGE="${1:?usage: test-image.sh <image>}"
EXPECTED_GARM_VERSION="${EXPECTED_GARM_VERSION:-v0.2.1}"
EXPECTED_PROVIDER_VERSION="${EXPECTED_PROVIDER_VERSION:-v0.2.0}"

label_version=$(docker image inspect \
  --format '{{index .Config.Labels "org.opencontainers.image.version"}}' "$IMAGE")
label_provider=$(docker image inspect \
  --format '{{index .Config.Labels "org.opencontainers.image.garm-provider-docker.version"}}' "$IMAGE")

[[ "$label_version" == "$EXPECTED_GARM_VERSION" ]]
[[ "$label_provider" == "$EXPECTED_PROVIDER_VERSION" ]]

docker run --rm --entrypoint /bin/sh "$IMAGE" -ec '
  test -x /bin/garm
  test -x /bin/garm-cli
  test -x /opt/garm/providers.d/garm-provider-docker
  test -x /usr/local/bin/healthcheck
'

entrypoint=$(docker image inspect --format '{{json .Config.Entrypoint}}' "$IMAGE")
[[ "$entrypoint" == '["/bin/garm","-config","/etc/garm/config.toml"]' ]]