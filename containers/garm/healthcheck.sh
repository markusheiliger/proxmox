#!/bin/sh
set -eu

response=$(wget -S -O /dev/null http://127.0.0.1:9997/api/v1/login 2>&1 || true)
status=$(printf '%s\n' "$response" |
  awk '$1 ~ /^HTTP\/[0-9.]+$/ && $2 ~ /^[0-9][0-9][0-9]$/ { print $2; exit }')

case "$status" in
  200|409)
    exit 0
    ;;
  *)
    printf 'GARM readiness check returned HTTP %s\n' "${status:-unknown}" >&2
    exit 1
    ;;
esac