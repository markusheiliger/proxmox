# backupVM.sh

Manages the dedicated Proxmox QEMU backup lifecycle. VM backups use native
QEMU snapshot mode and remain separate from workload-aware LXC backups.

## Usage

```bash
./backupVM.sh ACTION [options]
```

| Action | Purpose |
| --- | --- |
| `--configure-job` | Create or fully reconcile the QEMU vzdump job |
| `--reconcile-job` | Refresh eligible VMIDs on an existing job |
| `--run <VMID\|hostname\|all>` | Run an immediate QEMU snapshot backup |
| `--verify` | Verify a recent `.vma.zst` archive for every eligible VM |
| `--restore-test <VM>` | Restore the newest archive into an isolated VM |

`--restore-test` requires `--restore-id <unused-VMID>` and accepts `--node`.
The node defaults to the source VM's node. `--force` skips confirmation. All
mutating actions support `--dry-run`.

## Initial setup

The CT hook installer also deploys the shared backup selection reconciler and
its timer on every online node. Configure both jobs from one Proxmox host:

```bash
./backupCT.sh --install-hook
./backupCT.sh --configure-job
./backupVM.sh --configure-job
./backupVM.sh --verify
```

Policy comes from `commonCT.json`. `backup.vm` selects the QEMU destination and
schedule, while `backup.exclude` lists tags omitted from both CT and VM jobs.

Job configuration requires the configured backup storage to report active on
every online cluster node. Immediate backups repeat that check for the VM's
current node before invoking `vzdump`.

## Secure Boot certificate warning

An otherwise successful Windows backup can finish with `WARNINGS: 1` when its
OVMF EFI disk lacks Microsoft's 2023 Secure Boot certificates. The 2011
certificates expired in June 2026, so this is guest firmware maintenance rather
than a backup transport failure.

Before enrollment, record the BitLocker recovery key and run
`manage-bde -protectors -disable <drive>` in an elevated Windows PowerShell for
every protected drive. Shut the VM down cleanly, then run
`qm enroll-efi-keys <VMID>` on its Proxmox owner node. Boot the guest, verify
Secure Boot and TPM health, and re-enable each protector with
`manage-bde -protectors -enable <drive>`. Finally, run `--run <VMID>` and
`--verify`; the backup task should complete without the EFI certificate
warning. Do not enroll keys while BitLocker protectors remain active unless the
recovery-key boot path has been explicitly accepted.

## Selection

Both jobs use exact VMID lists. Eligible QEMU guests are cluster resources of
type `qemu` without any configured exclusion tag. `backup.exclude` defaults to
`["no-backup"]`. The internal `backup-restore-test` safety tag is always
excluded in addition to the configured list.

The `reconcile-backup-jobs.timer` runs on every node every 15 minutes. The
lexically first online node is elected to update both existing jobs, so VMs or
CTs created directly through Proxmox are enrolled without concurrent writes.
A single shared prune policy is reasserted on both jobs during reconciliation,
so retention changes or UI drift cannot make CT and VM retention diverge.
A missing job is reported but not created; use the corresponding
`--configure-job` action for initial creation and full policy reconciliation.

## Restore testing

The restore test uses `qmrestore --unique 1`, applies the
`backup-restore-test` tag, disables on-boot startup, and forces every restored
NIC onto the bridge selected for the restored VMID and VM name by the restore
node's `entities:` policy. Every NIC is also forced to `link_down=1` before
boot, while all unrelated NIC fields are preserved. It validates disk paths, starts the VM briefly,
checks its state and optional guest agent, then stops and retains it for
inspection. On failure after creation, it attempts to stop the VM and leaves it
available for diagnosis.

Destroy the retained test VM only after inspection:

```bash
qm destroy <restore-VMID> --destroy-unreferenced-disks 1 --purge 1
```

## Design boundary

QEMU snapshot backup consistency is provided by Proxmox/QEMU. The VM job must
not use `pve-workload-backup-hook` or `/TEMP`; those exist only for LXC rootfs
suspend staging and host-side workload dataset generations.

## Related

- [CT backup guide](backupCT.md)
- [Backup design](documentation/backup-design.md)
- [Backup helpers](backup/README.md)
