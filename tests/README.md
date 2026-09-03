# Tests

This directory contains focused Bash regression suites for lifecycle and shared
infrastructure behavior. Tests mock external Proxmox, Docker, storage, SSH, and
network boundaries while exercising production shell functions.

Run every suite from the repository root:

```bash
for test in tests/test-*.sh; do
  bash "$test"
done
```

Run the narrow suite first while changing a feature. Each script reports TAP-like
results and exits non-zero on failure.

## Suite map

- `test-backup-config.sh`, `test-backupCT.sh`, `test-backupVM.sh`,
  `test-backup-reconciler.sh`, and `test-temp-storage.sh`: backup configuration,
  CT hooks, QEMU lifecycle, automatic enrollment, and TEMP provisioning.
- `test-dry-run.sh`: mutation-free lifecycle previews.
- `test-moveCT.sh`: migration and rollback.
- `test-permissions.sh`: bind ownership policy.
- `test-refresh.sh`: refresh and initialization behavior.
- `test-upgradeCT.sh`: release upgrades and rollback.

See [Testing](../documentation/testing.md) for detailed ownership and test-design
rules.
