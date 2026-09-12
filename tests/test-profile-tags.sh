#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
CONFIG_FILE="${TEST_ROOT}/commonCT.json"
CALLS_FILE="${TEST_ROOT}/calls"
trap 'rm -rf "$TEST_ROOT"' EXIT

PASS=0
FAIL=0

pass() {
  echo "ok - $1"
  PASS=$((PASS + 1))
}

fail() {
  echo "not ok - $1" >&2
  FAIL=$((FAIL + 1))
}

assert_success() {
  local name="$1"
  shift
  if "$@" >"${TEST_ROOT}/output" 2>&1; then
    pass "$name"
  else
    cat "${TEST_ROOT}/output" >&2
    fail "$name"
  fi
}

assert_failure_contains() {
  local name="$1" expected="$2"
  shift 2
  if "$@" >"${TEST_ROOT}/output" 2>&1; then
    fail "$name"
  elif grep -Fq "$expected" "${TEST_ROOT}/output"; then
    pass "$name"
  else
    cat "${TEST_ROOT}/output" >&2
    fail "$name"
  fi
}

assert_output() {
  local name="$1" expected="$2"
  shift 2
  local actual
  if actual=$("$@" 2>"${TEST_ROOT}/error") && [[ "$actual" == "$expected" ]]; then
    pass "$name"
  else
    echo "expected: ${expected}" >&2
    echo "actual:   ${actual:-}" >&2
    cat "${TEST_ROOT}/error" >&2
    fail "$name"
  fi
}

write_valid_config() {
  cat >"$CONFIG_FILE" <<'EOF'
{
  "profiles": {
    "gpu": {
      "default": "none",
      "profiles": [
        {"name": "nvidia_compute", "tests": [["probe", "nvidia-control"], ["probe", "nvidia-drm"]]},
        {"name": "drm_nvidia", "tests": [["probe", "drm-nvidia"]]},
        {"name": "drm_intel", "tests": [["probe", "drm-intel"]]},
        {"name": "drm_amd", "tests": [["probe", "drm-amd"]]}
      ]
    }
  }
}
EOF
}

source "${SCRIPT_DIR}/commonCT.sh"

write_valid_config
assert_success "valid profile schema is accepted" validate_profiles_config

jq '.profiles["bad-group"] = .profiles.gpu | del(.profiles.gpu)' "$CONFIG_FILE" >"${TEST_ROOT}/invalid.json"
mv "${TEST_ROOT}/invalid.json" "$CONFIG_FILE"
assert_failure_contains "invalid group identifier is rejected" "Invalid profiles configuration" validate_profiles_config

write_valid_config
jq '.profiles.gpu.profiles[0].tests = []' "$CONFIG_FILE" >"${TEST_ROOT}/invalid.json"
mv "${TEST_ROOT}/invalid.json" "$CONFIG_FILE"
assert_failure_contains "empty candidate tests are rejected" "Invalid profiles configuration" validate_profiles_config

write_valid_config
jq '.profiles.gpu.profiles[1].name = "nvidia_compute"' "$CONFIG_FILE" >"${TEST_ROOT}/invalid.json"
mv "${TEST_ROOT}/invalid.json" "$CONFIG_FILE"
assert_failure_contains "duplicate candidate names are rejected" "Invalid profiles configuration" validate_profiles_config

write_valid_config
: >"$CALLS_FILE"
get_ct_owner_node() { printf 'pve02\n'; }
run_on_node() { printf '%s\n' "$*" >>"$CALLS_FILE"; }
ct_exec --timeout 7 2200 "true"
if grep -Fxq "pve02 timeout 7 pct exec 2200 -- sh -c true" "$CALLS_FILE"; then
  pass "ct_exec routes profile probes to a non-local owner"
else
  cat "$CALLS_FILE" >&2
  fail "ct_exec routes profile probes to a non-local owner"
fi
pct_set 2200 -tags profile-gpu-none
if grep -Fxq "pve02 pct set 2200 -tags profile-gpu-none" "$CALLS_FILE"; then
  pass "pct_set routes profile tag mutation to a non-local owner"
else
  cat "$CALLS_FILE" >&2
  fail "pct_set routes profile tag mutation to a non-local owner"
fi

MOCK_STATUS=running
MOCK_RESULTS=""
get_ct_status() { printf '%s\n' "$MOCK_STATUS"; }
ct_exec() {
  local timeout ctid command result
  [[ "${1:-}" == "--timeout" ]] || return 2
  timeout="$2"
  ctid="$3"
  command="${*:4}"
  printf '%s\t%s\t%s\n' "$timeout" "$ctid" "$command" >>"$CALLS_FILE"
  while IFS=$'\t' read -r result_command result; do
    [[ -n "$result_command" && "$command" == *"$result_command"* ]] || continue
    return "$result"
  done <<<"$MOCK_RESULTS"
  return 0
}

: >"$CALLS_FILE"
MOCK_RESULTS=""
assert_output "first fully matching candidate wins" "nvidia_compute" evaluate_ct_profile_group 2200 gpu
if [[ $(wc -l <"$CALLS_FILE") -eq 2 ]]; then
  pass "matching candidate evaluates all tests and short-circuits later profiles"
