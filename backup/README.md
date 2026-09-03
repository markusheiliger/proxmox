# Backup Helpers

This directory contains the programs installed or invoked by `backupCT.sh` to
implement workload-aware Proxmox backups.

## Files

- `pve-workload-backup-hook`: Proxmox `vzdump` hook that validates prerequisites,
  snapshots CT bind datasets, mirrors immutable workload generations to NFS,
  reconciles interrupted state, and prunes orphaned generations.
- `provision-temp-storage`: idempotently creates or extends the node-local thin
  LV and ext4 filesystem used for suspend-mode rootfs staging.
- `reconcile-backup-jobs`: leader-elected reconciliation of exact LXC and QEMU
  job membership from cluster resources and exclusion tags.
- `reconcile-backup-jobs.service` and `.timer`: run reconciliation every 15
  minutes on each node; non-leaders exit without mutation.

These files are source artifacts. `backupCT.sh --install-hook` and
`--provision-temp` install copies on cluster nodes; edit the files here, not
deployed copies.

## Documentation

- [Backup operator guide](../backupCT.md)
- [VM backup operator guide](../backupVM.md)
- [Backup design](../documentation/backup-design.md)
- [Storage and permissions](../documentation/storage-and-permissions.md)
- [Backup tests](../tests/README.md)
