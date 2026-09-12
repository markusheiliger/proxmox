#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/dependencies/execfuse.lock"

if [[ $# -ne 1 || "$1" != /* ]]; then
  echo "Usage: build-execfuse.sh <absolute-output-path>" >&2
  exit 64
fi

for command in curl make pkg-config tar sha256sum install; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "ERROR: required build command is unavailable: ${command}" >&2
    exit 69
  }
done

pkg-config --exists fuse || {
  echo "ERROR: libfuse development files are unavailable" >&2
  exit 69
}

output="$1"
build_dir="$(mktemp -d)"
trap 'rm -rf "$build_dir"' EXIT
archive="${build_dir}/execfuse.tar.gz"
source_dir="${build_dir}/source"
archive_url="${EXECFUSE_REPOSITORY}/archive/${EXECFUSE_COMMIT}.tar.gz"

curl -fsSL "$archive_url" -o "$archive"
printf '%s  %s\n' "$EXECFUSE_ARCHIVE_SHA256" "$archive" | sha256sum -c - >/dev/null

mkdir "$source_dir"
tar -xzf "$archive" --strip-components=1 -C "$source_dir"
make -C "$source_dir" execfuse \
  CFLAGS="-O2 -Wall -ffile-prefix-map=${source_dir}=/usr/src/execfuse" \
  LDFLAGS="-Wl,--build-id=none"
install -D -m 0755 "${source_dir}/execfuse" "$output"