else
  cat "$CALLS_FILE" >&2
  fail "matching candidate evaluates all tests and short-circuits later profiles"
fi

: >"$CALLS_FILE"
MOCK_RESULTS=$'nvidia-control\t1'
assert_output "next candidate wins after an earlier rejection" "drm_nvidia" evaluate_ct_profile_group 2200 gpu
if [[ $(wc -l <"$CALLS_FILE") -eq 2 ]] && sed -n '1p' "$CALLS_FILE" | grep -Fq "nvidia-control" \
  && sed -n '2p' "$CALLS_FILE" | grep -Fq "drm-nvidia"; then
  pass "candidate evaluation preserves configured order"
else
  cat "$CALLS_FILE" >&2
  fail "candidate evaluation preserves configured order"
fi

: >"$CALLS_FILE"
MOCK_RESULTS=$'nvidia-control\t127\ndrm-nvidia\t1\ndrm-intel\t124\ndrm-amd\t1'
assert_output "missing commands, failures, and timeouts select the default" "none" evaluate_ct_profile_group 2200 gpu

MOCK_RESULTS=$'nvidia-control\t255'
assert_failure_contains "transport failure aborts evaluation" "Transport failed" evaluate_ct_profile_group 2200 gpu

MOCK_STATUS=stopped
MOCK_RESULTS=""
assert_failure_contains "stopped CT cannot be evaluated" "must be running" evaluate_ct_profile_group 2200 gpu

MOCK_STATUS=running
: >"$CALLS_FILE"
assert_output "irrelevant profile groups produce no selections" "" evaluate_ct_profiles 2200 ""
if [[ ! -s "$CALLS_FILE" ]]; then
  pass "irrelevant profile groups execute no CT probes"
else
  cat "$CALLS_FILE" >&2
  fail "irrelevant profile groups execute no CT probes"
fi
assert_failure_contains "unknown relevant group is rejected" "unknown profile group" evaluate_ct_profiles 2200 storage

CURRENT_CONFIG=$'arch: amd64\ntags: zeta;compose-profile.vulkan;profile-gpu-cuda;managed;zeta'
PCT_SET_RESULT=0
pct_config() {
  printf '%s\n' "$CURRENT_CONFIG"
  printf 'config-read\n' >>"$CALLS_FILE"
}
pct_set() {
  printf 'pct-set\t%s\n' "$*" >>"$CALLS_FILE"
  return "$PCT_SET_RESULT"
}

: >"$CALLS_FILE"
assert_success "tag reconciliation succeeds" reconcile_ct_profile_tags 2200 $'gpu\tdrm_intel' gpu
if grep -Fxq $'pct-set\t2200 -tags managed;profile-gpu-drm_intel;zeta' "$CALLS_FILE" \
  && [[ "${CT_TAGS[2200]}" == "managed;profile-gpu-drm_intel;zeta" ]]; then
  pass "reconciliation removes stale managed tags and preserves sorted unrelated tags"
else
  cat "$CALLS_FILE" >&2
  fail "reconciliation removes stale managed tags and preserves sorted unrelated tags"
fi

CURRENT_CONFIG=$'arch: amd64\ntags: managed;profile-gpu-drm_intel;zeta'
: >"$CALLS_FILE"
assert_success "already reconciled tags succeed" reconcile_ct_profile_tags 2200 $'gpu\tdrm_intel' gpu
if [[ $(grep -c '^config-read$' "$CALLS_FILE") -eq 1 ]] && ! grep -q '^pct-set' "$CALLS_FILE"; then
  pass "reconciliation reads fresh state and avoids an idempotent mutation"
else
  cat "$CALLS_FILE" >&2
  fail "reconciliation reads fresh state and avoids an idempotent mutation"
fi

CURRENT_CONFIG=$'arch: amd64\ntags: managed;profile-gpu-drm_intel;zeta'
: >"$CALLS_FILE"
assert_success "irrelevant group tag reconciliation succeeds" reconcile_ct_profile_tags 2200 "" ""
if grep -Fxq $'pct-set\t2200 -tags managed;zeta' "$CALLS_FILE"; then
  pass "irrelevant group reconciliation removes stale profile tags"
else
  cat "$CALLS_FILE" >&2
  fail "irrelevant group reconciliation removes stale profile tags"
fi

assert_failure_contains "missing relevant group selection is rejected" "No selected profile" reconcile_ct_profile_tags 2200 "" gpu
assert_failure_contains "unknown selected profile is rejected" "is not configured" reconcile_ct_profile_tags 2200 $'gpu\tmetal' gpu
assert_failure_contains "duplicate group selection is rejected" "one unique group/name pair" reconcile_ct_profile_tags 2200 $'gpu\tnone\ngpu\tdrm_nvidia' gpu
assert_failure_contains "unknown relevant tag group is rejected" "unknown profile group" reconcile_ct_profile_tags 2200 "" storage

CURRENT_CONFIG=$'tags: profile-gpu-cuda'
PCT_SET_RESULT=1
assert_failure_contains "failed tag mutation is fatal" "Cannot reconcile profile tags" reconcile_ct_profile_tags 2200 $'gpu\tnone' gpu

echo "${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]