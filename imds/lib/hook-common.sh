#!/usr/bin/env bash

IMDS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMDS_GENERATOR="${PVE_IMDS_GENERATOR:-${IMDS_ROOT}/lib/pve-imds-generate}"
IMDS_PVESH="${PVE_IMDS_PVESH:-/usr/bin/pvesh}"
IMDS_LOCAL_LXC_CONFIG_DIR="${PVE_IMDS_LOCAL_LXC_CONFIG_DIR:-/etc/pve/local/lxc}"
IMDS_TIMEOUT_SECONDS="${PVE_IMDS_TIMEOUT_SECONDS:-5}"

imds_parse_file_path() {
  local path="$1"
  if [[ "$path" =~ ^/([1-9][0-9]{0,8})/(metadata|profiles)\.json$ ]]; then
    IMDS_CTID="${BASH_REMATCH[1]}"
    IMDS_KIND="${BASH_REMATCH[2]}"
    return 0
  fi
  return 1
}

imds_parse_ct_path() {
  local path="$1"
  if [[ "$path" =~ ^/([1-9][0-9]{0,8})$ ]]; then
    IMDS_CTID="${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

imds_list_local_ctids() {
  [[ "$IMDS_PVESH" == /* && -x "$IMDS_PVESH" ]] || return 69
  timeout --kill-after=1s "${IMDS_TIMEOUT_SECONDS}s" \
    "$IMDS_PVESH" get /nodes/localhost/lxc --output-format json \
    | jq -er '
        if type == "array"
          and all(.[]; (.vmid | type) == "number"
            and (.vmid | floor) == .vmid
            and .vmid >= 1
            and .vmid <= 999999999)
        then [.[].vmid] | unique | sort | .[]
        else error("invalid local LXC inventory")
        end
      '
}

imds_ct_is_local() {
  local ctid="$1"
  [[ "$ctid" =~ ^[1-9][0-9]{0,8}$ ]] || return 1
  [[ -f "${IMDS_LOCAL_LXC_CONFIG_DIR}/${ctid}.conf" ]]
}

imds_emit_stat() {
  local inode="$1" mode="$2" links="$3" size="$4" name="${5:-}"
  printf 'ino=%s mode=%s nlink=%s uid=0 gid=0 rdev=0 size=%s blksize=512 blocks=0 atime=0 mtime=0 ctime=0 %s' \
    "$inode" "$mode" "$links" "$size" "$name"
}

imds_dir_inode() {
  printf '%s' "$((2 + ($1 * 3)))"
}

imds_file_inode() {
  local ctid="$1" kind="$2" offset=1
  [[ "$kind" == profiles ]] && offset=2
  printf '%s' "$((2 + (ctid * 3) + offset))"
}

imds_generate_to_file() {
  local kind="$1" ctid="$2" output="$3"
  "$IMDS_GENERATOR" "$kind" "$ctid" >"$output"
}