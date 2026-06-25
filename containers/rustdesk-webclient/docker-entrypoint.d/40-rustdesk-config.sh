#!/bin/sh
# Injects the hbbs/hbbr connection parameters into the static web client at
# container start. Runs via nginx's own /docker-entrypoint.d/ mechanism, so it
# executes before nginx starts and is fully idempotent.
#
# The RustDesk web client is a static Flutter app; there is no official
# build-time/runtime server-config hook. This writes a small config script that
# (a) exposes the values on window.__RUSTDESK_CONFIG__ and (b) best-effort seeds
# the standard RustDesk option keys in localStorage when they are still empty.
# The always-reliable path remains entering the server in the web UI settings.
set -eu

HTML_DIR="/usr/share/nginx/html"
INDEX="${HTML_DIR}/index.html"
CONFIG="${HTML_DIR}/rustdesk-config.js"

if [ ! -f "${INDEX}" ]; then
    echo ">>> rustdesk-webclient: ${INDEX} not found, skipping config injection" >&2
    exit 0
fi

# Escape backslashes and double quotes for safe embedding in a JS string.
esc() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

ID_SERVER="$(esc "${RUSTDESK_ID_SERVER:-}")"
RELAY_SERVER="$(esc "${RUSTDESK_RELAY_SERVER:-}")"
API_SERVER="$(esc "${RUSTDESK_API_SERVER:-}")"
KEY="$(esc "${RUSTDESK_KEY:-}")"

cat > "${CONFIG}" <<EOF
// Generated at container start by 40-rustdesk-config.sh — do not edit.
(function () {
  var cfg = {
    idServer: "${ID_SERVER}",
    relayServer: "${RELAY_SERVER}",
    apiServer: "${API_SERVER}",
    key: "${KEY}"
  };
  window.__RUSTDESK_CONFIG__ = cfg;
  try {
    var seed = function (k, v) {
      if (v && !window.localStorage.getItem(k)) window.localStorage.setItem(k, v);
    };
    seed("custom-rendezvous-server", cfg.idServer);
    seed("relay-server", cfg.relayServer);
    seed("api-server", cfg.apiServer);
    seed("key", cfg.key);
  } catch (e) { /* ignore */ }
})();
EOF

# Inject the config script into <head> once (idempotent).
if ! grep -q 'rustdesk-config.js' "${INDEX}"; then
    sed -i 's#</head>#  <script src="rustdesk-config.js"></script>\n</head>#' "${INDEX}"
    echo ">>> rustdesk-webclient: injected rustdesk-config.js into index.html"
else
    echo ">>> rustdesk-webclient: rustdesk-config.js already referenced in index.html"
fi

echo ">>> rustdesk-webclient: id=${RUSTDESK_ID_SERVER:-} relay=${RUSTDESK_RELAY_SERVER:-} api=${RUSTDESK_API_SERVER:-}"
