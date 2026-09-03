# Troubleshooting

Start with the lifecycle guide for the command that failed. This page covers
cross-cutting diagnosis and directs recovery to the component that owns state.

## General checks

1. Read `/root/scripts/logs/<script>.log` and identify the last completed phase.
2. Confirm the CT status and Proxmox task status.
3. Check the relevant storage is active and has sufficient capacity.
4. Validate Compose configuration before restarting services.
5. Avoid deleting state until its owning script's recovery behavior is known.

Each finite lifecycle script keeps only its latest node-local run. The log
contains merged stdout and stderr plus start, end, exit-status, and duration
metadata. Known sensitive argument values are replaced with `REDACTED`, but a
child command that prints a secret can still place it in the log. Logs are
therefore root-only and must be reviewed before sharing. `monitorCT.sh` output
is not persisted by this mechanism.

## Compose startup and permissions

Permission reconciliation fails before mutation when a writable bind is unsafe,
a service user is ambiguous, or multiple writers disagree. Render the Compose
configuration and inspect `user:`, `PUID`/`PGID`, image user metadata, and
`permissions.thesaints.*` labels. Do not bypass the check with broad `chown`.

Initialization services are identified by `restart: "no"`. A non-zero exit is
fatal to create or refresh. Inspect that service's logs and make its operation
idempotent before retrying.

## Storage and backup

An undersized TEMP error refers to the managed block device's virtual capacity,
not free ext4 space. Reconcile it with `backupCT.sh --provision-temp`; the
provisioner grows but never shrinks the LV.

For interrupted backups, inspect `/var/lib/pve-workload-backup` and pending ZFS
snapshots before intervening. Valid known state is reconciled at the next
`job-init`; unknown state is deliberately retained. See
[Backup design](backup-design.md) and the [backup guide](../backupCT.md).

## Network and DNS

After VLAN or rename operations, verify the CT received an address on the
expected subnet, the network controller's fixed assignment matches its MAC, and
DNS resolves to that address. VLAN operations attempt rollback; do not repeat a
partial operation until the CT's current tag and address are known.

For secondary domains, inspect the split-DNS service and forwarding rules rather
than adding primary-domain records manually.

## Authentik

A generic `invalid_request` at the authorize endpoint usually requires checking
Authentik server logs. Verify grant types, redirect URI object structure, scope
property mappings, and flow identifiers. Rerunning an idempotent configure
script should patch an existing provider and repair supported drift.

## Upgrade and move recovery

`upgradeCT.sh` appends failure diagnostics to `logs/upgradeCT.log` and uses its pre-upgrade rollback
point unless `--keep-failed` was selected. `moveCT.sh` attempts to restore data,
CT placement, and original running state after target verification fails. Read
their adjacent guides before manually moving datasets or rolling back snapshots.

`cannot migrate local bind mount point 'mpN'` means Proxmox was asked to migrate
a CT while a host bind mount was still attached. Current `moveCT.sh` avoids this
by temporarily detaching accepted mounts only while the CT is stopped, then
restoring their exact values on the owning node. For an older or interrupted
run, first inspect CT ownership and its `mpN` configuration in
`/root/scripts/logs/moveCT.log`; do not manually delete source or target data.
An incomplete rollback intentionally leaves the CT stopped and both copies
present for recovery.

New move transactions persist under `/etc/pve/priv/moveCT/<CTID>.json`. After a
dropped SSH session, use `moveCT.sh --status <CT>` first. If its Proxmox UPID is
still running, do not abort or submit another migration; `--resume` waits for
that same task and continues mount and service recovery. Signals checkpoint
rather than rolling back because the node-owned Proxmox task may outlive its
client. Use `--abort` only after status shows a terminal task and consistent
ownership.

An older script could print `jq: parse error` immediately after the
`mounts_detached` checkpoint because local `pvesh` runs a worker synchronously
and returned its accumulated migration log rather than a UPID. Current task
submission starts the CLI waiter separately, discovers the new native
`vzmigrate` UPID from task history before checkpointing, and confines automatic
recovery to the coordinator shell so one failure cannot start duplicate
rollback passes.

`No vmbr<number> entities: policies found`, `No bridge policy ... matches`, or
`Selected bridge ... does not exist` is a fail-closed bridge-policy error. On
the named node, inspect `/etc/network/interfaces`, add one standalone
case-insensitive `entities:` label to the intended `vmbr<number>` stanza, and
ensure the Linux bridge exists at runtime. Matching precedence is exact ID or
hostname/name, `CT`/`VM`, then `*`; equal-rank matches select the lowest bridge
number. Do not work around the error with a `BRIDGE` environment variable.

Runs made before checkpoint support have no state file. For those,
`moveCT.sh --status <CT> --node <expected-target>` prints a read-only legacy
inspection. Preserve both workload copies until CT ownership, the latest
migration task, rootfs volumes, and exact bind mounts agree.

## Related documentation

- [Documentation index](README.md)
- [Storage and permissions](storage-and-permissions.md)
- [Networking and authentication](networking-and-authentication.md)
- [Testing](testing.md)
