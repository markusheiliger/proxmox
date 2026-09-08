# Tests

This directory contains focused Bash regression suites for lifecycle and shared
infrastructure behavior. Workload-owned contracts live beside each workload's
`docker-compose.yaml` as root-level `test-*.sh` files.

Run every suite from the repository root:

```bash
for test in tests/test-*.sh; do
  bash "$test"
done
```

Run the narrow suite first while changing a feature. Each script reports TAP-like
results and exits non-zero on failure.

Run workload tests through the cluster-aware runner:

```bash
./testCT.sh pdf.thesaints.home
./testCT.sh 2500
./testCT.sh --all
```

## Suite map

- `test-backup-config.sh`, `test-backupCT.sh`, `test-backupVM.sh`,
  `test-backup-reconciler.sh`, and `test-temp-storage.sh`: backup configuration,
  CT hooks, QEMU lifecycle, automatic enrollment, and TEMP provisioning.
- `test-dry-run.sh`: mutation-free lifecycle previews.
- `test-forwardAuthCT.sh`: generated Authentik forward-auth label contract.
- `test-glances-policy.sh`: shared Glances no-authentication policy contract.
- `test-moveCT.sh`: migration and rollback.
- `test-optimization-contract.sh`: fail-closed image, advisory, artifact, and guest
  OS upgrade verification contracts for Recon and `ct-optimize`.
- `test-permissions.sh`: bind ownership policy.
- `test-refresh.sh`: refresh and initialization behavior.
- `test-testCT.sh`: workload discovery, owner-node routing, selection, ordering,
  skip behavior, and failure aggregation.
- `test-upgradeCT.sh`: release upgrades and rollback.

See [Testing](../documentation/testing.md) for detailed ownership and test-design
rules.
