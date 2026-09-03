#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
PASS=0
FAIL=0

pass() { echo "ok - $1"; PASS=$((PASS + 1)); }
fail() { echo "not ok - $1" >&2; FAIL=$((FAIL + 1)); }
assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then pass "$name"; else echo "expected: $expected" >&2; echo "actual:   $actual" >&2; fail "$name"; fi
}
assert_contains() {
  local name="$1" file="$2" expected="$3"
  if grep -Fq "$expected" "$file"; then pass "$name"; else cat "$file" >&2; fail "$name"; fi
}

source "${SCRIPT_DIR}/commonCT.sh"
trap 'rm -rf "$TEST_ROOT"' EXIT
CTID=2200

resolve_json='{"services":{"app":{"image":"app:test","labels":{"permissions.thesaints.user":"42:43"}}}}'
ct_exec() { return 99; }
assert_eq "permission override has highest precedence" "42:43" "$(resolve_compose_service_user 2200 "$resolve_json" app)"

resolve_json='{"services":{"app":{"image":"app:test","user":"100:101","environment":{"PUID":"200","PGID":"201"}}}}'
assert_eq "Compose user precedes PUID and PGID" "100:101" "$(resolve_compose_service_user 2200 "$resolve_json" app)"

resolve_json='{"services":{"app":{"image":"app:test","environment":{"PUID":"200","PGID":"201"}}}}'
assert_eq "paired PUID and PGID are supported" "200:201" "$(resolve_compose_service_user 2200 "$resolve_json" app)"

resolve_json='{"services":{"app":{"image":"app:test"}}}'
ct_exec() {
  local command="${*: -1}"
  [[ "$command" == *"docker image inspect"* ]] && { echo 10001; return 0; }
  return 1
}
assert_eq "bare numeric image user uses Docker default group" "10001:0" "$(resolve_compose_service_user 2200 "$resolve_json" app)"

ct_exec() {
  local command="${*: -1}"
  case "$command" in
    *"docker image inspect"*) echo nobody ;;
    *"entrypoint id"*" -u") echo 65534 ;;
    *"entrypoint id"*" -g") echo 65534 ;;
    *) return 1 ;;
  esac
}
assert_eq "named image user resolves numerically" "65534:65534" "$(resolve_compose_service_user 2200 "$resolve_json" app)"

commands="${TEST_ROOT}/commands"
conflict_json='{"services":{"one":{"image":"one:test","labels":{"permissions.thesaints.user":"1:1"},"volumes":[{"type":"bind","source":"/mnt/docker-data/shared","target":"/data"}]},"two":{"image":"two:test","labels":{"permissions.thesaints.user":"2:2"},"volumes":[{"type":"bind","source":"/mnt/docker-data/shared","target":"/data"}]}}}'
ct_exec() {
  local command="${*: -1}"
  echo "$command" >> "$commands"
  [[ "$command" == *"docker compose config"* ]] && { echo "$conflict_json"; return 0; }
  return 1
}
if reconcile_compose_permissions 2200 >"${TEST_ROOT}/conflict-output" 2>&1; then
  fail "conflicting shared writers fail"
else
  pass "conflicting shared writers fail"
fi
assert_contains "conflict names both ownerships" "${TEST_ROOT}/conflict-output" "one=1:1, two=2:2"
if ! grep -Fq "chown" "$commands"; then pass "conflict causes no mutation"; else fail "conflict causes no mutation"; fi

unsafe_json='{"services":{"app":{"image":"app:test","labels":{"permissions.thesaints.user":"1:1"},"volumes":[{"type":"bind","source":"/etc","target":"/host"}]}}}'
ct_exec() {
  local command="${*: -1}"
  [[ "$command" == *"docker compose config"* ]] && { echo "$unsafe_json"; return 0; }
  return 1
}
if reconcile_compose_permissions 2200 >"${TEST_ROOT}/unsafe-output" 2>&1; then
  fail "writable bind outside managed roots fails"
else
  pass "writable bind outside managed roots fails"
fi
assert_contains "unsafe bind diagnostic names source" "${TEST_ROOT}/unsafe-output" "app:/etc"

skip_json='{"services":{"app":{"image":"app:test","labels":{"permissions.thesaints.user":"1:1","permissions.thesaints.skip":"/mnt/docker-data/legacy"},"volumes":[{"type":"bind","source":"/mnt/docker-data/legacy","target":"/data"}]}}}'
: > "$commands"
ct_exec() {
  local command="${*: -1}"
  echo "$command" >> "$commands"
  [[ "$command" == *"docker compose config"* ]] && { echo "$skip_json"; return 0; }
  return 1
}
if reconcile_compose_permissions 2200 --check >"${TEST_ROOT}/skip-output"; then pass "explicit exact-path skip succeeds"; else fail "explicit exact-path skip succeeds"; fi
assert_contains "explicit skip reports service and source" "${TEST_ROOT}/skip-output" "app: explicitly skipping /mnt/docker-data/legacy"
if ! grep -Fq "chown" "$commands"; then pass "explicit skip performs no ownership mutation"; else fail "explicit skip performs no ownership mutation"; fi

