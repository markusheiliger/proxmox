#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
CALLS="${TEST_ROOT}/calls"
AVAILABLE="${TEST_ROOT}/available"
trap 'rm -rf "$TEST_ROOT"' EXIT

PASS=0
FAIL=0

pass() { echo "ok - $1"; PASS=$((PASS + 1)); }
fail() { echo "not ok - $1" >&2; FAIL=$((FAIL + 1)); }

assert_equals() {
  local name="$1"
  local expected="$2"
  local actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    pass "$name"
  else
    printf 'expected: %s\nactual:   %s\n' "$expected" "$actual" >&2
    fail "$name"
  fi
}

assert_failure_contains() {
  local name="$1"
  local expected="$2"
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

source "${SCRIPT_DIR}/createCT.sh"

run_on_node() {
  local node="$1"
  shift
  printf '%s|%s\n' "$node" "$*" >> "$CALLS"

  case "$1" in
    uname)
      case "$node" in
        pve02) echo x86_64 ;;
        pve03) echo aarch64 ;;
        pve04) echo riscv64 ;;
        *) return 1 ;;
      esac
      ;;
    pveam)
      case "$2" in
        update|download) return 0 ;;
        available)
          awk '{print "system " $0}' "$AVAILABLE"
          ;;
        list)
          echo "NAME SIZE"
          ;;
        *) return 1 ;;
      esac
      ;;
    pct)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

pvesh() {
  echo '[]'
}

cat > "$AVAILABLE" <<'EOF'
alpine-3.23-default_20260101_amd64.tar.xz
alpine-3.24-default_20260803_amd64.tar.xz
alpine-3.24-default_20260803_arm64.tar.xz
EOF

CREATE_NODE=pve02
TEMPLATE_PREFIX=alpine-3
TEMPLATE_STORE=local
TEMPLATE_ARCH=""
TEMPLATE_PATH=""
prepare_template >/dev/null

assert_equals "x86_64 target selects amd64" "amd64" "$TEMPLATE_ARCH"
assert_equals "newest matching amd64 template is selected" \
  "local:vztmpl/alpine-3.24-default_20260803_amd64.tar.xz" "$TEMPLATE_PATH"
if grep -Fq 'pve02|uname -m' "$CALLS"; then
  pass "template architecture is queried on the target node"
else
  fail "template architecture is queried on the target node"
fi

CTID=3000
HOSTNAME=build.thesaints.home
CORES=2
MEMORY=2048
DISK=16
IP=dhcp
GW=""
BRIDGE=vmbr1
CT_PRIORITY=mid
create_ct
if grep -Fq 'pve02|pct create 3000 local:vztmpl/alpine-3.24-default_20260803_amd64.tar.xz --hostname build.thesaints.home --arch amd64' "$CALLS"; then
  pass "CT creation routes to the target node with explicit architecture"
else
  fail "CT creation routes to the target node with explicit architecture"
fi

CREATE_NODE=pve03
TEMPLATE_ARCH=""
TEMPLATE_PATH=""
prepare_template >/dev/null
assert_equals "aarch64 target selects arm64" "arm64" "$TEMPLATE_ARCH"
assert_equals "matching arm64 template is selected" \
  "local:vztmpl/alpine-3.24-default_20260803_arm64.tar.xz" "$TEMPLATE_PATH"

CREATE_NODE=pve04
assert_failure_contains "unsupported target architecture fails closed" \
  "Unsupported template architecture 'riscv64'" prepare_template

cat > "$AVAILABLE" <<'EOF'
alpine-3.24-default_20260803_arm64.tar.xz
EOF
CREATE_NODE=pve02
assert_failure_contains "missing target architecture template fails closed" \
  "No amd64 template found" prepare_template

echo "${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]