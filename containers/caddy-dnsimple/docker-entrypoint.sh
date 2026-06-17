#!/bin/bash
set -e

if [ -z "$DNSIMPLE_API_ACCESS_TOKEN" ]; then
    echo ">>> ERROR: DNSIMPLE_API_ACCESS_TOKEN is required for DNS-01 ACME with dnsimple"
    exit 1
fi

# If a Caddyfile exists, format it (for non-docker-proxy mode)
if [ -f /etc/caddy/Caddyfile ] && [[ "$*" != *"docker-proxy"* ]]; then
    echo ">>> Format Caddyfile ..."
    caddy fmt --overwrite /etc/caddy/Caddyfile
fi

echo ">>> Running Caddy ($*) ..."
exec "$@"
