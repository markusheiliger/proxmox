#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
PASS=0
FAIL=0

pass() { echo "ok - $1"; PASS=$((PASS + 1)); }
fail() { echo "not ok - $1" >&2; FAIL=$((FAIL + 1)); }

run_logged() {
  LIFECYCLE_LOG_DIR="${TEST_ROOT}/logs" SCRIPT_DIR="$SCRIPT_DIR" bash -c '
    source "$SCRIPT_DIR/commonCT.sh"
    lifecycle_log_init "/tmp/example.sh" --token secret visible
    echo stdout-message
    echo stderr-message >&2
  '
}

run_logged >/dev/null 2>&1
log="${TEST_ROOT}/logs/example.log"
if [[ -f "$log" && "$(stat -c %a "$log")" == 600 && "$(stat -c %a "${TEST_ROOT}/logs")" == 700 ]]; then
  pass "lifecycle logs use root-only permissions"
else
  fail "lifecycle logs use root-only permissions"
fi
if grep -Fq stdout-message "$log" && grep -Fq stderr-message "$log"; then
  pass "lifecycle log captures stdout and stderr"
else
  fail "lifecycle log captures stdout and stderr"
fi
if grep -Fq 'REDACTED' "$log" && ! grep -Fq ' secret' "$log"; then
  pass "lifecycle log redacts sensitive arguments"
else
  fail "lifecycle log redacts sensitive arguments"
fi
if grep -Fq 'exit_status=0' "$log"; then
  pass "lifecycle log records successful completion"
else
  fail "lifecycle log records successful completion"
fi

LIFECYCLE_LOG_DIR="${TEST_ROOT}/logs" SCRIPT_DIR="$SCRIPT_DIR" bash -c '
  source "$SCRIPT_DIR/commonCT.sh"
  lifecycle_log_init "/tmp/example.sh" second-run
  echo replacement
' >/dev/null 2>&1
if grep -Fq replacement "$log" && ! grep -Fq stdout-message "$log"; then
  pass "latest lifecycle run replaces the prior log"
else
  fail "latest lifecycle run replaces the prior log"
fi

set +e
LIFECYCLE_LOG_DIR="${TEST_ROOT}/logs" SCRIPT_DIR="$SCRIPT_DIR" bash -c '
  source "$SCRIPT_DIR/commonCT.sh"
  lifecycle_log_init "/tmp/failure.sh"
  echo before-failure
  false
' >/dev/null 2>&1
exit_code=$?
set -e
if [[ "$exit_code" -eq 1 ]] && grep -Fq before-failure "${TEST_ROOT}/logs/failure.log" \
  && grep -Fq 'exit_status=1' "${TEST_ROOT}/logs/failure.log"; then
  pass "lifecycle logger preserves failures and diagnostics"
else
  fail "lifecycle logger preserves failures and diagnostics"
fi

set +e
LIFECYCLE_LOG_DIR="${TEST_ROOT}/logs" SCRIPT_DIR="$SCRIPT_DIR" bash -c '
  source "$SCRIPT_DIR/commonCT.sh"
  lifecycle_log_init "/tmp/signal.sh"
  kill -TERM $$
' >/dev/null 2>&1
exit_code=$?
set -e
if [[ "$exit_code" -eq 143 ]] \
  && grep -Fq 'signal=TERM' "${TEST_ROOT}/logs/signal.log" \
  && grep -Fq 'exit_status=143' "${TEST_ROOT}/logs/signal.log"; then
  pass "lifecycle logger records signal termination and a complete footer"
else
  fail "lifecycle logger records signal termination and a complete footer"
fi

if git -C "$SCRIPT_DIR" check-ignore -q logs/example.log; then
  pass "runtime lifecycle logs are ignored by Git"
else
  fail "runtime lifecycle logs are ignored by Git"
fi

lifecycle_scripts=(
  createCT.sh refreshCT.sh deleteCT.sh renameCT.sh upgradeCT.sh moveCT.sh
  backupCT.sh backupVM.sh forwardAuthCT.sh forwardDNSCT.sh
)
missing_logging=()
for script in "${lifecycle_scripts[@]}"; do
  if ! grep -Fq 'lifecycle_log_init "${BASH_SOURCE[0]}" "$@"' "$SCRIPT_DIR/$script"; then
    missing_logging+=("$script")
  fi
done
if [[ ${#missing_logging[@]} -eq 0 ]] && ! grep -Fq lifecycle_log_init "$SCRIPT_DIR/monitorCT.sh"; then
  pass "all finite lifecycle entry points initialize logging"
else
  fail "all finite lifecycle entry points initialize logging"
fi

if ! grep -Eq '/var/log/(moveCT|upgradeCT)' "$SCRIPT_DIR/moveCT.sh" "$SCRIPT_DIR/upgradeCT.sh" \
  && grep -Fq 'Transaction log: ${RUN_LOG_FILE}' "$SCRIPT_DIR/moveCT.sh" \
  && grep -Fq 'DIAGNOSTIC_LOG="$RUN_LOG_FILE"' "$SCRIPT_DIR/upgradeCT.sh"; then
  pass "move and upgrade use the shared latest-run log"
else
  fail "move and upgrade use the shared latest-run log"
fi

for script in createCT.sh refreshCT.sh; do
  if ! awk '/lifecycle_log_stop 0/ { stopped=1 } /exec .*monitorCT\.sh/ { if (stopped) found=1 } END { exit !found }' "$SCRIPT_DIR/$script"; then
    fail "monitor handoffs close finite lifecycle logs"
    monitor_handoffs_valid=false
    break
  fi
done
if [[ "${monitor_handoffs_valid:-true}" == "true" ]]; then
  pass "monitor handoffs close finite lifecycle logs"
fi

echo "${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]