#!/usr/bin/env bash
set -Eeuo pipefail

RUNTIME_ROOT=/usr/local/libexec/pve-imds
HEALTH_PATH=/usr/local/sbin/pve-imds-health
UNIT_PATH=/etc/systemd/system/pve-imds.service
MOUNTPOINT=/run/pve-imds

remove_installation() {
  local filesystem=""
  if mountpoint -q "$MOUNTPOINT"; then
    filesystem="$(findmnt -rn -o FSTYPE --target "$MOUNTPOINT")"
    [[ "$filesystem" == fuse.pve-imds ]] || {
      echo "ERROR: refusing to unmount unexpected filesystem ${filesystem} at ${MOUNTPOINT}." >&2
      return 1
    }
  fi

  systemctl disable --now pve-imds.service 2>/dev/null || true
  if mountpoint -q "$MOUNTPOINT"; then
    timeout 10 fusermount -u "$MOUNTPOINT" || {
      echo "ERROR: cannot unmount ${MOUNTPOINT}." >&2
      return 1
    }
  fi
  rm -f "$UNIT_PATH" "$HEALTH_PATH"
  if [[ -e "$RUNTIME_ROOT" && ! -d "$RUNTIME_ROOT" ]]; then
    echo "ERROR: refusing to remove unexpected ${RUNTIME_ROOT}." >&2
    return 1
  fi
  if [[ -d "$RUNTIME_ROOT" ]]; then
    [[ -f "$RUNTIME_ROOT/.pve-imds-managed" ]] || {
      echo "ERROR: refusing to remove unmarked runtime directory ${RUNTIME_ROOT}." >&2
      return 1
    }
    rm -rf "$RUNTIME_ROOT"
  fi
  rmdir "$MOUNTPOINT" 2>/dev/null || true
  systemctl daemon-reload
  systemctl reset-failed pve-imds.service 2>/dev/null || true
  echo "Removed pve-imds from $(hostname -s)."
}

if [[ "${1:-}" == --remove ]]; then
  [[ $# -eq 1 ]] || exit 64
  remove_installation
  exit
fi

[[ $# -eq 2 ]] || { echo "Usage: install-release.sh <bundle-dir> <release-id>|--remove" >&2; exit 64; }
bundle="$1"
release_id="$2"
[[ "$release_id" =~ ^[a-f0-9]{16}$ ]] || { echo "ERROR: invalid release ID." >&2; exit 65; }
[[ -d "$bundle/release" && -f "$bundle/pve-imds.service" && -x "$bundle/pve-imds-health" ]] || {
  echo "ERROR: incomplete release bundle." >&2
  exit 66
}
(
  cd "$bundle"
  sha256sum -c bundle-checksums.sha256 >/dev/null
)

command -v pvesh >/dev/null 2>&1 || { echo "ERROR: pvesh is unavailable." >&2; exit 69; }
[[ -c /dev/fuse ]] || { echo "ERROR: /dev/fuse is unavailable." >&2; exit 69; }

packages=()
command -v jq >/dev/null 2>&1 || packages+=(jq)
command -v fusermount >/dev/null 2>&1 || packages+=(fuse)
if ! ldconfig -p | grep -q 'libfuse\.so\.2'; then
  if apt-cache show libfuse2t64 >/dev/null 2>&1; then
    packages+=(libfuse2t64)
  else
    packages+=(libfuse2)
  fi
fi
if (( ${#packages[@]} > 0 )); then
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${packages[@]}"
fi

for command in jq fusermount findmnt systemctl timeout; do
  command -v "$command" >/dev/null 2>&1 || { echo "ERROR: missing runtime dependency: ${command}" >&2; exit 69; }
done
ldconfig -p | grep -q 'libfuse\.so\.2' || { echo "ERROR: libfuse2t64 is unavailable." >&2; exit 69; }

(
  cd "$bundle/release"
  sha256sum -c checksums.sha256 >/dev/null
)

if [[ -d "$RUNTIME_ROOT" && ! -f "$RUNTIME_ROOT/.pve-imds-managed" ]]; then
  echo "ERROR: refusing to use unmarked runtime directory ${RUNTIME_ROOT}." >&2
  exit 73
fi
install -d -o root -g root -m 0755 "$RUNTIME_ROOT/releases"
printf 'pve-imds\n' >"$RUNTIME_ROOT/.pve-imds-managed"
chown root:root "$RUNTIME_ROOT/.pve-imds-managed"
chmod 0644 "$RUNTIME_ROOT/.pve-imds-managed"
destination="$RUNTIME_ROOT/releases/$release_id"
if [[ -e "$destination" ]]; then
  [[ -d "$destination" ]] || { echo "ERROR: release destination is not a directory." >&2; exit 73; }
  (cd "$destination" && sha256sum -c checksums.sha256 >/dev/null) || {
    echo "ERROR: installed release ${release_id} failed verification." >&2
    exit 73
  }
else
  temporary="$RUNTIME_ROOT/releases/.${release_id}.$$"
  mkdir "$temporary"
  cp -a "$bundle/release/." "$temporary/"
  chown -R root:root "$temporary"
  find "$temporary" -type d -exec chmod 0755 {} +
  chmod 0755 "$temporary/execfuse" "$temporary"/hooks/* "$temporary/lib/pve-imds-generate"
  chmod 0644 "$temporary/checksums.sha256" "$temporary"/filters/* "$temporary/lib/hook-common.sh"
  mv "$temporary" "$destination"
fi

previous="$(readlink "$RUNTIME_ROOT/current" 2>/dev/null || true)"
link_tmp="$RUNTIME_ROOT/.current.$$"
ln -s "releases/$release_id" "$link_tmp"
mv -Tf "$link_tmp" "$RUNTIME_ROOT/current"
install -D -o root -g root -m 0755 "$bundle/pve-imds-health" "$HEALTH_PATH"
install -D -o root -g root -m 0644 "$bundle/pve-imds.service" "$UNIT_PATH"
[[ "$(sha256sum "$HEALTH_PATH" | awk '{print $1}')" == "$(sha256sum "$bundle/pve-imds-health" | awk '{print $1}')" ]] || {
  echo "ERROR: installed health command failed verification." >&2
  exit 74
}
[[ "$(sha256sum "$UNIT_PATH" | awk '{print $1}')" == "$(sha256sum "$bundle/pve-imds.service" | awk '{print $1}')" ]] || {
  echo "ERROR: installed systemd unit failed verification." >&2
  exit 74
}
systemctl daemon-reload

if ! systemctl is-active --quiet pve-imds.service; then
  systemctl enable --now pve-imds.service
  "$HEALTH_PATH" --wait
  echo "Activated pve-imds ${release_id} on $(hostname -s)."
elif [[ "$previous" == "releases/$release_id" ]]; then
  systemctl enable pve-imds.service >/dev/null
  "$HEALTH_PATH"
  echo "pve-imds ${release_id} is already active on $(hostname -s)."
elif grep -Eq '^mp[0-9]+: .*mp=/mnt/pve-imds(,|$)' /etc/pve/lxc/*.conf 2>/dev/null; then
  systemctl enable pve-imds.service >/dev/null
  echo "Staged pve-imds ${release_id} on $(hostname -s); active CT binds defer restart."
  exit 10
else
  systemctl restart pve-imds.service
  "$HEALTH_PATH" --wait
  echo "Activated pve-imds ${release_id} on $(hostname -s)."
fi