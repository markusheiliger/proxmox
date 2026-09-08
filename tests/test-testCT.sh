#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
MOCK_COMMON="${TEST_ROOT}/commonCT.sh"
MOCK_WORKLOADS="${TEST_ROOT}/workloads"
MOCK_CALLS="${TEST_ROOT}/calls"
PASS=0
FAIL=0
mkdir -p "$MOCK_WORKLOADS"/{alpha.test,beta.test,empty.test}
trap 'rm -rf "$TEST_ROOT"' EXIT

pass() { echo "ok - $1"; PASS=$((PASS + 1)); }
fail() { echo "not ok - $1" >&2; FAIL=$((FAIL + 1)); }

assert_success_contains() {
  local description="$1" expected="$2"
  shift 2
  local output
  if output=$("$@" 2>&1) && grep -Fq "$expected" <<< "$output"; then
    pass "$description"
  else
    printf '%s\n' "$output" >&2
    fail "$description"
  fi
}

assert_failure_contains() {
  local description="$1" expected="$2"
  shift 2
  local output
  if output=$("$@" 2>&1); then
    printf '%s\n' "$output" >&2
    fail "$description"
  elif grep -Fq "$expected" <<< "$output"; then
    pass "$description"
  else
    printf '%s\n' "$output" >&2
    fail "$description"
  fi
}

cat > "$MOCK_COMMON" <<'EOF'
declare -A CT_MAP CT_NODE
declare -a CT_LIST SELECTED_CTS
CTID=""
CT_HOSTNAME=""
build_ct_list() {
  CT_LIST=(100 200 300)
  CT_MAP=([100]=alpha.test [200]=beta.test [300]=empty.test)
  CT_NODE=([100]=pve01 [200]=pve02 [300]=pve02)
}
resolve_ct_from_input() {
  local input="$1" id
  if [[ "$input" =~ ^[0-9]+$ ]]; then
    [[ -n "${CT_MAP[$input]:-}" ]] || { echo "ERROR: CT ${input} does not exist." >&2; return 1; }
    CTID="$input"
  else
    CTID=""
    for id in "${CT_LIST[@]}"; do
      [[ "${CT_MAP[$id]}" == "$input" ]] && CTID="$id"
    done
    [[ -n "$CTID" ]] || { echo "ERROR: No CT found with hostname '${input}'." >&2; return 1; }
  fi
  CT_HOSTNAME="${CT_MAP[$CTID]}"
}
select_ct_interactive_multi() {
  read -r -a SELECTED_CTS <<< "${MOCK_SELECTION:-100 300}"
}
get_ct_owner_node() { printf '%s\n' "${CT_NODE[$1]}"; }
run_on_node() {
  local node="$1" command="$2" path="$3"
  shift 3
  printf '%s|%s|%s\n' "$node" "$command" "$path" >> "$MOCK_CALLS"
  case "$command" in
    find)
      local hostname="${path##*/}"
      if [[ "$hostname" == "${MOCK_DISCOVERY_FAIL_HOST:-}" ]]; then
        return 6
      fi
      find "$MOCK_WORKLOADS/$hostname" -maxdepth 1 -type f -name 'test-*.sh' -printf '%f\n'
      ;;
    bash)
      local hostname="${path%/*}"
      hostname="${hostname##*/}"
      bash "$MOCK_WORKLOADS/$hostname/${path##*/}"
      ;;
    *) return 1 ;;
  esac
}
lifecycle_log_init() { :; }
status_bar_init() { :; }
status_progress() { :; }
status_bar_cleanup() { :; }
EOF

cat > "$MOCK_WORKLOADS/alpha.test/test-20-second.sh" <<'EOF'
#!/usr/bin/env bash
echo second
EOF
cat > "$MOCK_WORKLOADS/alpha.test/test-10-first.sh" <<'EOF'
#!/usr/bin/env bash
echo first
EOF
cat > "$MOCK_WORKLOADS/beta.test/test-fail.sh" <<'EOF'
#!/usr/bin/env bash
echo intentional failure
exit 4
EOF
cat > "$MOCK_WORKLOADS/beta.test/test-pass.sh" <<'EOF'
#!/usr/bin/env bash
echo continued
EOF
cat > "$MOCK_WORKLOADS/alpha.test/nested-test.sh" <<'EOF'
#!/usr/bin/env bash
exit 99
EOF
mkdir -p "$MOCK_WORKLOADS/alpha.test/nested"
touch "$MOCK_WORKLOADS/alpha.test/nested/test-hidden.sh"
ln -s "$MOCK_WORKLOADS/alpha.test/test-10-first.sh" "$MOCK_WORKLOADS/alpha.test/test-link.sh"

run_runner() {
  : > "$MOCK_CALLS"
  TEST_CT_COMMON_FILE="$MOCK_COMMON" MOCK_WORKLOADS="$MOCK_WORKLOADS" \
    MOCK_CALLS="$MOCK_CALLS" MOCK_SELECTION="${MOCK_SELECTION:-}" \
    MOCK_DISCOVERY_FAIL_HOST="${MOCK_DISCOVERY_FAIL_HOST:-}" \
    bash "$SCRIPT_DIR/testCT.sh" "$@"
}

assert_success_contains "hostname target runs workload tests" "2 passed, 0 failed, 0 skipped" run_runner alpha.test
if [[ "$(grep '|bash|' "$MOCK_CALLS" | cut -d'|' -f3 | paste -sd ',')" == "/mnt/docker/alpha.test/test-10-first.sh,/mnt/docker/alpha.test/test-20-second.sh" ]]; then
  pass "tests run lexically from owner-node workload paths"
else
  cat "$MOCK_CALLS" >&2
  fail "tests run lexically from owner-node workload paths"
fi
assert_failure_contains "numeric CTID resolves remote owner" "CT 200 (beta.test) on pve02" run_runner 200
if grep -Fq 'pve02|bash|/mnt/docker/beta.test/test-pass.sh' "$MOCK_CALLS"; then
  pass "failed tests do not prevent later tests"
else
  cat "$MOCK_CALLS" >&2
  fail "failed tests do not prevent later tests"
fi
assert_failure_contains "failed workload test controls aggregate status" "1 passed, 1 failed, 0 skipped" run_runner beta.test
assert_failure_contains "explicit CT without tests fails" "No root-level test-*.sh files found" run_runner empty.test
MOCK_DISCOVERY_FAIL_HOST="alpha.test" assert_failure_contains "owner discovery failures are reported" "Cannot discover workload tests" run_runner alpha.test
MOCK_SELECTION="100 300" assert_success_contains "interactive selection skips untested CTs" "2 passed, 0 failed, 1 skipped" run_runner
assert_failure_contains "all mode continues and aggregates failures" "3 passed, 1 failed, 1 skipped" run_runner --all
assert_failure_contains "multiple targets are rejected" "Only one CTID or hostname" run_runner alpha.test beta.test
assert_failure_contains "unknown options are rejected" "Unknown option '--bogus'" run_runner --bogus

echo "${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]