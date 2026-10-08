#!/usr/bin/env bash
set -euo pipefail

IMAGE="${1:?usage: test-image.sh <image>}"
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
EXPECTED_VERSION="${EXPECTED_VERSION:-$(jq --exit-status --raw-output '."ddns-update"' "$SCRIPT_DIR/../../image-version.json")}"

label_version=$(docker image inspect \
  --format '{{index .Config.Labels "org.opencontainers.image.version"}}' "$IMAGE")
runtime_user=$(docker image inspect --format '{{.Config.User}}' "$IMAGE")
version=$(docker run --rm "$IMAGE" --version)

[[ "$label_version" == "$EXPECTED_VERSION" ]]
[[ "$version" == "$EXPECTED_VERSION" ]]
[[ "$runtime_user" == 10001:10001 ]]
docker run --rm "$IMAGE" --help >/dev/null