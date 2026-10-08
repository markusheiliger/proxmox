#!/bin/sh
set -eu

response=$(wget -S -O /dev/null http://127.0.0.1:9997/api/v1/login 2>&1 || true)
status=$(printf '%s\n' "$response" | awk '/HTTP\/[0-9.]+/ { code = $2 } END { print code }')

case "$status" in
  200|409)
    exit 0
    ;;
  *)
    printf 'GARM readiness check returned HTTP %s\n' "${status:-unknown}" >&2
    exit 1
    ;;
esac