#!/bin/bash
set -e

if [ -n "$STEP_CA_URL" ] && [ -n "$STEP_CA_FINGERPRINT" ]; then

    echo ">>> Running step-ca bootstrap ..."
    step ca bootstrap --ca-url "$STEP_CA_URL" --fingerprint "$STEP_CA_FINGERPRINT" --force

    echo ">>> Installing root CA certificate ..."
    step certificate install "$(step path)/certs/root_ca.crt"

else

    echo ">>> Leaving step CA uninitialized ..."
    echo "STEP_CA_URL:         $STEP_CA_URL"
    echo "STEP_CA_FINGERPRINT: $STEP_CA_FINGERPRINT"

fi

# If a Caddyfile exists, format it (for non-docker-proxy mode)
if [ -f /etc/caddy/Caddyfile ] && [[ "$*" != *"docker-proxy"* ]]; then
    echo ">>> Format Caddyfile ..."
    caddy fmt --overwrite /etc/caddy/Caddyfile
fi

echo ">>> Running Caddy ($*) ..."
exec "$@"
