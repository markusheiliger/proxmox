#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/bin"
INTERFACES_FIXTURE="$TEST_ROOT/interfaces"
export INTERFACES_FIXTURE

cat >"$TEST_ROOT/bin/hostname" <<'EOF'
#!/usr/bin/env bash
printf 'testnode\n'
EOF
cat >"$TEST_ROOT/bin/cat" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == /etc/network/interfaces ]]; then
  /bin/cat "$INTERFACES_FIXTURE"
else
  /bin/cat "$@"
fi
EOF
chmod +x "$TEST_ROOT/bin/hostname" "$TEST_ROOT/bin/cat"
PATH="$TEST_ROOT/bin:$PATH"
# shellcheck source=../commonCT.sh
source "$SCRIPT_DIR/commonCT.sh"

passed=0
failed=0
pass() { echo "ok - $1"; passed=$((passed + 1)); }
fail() { echo "not ok - $1"; failed=$((failed + 1)); }
assert_selected() {
  local name="$1" expected="$2" type="$3" id="$4" hostname="$5"
  if bridge_policy_select testnode "$type" "$id" "$hostname" >/dev/null 2>&1 \
      && [[ "$BRIDGE_POLICY_SELECTED" == "$expected" ]]; then pass "$name"; else fail "$name"; fi
}
assert_failure() {
  local name="$1" type="$2" id="$3" hostname="$4"
  if bridge_policy_select testnode "$type" "$id" "$hostname" >/dev/null 2>&1; then fail "$name"; else pass "$name"; fi
}

cat >"$INTERFACES_FIXTURE" <<'EOF'
# Management & Entities: *
auto vmbr10
iface vmbr10 inet static
  bridge-ports eno1

# Entities: CT
auto vmbr2
iface vmbr2 inet manual
  bridge-ports bond0

# production; ENTITIES: 3500, seafile.thesaints.de
auto vmbr7
iface vmbr7 inet manual
  bridge-ports bond1

# entities: VM
auto vmbr3
iface vmbr3 inet manual
  bridge-ports bond2
EOF
assert_selected "exact ID outranks type and wildcard" vmbr7 CT 3500 other.example
assert_selected "hostname match is case-insensitive" vmbr7 CT 9999 SEAFILE.THESAINTS.DE
assert_selected "CT type outranks wildcard" vmbr2 CT 9999 other.example
assert_selected "VM type outranks wildcard" vmbr3 VM 9999 other.example

cat >"$INTERFACES_FIXTURE" <<'EOF'
# Entities: *
auto vmbr10
iface vmbr10 inet manual

# entities: *
auto vmbr2
iface vmbr2 inet manual
EOF
assert_selected "equal-rank tie uses numeric suffix" vmbr2 CT 100 other

cat >"$INTERFACES_FIXTURE" <<'EOF'
# entities: 100
iface vmbr8 inet manual

# entities: host.example
iface vmbr4 inet manual
EOF
assert_selected "ID and hostname share top rank and tie numerically" vmbr4 CT 100 host.example

cat >"$INTERFACES_FIXTURE" <<'EOF'
# NonEntities: *
iface vmbr1 inet manual
EOF
assert_failure "label must be standalone" CT 100 host

cat >"$INTERFACES_FIXTURE" <<'EOF'
# entities: CT
# Entities: *
iface vmbr1 inet manual
EOF
assert_failure "duplicate labels fail closed" CT 100 host

cat >"$INTERFACES_FIXTURE" <<'EOF'
# entities:
iface vmbr1 inet manual
EOF
assert_failure "empty policy fails closed" CT 100 host

cat >"$INTERFACES_FIXTURE" <<'EOF'
# entities: ROUTER
iface vmbr1 inet manual
EOF
assert_failure "no matching policy fails closed" CT 100 host

cat >"$INTERFACES_FIXTURE" <<'EOF'
# entities: *
iface br0 inet manual
EOF
assert_failure "custom bridge names are excluded" CT 100 host

rewrite=$(bridge_policy_rewrite_nic 'name=eth0,hwaddr=AA:BB,bridge=vmbr1,tag=20,firewall=1' vmbr7 false)
if [[ "$rewrite" == 'name=eth0,hwaddr=AA:BB,bridge=vmbr7,tag=20,firewall=1' ]]; then pass "rewrite preserves unrelated fields"; else fail "rewrite preserves unrelated fields"; fi
rewrite=$(bridge_policy_rewrite_nic 'virtio=AA:BB,tag=20' vmbr3 true)
if [[ "$rewrite" == 'virtio=AA:BB,tag=20,bridge=vmbr3,link_down=1' ]]; then pass "rewrite adds bridge and restore isolation"; else fail "rewrite adds bridge and restore isolation"; fi
rewrite=$(bridge_policy_rewrite_nic 'virtio=AA:BB,link_down=0,bridge=vmbr1' vmbr3 true)
if [[ "$rewrite" == 'virtio=AA:BB,link_down=1,bridge=vmbr3' ]]; then pass "rewrite normalizes link_down in place"; else fail "rewrite normalizes link_down in place"; fi
if bridge_policy_rewrite_nic 'name=eth0,bridge=vmbr1,bridge=vmbr2' vmbr3 false >/dev/null 2>&1; then fail "duplicate bridge fields are rejected"; else pass "duplicate bridge fields are rejected"; fi

echo "${passed} passed, ${failed} failed"
(( failed == 0 ))
