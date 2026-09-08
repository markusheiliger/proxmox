#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORWARD_AUTH_SCRIPT="${SCRIPT_DIR}/forwardAuthCT.sh"

python3 - "$FORWARD_AUTH_SCRIPT" <<'PY'
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    script = handle.read()

assert "'caddy.route.0_reverse_proxy.header_up: \"Host {http.reverse_proxy.upstream.host}\"'" in script
assert "'caddy.route.50_forward_auth.header_up: \"Host {http.reverse_proxy.upstream.host}\"'" in script
assert "'caddy.route.0_reverse_proxy.header_up: \"Host {http.request.host}\"'" not in script
assert "'caddy.route.50_forward_auth.header_up: \"Host {http.request.host}\"'" not in script
assert "caddy.route.50_forward_auth.trusted_proxies" not in script
PY

echo "1 passed, 0 failed"