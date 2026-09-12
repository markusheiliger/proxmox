#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRAPPER="${SCRIPT_DIR}/configure/compose-profile.sh"
RESOLVER="${SCRIPT_DIR}/configure/resolve-compose-profile.py"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
passed=0
failed=0

pass() { printf 'ok - %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'not ok - %s\n' "$1" >&2; failed=$((failed + 1)); }

expect_failure() {
  local name="$1" expected="$2"
  shift 2
  if "$@" >"${TEST_ROOT}/failure.out" 2>"${TEST_ROOT}/failure.err"; then
    fail "$name"
  elif grep -Fq "$expected" "${TEST_ROOT}/failure.err"; then
    pass "$name"
  else
    cat "${TEST_ROOT}/failure.err" >&2
    fail "$name"
  fi
}

mkdir -p "$TEST_ROOT/bin"
cat >"$TEST_ROOT/bin/docker" <<'EOF'
#!/bin/sh
printf '%s|%s|%s\n' "${COMPOSE_PROFILES-unset}" "${VULKAN_DEVICE-unset}" "$*" >>"$COMPOSE_TEST_LOG"
EOF
chmod 0755 "$TEST_ROOT/bin/docker" "$RESOLVER"
export PATH="$TEST_ROOT/bin:$PATH"
export COMPOSE_TEST_LOG="$TEST_ROOT/docker.log"
export COMPOSE_SELECTOR_LOG="$TEST_ROOT/selector.log"

cat >"$TEST_ROOT/grouped.yaml" <<'EOF'
services:
  app-nvidia:
    image: example.invalid/app
    profiles: [gpu-nvidia_compute, gpu-drm_nvidia]
  app-cpu:
    image: example.invalid/app
    profiles: [gpu-drm_intel, gpu-drm_amd, gpu-none]
  helper:
    image: example.invalid/helper
    profiles: [runtime-native]
EOF
printf '%s\n' '["gpu-none","runtime-native"]' >"$TEST_ROOT/profiles.json"

if [[ "$(python3 "$RESOLVER" --file "$TEST_ROOT/grouped.yaml" \
  --profiles-file "$TEST_ROOT/profiles.json" --detect)" == true ]]; then
  pass "managed groups are derived from service profiles"
else
  fail "managed groups are derived from service profiles"
fi

if [[ "$(python3 "$RESOLVER" --file "$TEST_ROOT/grouped.yaml" \
  --profiles-file "$TEST_ROOT/no-metadata" --managed-group gpu --detect)" == true ]]; then
  pass "host detection uses centrally supplied groups without IMDS"
else
  fail "host detection uses centrally supplied groups without IMDS"
fi

if [[ "$(python3 "$RESOLVER" --file "$TEST_ROOT/grouped.yaml" \
  --profiles-file "$TEST_ROOT/no-metadata" --managed-group runtime \
  --managed-group gpu --managed-group storage --list-groups)" == $'gpu\nruntime' ]]; then
  pass "host discovery lists only relevant centrally supplied groups"
else
  fail "host discovery lists only relevant centrally supplied groups"
fi

if [[ "$(python3 "$RESOLVER" --file "$TEST_ROOT/grouped.yaml" \
  --profiles-file "$TEST_ROOT/profiles.json")" == "gpu-none,runtime-native" ]]; then
  pass "resolver combines exact IMDS winners from independent groups"
else
  fail "resolver combines exact IMDS winners from independent groups"
fi

if python3 "$RESOLVER" --file "$TEST_ROOT/grouped.yaml" --validate \
  >"$TEST_ROOT/validate.out" && [[ ! -s "$TEST_ROOT/validate.out" ]]; then
  pass "validation does not require IMDS"
else
  fail "validation does not require IMDS"
fi

printf '%s\n' '["gpu-unknown","runtime-native"]' >"$TEST_ROOT/unsupported.json"
expect_failure "unsupported workload winner fails closed" "does not support selected profile: gpu-unknown" \
  python3 "$RESOLVER" --file "$TEST_ROOT/grouped.yaml" --profiles-file "$TEST_ROOT/unsupported.json"

expect_failure "missing profile metadata fails closed" "cannot read IMDS profiles" \
  python3 "$RESOLVER" --file "$TEST_ROOT/grouped.yaml" --profiles-file "$TEST_ROOT/missing.json"

printf '%s\n' '["gpu-none","gpu-drm_nvidia","runtime-native"]' >"$TEST_ROOT/multiple.json"
expect_failure "multiple group winners fail closed" "exactly one winner for profile group gpu" \
  python3 "$RESOLVER" --file "$TEST_ROOT/grouped.yaml" --profiles-file "$TEST_ROOT/multiple.json"

printf '%s\n' '["gpu-none","gpu-none","runtime-native"]' >"$TEST_ROOT/duplicate.json"
expect_failure "duplicate metadata values fail closed" "must not contain duplicates" \
  python3 "$RESOLVER" --file "$TEST_ROOT/grouped.yaml" --profiles-file "$TEST_ROOT/duplicate.json"

printf '%s\n' '["GPU-none"]' >"$TEST_ROOT/malformed.json"
expect_failure "malformed metadata fails closed" "sanitized profile names" \
  python3 "$RESOLVER" --file "$TEST_ROOT/grouped.yaml" --profiles-file "$TEST_ROOT/malformed.json"

cat >"$TEST_ROOT/obsolete.yaml" <<'EOF'
x-profiles:
  gpu: [gpu-none]
services:
  app:
    image: example.invalid/app
    profiles: [gpu-none]
EOF
expect_failure "obsolete x-profiles is rejected" "x-profiles is obsolete" \
  python3 "$RESOLVER" --file "$TEST_ROOT/obsolete.yaml" --validate

: >"$COMPOSE_TEST_LOG"
COMPOSE_PROFILES=stale COMPOSE_PROFILE_FILE="$TEST_ROOT/grouped.yaml" \
COMPOSE_PROFILE_METADATA="$TEST_ROOT/profiles.json" \
COMPOSE_PROFILE_SELECTOR="$TEST_ROOT/no-selector" COMPOSE_PROFILE_RESOLVER="$RESOLVER" \
  "$WRAPPER" config --quiet
if [[ "$(cat "$COMPOSE_TEST_LOG")" == 'gpu-none,runtime-native|unset|compose config --quiet' ]]; then
  pass "wrapper activates IMDS winners without inherited or published profiles"
else
  cat "$COMPOSE_TEST_LOG" >&2
  fail "wrapper activates IMDS winners without inherited or published profiles"
fi

: >"$COMPOSE_TEST_LOG"
COMPOSE_PROFILES=stale VULKAN_DEVICE=/dev/dri/renderD999 \
COMPOSE_PROFILE_FILE="$TEST_ROOT/grouped.yaml" COMPOSE_PROFILE_METADATA="$TEST_ROOT/no-metadata" \
COMPOSE_PROFILE_SELECTOR="$TEST_ROOT/no-selector" COMPOSE_PROFILE_RESOLVER="$RESOLVER" \
  "$WRAPPER" --all-profiles pull
if [[ "$(cat "$COMPOSE_TEST_LOG")" == 'unset|/dev/null|compose pull' ]]; then
  pass "all-profile mode validates without reading IMDS"
else
  fail "all-profile mode validates without reading IMDS"
fi

cat >"$TEST_ROOT/select-cpu.sh" <<'EOF'
#!/bin/sh
printf 'x\n' >>"$COMPOSE_SELECTOR_LOG"
printf 'no-discrete-gpu|\n'
EOF
chmod 0755 "$TEST_ROOT/select-cpu.sh"
expect_failure "managed profiles cannot mix with a legacy selector" "managed service profiles" \
  env COMPOSE_PROFILE_FILE="$TEST_ROOT/grouped.yaml" COMPOSE_PROFILE_METADATA="$TEST_ROOT/profiles.json" \
  COMPOSE_PROFILE_SELECTOR="$TEST_ROOT/select-cpu.sh" \
  COMPOSE_PROFILE_RESOLVER="$RESOLVER" "$WRAPPER" config --quiet

cat >"$TEST_ROOT/nvr.yaml" <<'EOF'
services:
  frigate-vulkan:
    image: example.invalid/frigate
    profiles: [vulkan]
  frigate-cpu:
    image: example.invalid/frigate
    profiles: [no-discrete-gpu]
EOF
if [[ "$(python3 "$RESOLVER" --file "$TEST_ROOT/nvr.yaml" \
  --profiles-file "$TEST_ROOT/no-metadata" --managed-group gpu --detect)" == false ]]; then
  pass "host detection ignores legacy NVR profiles"
else
  fail "host detection ignores legacy NVR profiles"
fi
: >"$COMPOSE_TEST_LOG"
: >"$COMPOSE_SELECTOR_LOG"
COMPOSE_PROFILE_FILE="$TEST_ROOT/nvr.yaml" COMPOSE_PROFILE_METADATA="$TEST_ROOT/profiles.json" \
COMPOSE_PROFILE_SELECTOR="$TEST_ROOT/select-cpu.sh" \
  COMPOSE_PROFILE_RESOLVER="$RESOLVER" "$WRAPPER" config --quiet
if [[ "$(cat "$COMPOSE_TEST_LOG")" == 'no-discrete-gpu|unset|compose config --quiet' \
  && "$(wc -l <"$COMPOSE_SELECTOR_LOG")" -eq 1 ]]; then
  pass "legacy NVR selector remains isolated"
else
  fail "legacy NVR selector remains isolated"
fi

printf '%d passed, %d failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]