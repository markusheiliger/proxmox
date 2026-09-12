# Proxmox instance metadata filesystem

This directory contains the node-local, script-backed instance metadata
filesystem, cluster deployment tooling, and CT lifecycle mount integration.

## Virtual tree

One `execfuse` process exposes the CTs owned by the local node:

```text
/run/pve-imds/
└── <CTID>/
    ├── metadata.json
    └── profiles.json
```

The root CTID list is read from the node-local Proxmox API:

```bash
pvesh get /nodes/localhost/lxc --output-format json
```

`metadata.json` is generated from:

```bash
pvesh get /nodes/localhost/lxc/<CTID>/config --output-format json
```

The generator removes host-bound fields before exposing the API object:
`rootfs`, `hookscript`, `ssh-public-keys`, `lxc`, and top-level `mpN` and
`devN` keys.

`profiles.json` applies `filters/profiles.jq` to the same redacted API object.
It accepts strict `profile-<group>-<name>` tags and removes only the leading
`profile-`, returning sorted values such as `gpu-drm_intel`. Group and name use
lowercase alphanumeric or underscore characters. Malformed profile tags and
multiple tags for one group fail generation.

Directory locality checks use `/etc/pve/local/lxc/<CTID>.conf` so a stopped CT
remains visible while Proxmox runs its pre-start hook. Root enumeration and
metadata generation continue to use the Proxmox API.

## Snapshot behavior

Execfuse invokes `read_file` lazily. The first read on an open descriptor
generates and buffers the entire file. Later offset reads on that descriptor
use the buffered bytes; a newly opened descriptor retrieves current Proxmox
state.

## Build

The current POC pins execfuse commit
`91bf488c1293ebe1d88aa17c8c2ee97d2593c16a`. On Debian 13/PVE 9 the build
requires:

```bash
apt-get install build-essential pkg-config libfuse-dev
```

Build to an absolute path outside this source tree:

```bash
./build-execfuse.sh /tmp/execfuse
```

The build verifies the source archive checksum and produces byte-identical
binaries across clean temporary build directories.

## Tests

Run the pure generator and hook protocol tests:

```bash
../tests/test-imds-generator.sh
../tests/test-imds-hooks.sh
```

Run the real mounted FUSE test when `/dev/fuse` and the build dependencies are
available:

```bash
../tests/test-imds-fuse.sh
```

The mounted test uses temporary fixture data and cleans up its mount. It covers
dynamic CT listings, exact `getattr` sizes, read-only behavior, offset reads,
first-read snapshots, concurrent readers, and access through `allow_other` as
an unprivileged host user.

## Deployment

Install or upgrade the immutable release on every online Proxmox node:

```bash
./deploy.sh
```

The deployment builds the pinned engine once, validates that online nodes use
the same supported architecture, transfers a checksummed release bundle, and
installs it below `/usr/local/libexec/pve-imds/releases/`. The atomic `current`
symlink selects the release used on the next service start.

If the service is already active and a node has configured IMDS CT binds, the
new release is staged without restarting the FUSE connection. A reboot or
maintenance window activates it. Nodes without consumers restart and verify
the new release immediately. Offline nodes are reported as pending and cause a
nonzero partial-convergence result.

Verify installation and runtime health across the cluster without changing
node or service state:

```bash
./deploy.sh --verify
```

Every cluster node receives one concise status line. Online nodes are reported
as `HEALTHY`, `STAGED`, `NOT INSTALLED`, `BROKEN`, `UNHEALTHY`, or
`UNREACHABLE`; offline nodes are `UNVERIFIED`. `HEALTHY` requires a complete
managed installation, matching active and current releases, an active service,
a host-visible read-only FUSE mount, and valid generated metadata and profile
JSON. `STAGED` means the healthy active release differs from the release
selected for the next service start.

Verification exits successfully only when every cluster node is online,
converged, and healthy. It does not build, install, repair, restart, enable,
disable, mount, or unmount anything.

Lifecycle reconciliation mounts `/run/pve-imds/<CTID>` read-only at
`/mnt/pve-imds` as `mp0`, followed by Docker at `mp1` and Docker-data at `mp2`.
The persistent guest target avoids Alpine boot cleanup of children below `/run`.
It removes unrelated mounts on success and restores the exact original mount
set and running state if configuration or startup fails.

Remove the service from all online nodes:

```bash
./deploy.sh --remove
```

Removal first scans all cluster CT configurations, including offline owners.
Any configured IMDS bind blocks every removal mutation. The command never
stops CTs or removes their mount entries.

## Follow-up

The service and lifecycle integration are deployed. One non-runtime follow-up
remains:

- Clarify execfuse's redistribution license. Its `LICENSE` file is ambiguous,
  despite other repository metadata referring to GPL-2.0+.