managed_json='{"services":{"app":{"image":"app:test","labels":{"permissions.thesaints.user":"7:8"},"volumes":[{"type":"bind","source":"/mnt/docker-data/app","target":"/data"}]}}}'
: > "$commands"
ct_exec() {
  local command="${*: -1}"
  echo "$command" >> "$commands"
  case "$command" in
    *"docker compose config"*) echo "$managed_json" ;;
    *"candidate='/mnt/docker-data/app'"*) return 0 ;;
    *"test -e '/mnt/docker-data/app'"*) return 0 ;;
    *) return 1 ;;
  esac
}
if reconcile_compose_permissions 2200 --check >"${TEST_ROOT}/check-output"; then pass "check-only plan succeeds"; else fail "check-only plan succeeds"; fi
assert_contains "check-only plan reports owner" "${TEST_ROOT}/check-output" "/mnt/docker-data/app -> 7:8"
if ! grep -Eq 'chown|mkdir -p' "$commands"; then pass "check-only plan performs no mutation"; else fail "check-only plan performs no mutation"; fi

: > "$commands"
ct_exec() {
  local command="${*: -1}"
  echo "$command" >> "$commands"
  case "$command" in
    *"docker compose config"*) echo "$managed_json" ;;
    *"candidate='/mnt/docker-data/app'"*) return 0 ;;
    *"test -e '/mnt/docker-data/app'"*) return 1 ;;
    *"mkdir -p '/mnt/docker-data/app'"*) return 0 ;;
    *"find '/mnt/docker-data/app'"*) return 0 ;;
    *) return 1 ;;
  esac
}
if reconcile_compose_permissions 2200 >"${TEST_ROOT}/create-output"; then pass "missing auto-creatable directory is reconciled"; else cat "${TEST_ROOT}/create-output" >&2; fail "missing auto-creatable directory is reconciled"; fi
assert_contains "missing directory is created inside CT" "$commands" "mkdir -p '/mnt/docker-data/app'"
if [[ "$(grep -n "candidate='/mnt/docker-data/app'" "$commands" | head -1 | cut -d: -f1)" -lt "$(grep -n "mkdir -p '/mnt/docker-data/app'" "$commands" | head -1 | cut -d: -f1)" ]]; then
  pass "missing directory validates before creation"
else
  fail "missing directory validates before creation"
fi
assert_contains "first-level source permits managed mount root ancestor" "$commands" "/mnt/docker-data|/mnt/docker-data/?*"

: > "$commands"
ct_exec() {
  local command="${*: -1}"
  echo "$command" >> "$commands"
  case "$command" in
    *"docker compose config"*) echo "$managed_json" ;;
    *"candidate='/mnt/docker-data/app'"*) return 0 ;;
    *"test -e '/mnt/docker-data/app'"*) return 0 ;;
    *"find '/mnt/docker-data/app'"*) return 0 ;;
    *) return 1 ;;
  esac
}
if reconcile_compose_permissions 2200 >"${TEST_ROOT}/legacy-empty-output"; then pass "legacy empty bind source is reconciled"; else cat "${TEST_ROOT}/legacy-empty-output" >&2; fail "legacy empty bind source is reconciled"; fi

legacy_mount="${TEST_ROOT}/legacy-mount"
mkdir -p "${legacy_mount}/empty" "${legacy_mount}/populated"
touch "${legacy_mount}/populated/data"
chmod 755 "$legacy_mount"
pct() {
  [[ "$1" == "config" ]] || return 1
  echo "mp0: ${legacy_mount},mp=/mnt/docker"
}
if remove_empty_host_root_bind_ancestors 2200 /mnt/docker/empty >"${TEST_ROOT}/host-repair-output"; then pass "empty host-root bind source is removed safely"; else fail "empty host-root bind source is removed safely"; fi
if [[ ! -e "${legacy_mount}/empty" ]]; then pass "host repair resolves actual CT mount mapping"; else fail "host repair resolves actual CT mount mapping"; fi
assert_contains "host repair reports CT-local source" "${TEST_ROOT}/host-repair-output" "/mnt/docker/empty"
if remove_empty_host_root_bind_ancestors 2200 /mnt/docker/populated >/dev/null 2>&1; then fail "populated host-root bind source is preserved"; else pass "populated host-root bind source is preserved"; fi
if [[ -f "${legacy_mount}/populated/data" ]]; then pass "populated bind data remains intact"; else fail "populated bind data remains intact"; fi
ln -s "${legacy_mount}/populated" "${legacy_mount}/linked"
if remove_empty_host_root_bind_ancestors 2200 /mnt/docker/linked >/dev/null 2>&1; then fail "symlink bind source is rejected"; else pass "symlink bind source is rejected"; fi

mkdir -p "${legacy_mount}/blocked/leaf"
ct_create_attempt=0
ct_exec() {
  local command="${*: -1}"
  if [[ "$command" == *"mkdir -p '/mnt/docker/blocked/leaf'"* ]]; then
    ct_create_attempt=$((ct_create_attempt + 1))
    [[ $ct_create_attempt -gt 1 ]] || return 1
    mkdir -p "${legacy_mount}/blocked/leaf"
    return 0
  fi
  return 1
}
if remove_empty_host_root_bind_ancestors 2200 /mnt/docker/blocked/leaf >/dev/null &&
   create_compose_bind_source 2200 /mnt/docker/blocked/leaf 7:8 "'/mnt/docker/blocked/leaf'"; then
  pass "missing nested bind source is recreated across unprivileged mount boundary"
else
  fail "missing nested bind source is recreated across unprivileged mount boundary"
fi
assert_eq "temporary mount-root write permission is restored" "755" "$(stat -c %a "$legacy_mount")"

echo "${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
