#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
PASS=0
FAIL=0

pass() { echo "ok - $1"; PASS=$((PASS + 1)); }
fail() { echo "not ok - $1" >&2; FAIL=$((FAIL + 1)); }

source "${SCRIPT_DIR}/commonCT.sh"

mount_config=""
ct_status=stopped
commands="${TEST_ROOT}/commands"
failure_at=""
start_failures=0
mutation_count=0

get_ct_owner_node() { printf '%s\n' "${MOCK_OWNER:-pve02}"; }
warn_if_imds_unavailable() { :; }
get_ct_status() { printf '%s\n' "$ct_status"; }
pct_config() { printf '%s\n' "$mount_config"; }
pct_stop() { printf 'stop %s\n' "$1" >>"$commands"; ct_status=stopped; }
pct_start() {
  printf 'start %s\n' "$1" >>"$commands"
  if ((start_failures > 0)); then
    start_failures=$((start_failures - 1))
    return 1
  fi
  ct_status=running
}
sleep() { :; }
pct_set() {
  local ctid="$1" operation="$2" value="${3:-}" key
  mutation_count=$((mutation_count + 1))
  printf 'set %s %s %s\n' "$ctid" "$operation" "$value" >>"$commands"
  [[ -z "$failure_at" || "$mutation_count" -ne "$failure_at" ]] || return 1
  if [[ "$operation" == -delete ]]; then
    key="$value"
    mount_config=$(sed -E "/^${key}:/d" <<<"$mount_config")
  else
    key="${operation#-}"
    mount_config+="${mount_config:+$'\n'}${key}: ${value}"
    mount_config=$(sort -V <<<"$mount_config")
  fi
}

desired=$(canonical_ct_mounts 2100 app.thesaints.home)

reordered=$'mp0: /run/pve-imds/2100,shared=1,backup=0,mp=/mnt/pve-imds,ro=1\nmp1: /mnt/docker/app.thesaints.home,mp=/mnt/docker\nmp2: /mnt/docker-data/app.thesaints.home,mp=/mnt/docker-data'
if ct_mounts_match "$reordered" "$desired"; then
  pass "mount comparison accepts Proxmox option reordering"
else
  fail "mount comparison accepts Proxmox option reordering"
fi

: >"$commands"
mount_config=""
ct_status=stopped
mutation_count=0
if reconcile_ct_mountpoints 2100 app.thesaints.home >/dev/null \
  && [[ "$mount_config" == "$desired" ]] \
  && ! grep -Eq '^(stop|start) ' "$commands"; then
  pass "fresh stopped CT receives exactly canonical mp0-mp2"
else
  fail "fresh stopped CT receives exactly canonical mp0-mp2"
fi

: >"$commands"
mount_config="$desired"
ct_status=running
mutation_count=0
if reconcile_ct_mountpoints 2100 app.thesaints.home >/dev/null \
  && [[ ! -s "$commands" ]]; then
  pass "canonical running CT is an idempotent no-op"
else
  fail "canonical running CT is an idempotent no-op"
fi

: >"$commands"
mount_config=$'mp0: /mnt/docker/app.thesaints.home,mp=/mnt/docker\nmp1: /mnt/docker-data/app.thesaints.home,mp=/mnt/docker-data\nmp4: /srv/extra,mp=/srv/extra'
ct_status=running
mutation_count=0
if reconcile_ct_mountpoints 2100 app.thesaints.home >/dev/null \
  && [[ "$mount_config" == "$desired" ]] \
  && [[ "$(grep -E '^(stop|start) ' "$commands" | paste -sd, -)" == 'stop 2100,start 2100' ]]; then
  pass "legacy running CT is stopped, canonicalized, and extra mounts are deleted"
else
  cat "$commands" >&2
  fail "legacy running CT is stopped, canonicalized, and extra mounts are deleted"
fi

: >"$commands"
original=$'mp0: /mnt/docker/app.thesaints.home,mp=/mnt/docker\nmp1: /mnt/docker-data/app.thesaints.home,mp=/mnt/docker-data\nmp3: /srv/extra,mp=/srv/extra'
mount_config="$original"
ct_status=running
mutation_count=0
failure_at=5
if reconcile_ct_mountpoints 2100 app.thesaints.home >/dev/null 2>&1; then
  fail "failed reconciliation returns nonzero"
elif [[ "$mount_config" == "$original" && "$ct_status" == running ]]; then
  pass "failed reconciliation restores exact mounts and running state"
else
  printf '%s\n' "$mount_config" >&2
  fail "failed reconciliation restores exact mounts and running state"
fi
failure_at=""

: >"$commands"
original=$'mp0: /mnt/docker/app.thesaints.home,mp=/mnt/docker\nmp1: /mnt/docker-data/app.thesaints.home,mp=/mnt/docker-data'
mount_config="$original"
ct_status=running
mutation_count=0
start_failures=1
if reconcile_ct_mountpoints 2100 app.thesaints.home >/dev/null 2>&1; then
  fail "failed canonical restart returns nonzero"
elif [[ "$mount_config" == "$original" && "$ct_status" == running \
  && "$(grep -E '^(stop|start) ' "$commands" | paste -sd, -)" == 'stop 2100,start 2100,start 2100' ]]; then
  pass "failed canonical restart restores exact mounts and original running state"
else
  cat "$commands" >&2
  fail "failed canonical restart restores exact mounts and original running state"
fi
start_failures=0

echo "${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]