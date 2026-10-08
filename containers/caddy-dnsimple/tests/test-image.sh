#!/usr/bin/env bash
set -euo pipefail

IMAGE="${1:?usage: test-image.sh <image>}"
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
EXPECTED_VERSION="${EXPECTED_VERSION:-$(jq --exit-status --raw-output '."caddy-dnsimple"' "$SCRIPT_DIR/../../image-version.json")}"

label_version=$(docker image inspect \
  --format '{{index .Config.Labels "org.opencontainers.image.version"}}' "$IMAGE")
version=$(docker run --rm --entrypoint caddy "$IMAGE" version | cut -d' ' -f1)

[[ "$label_version" == "$EXPECTED_VERSION" ]]
[[ "$version" == "v$EXPECTED_VERSION" ]]
docker run --rm --entrypoint caddy "$IMAGE" list-modules --packages |
  grep -Fq 'github.com/caddy-dns/dnsimple'
docker run --rm --entrypoint caddy "$IMAGE" list-modules --packages |
  grep -Fq 'github.com/lucaslorentz/caddy-docker-proxy/v2'
docker run --rm --entrypoint caddy "$IMAGE" docker-proxy --help >/dev/null