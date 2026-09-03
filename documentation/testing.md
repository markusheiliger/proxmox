# Testing

Tests under `../tests/` are executable Bash programs with TAP-like `ok` and
`not ok` output. They source production functions where practical and replace
external commands with shell functions or fixture executables.

## Run the suites

From `/root/scripts`:

```bash
for test in tests/test-*.sh; do
  bash "$test"
done
```

Run one focused suite while developing:

```bash
bash tests/test-backupCT.sh
bash tests/test-moveCT.sh
bash tests/test-permissions.sh
```

A suite prints its pass/fail count and exits non-zero when an assertion fails.
Tests create temporary fixtures and clean them with traps.

## Ownership map

| Suite | Primary behavior |
| --- | --- |
| `test-backup-config.sh` | Backup configuration getters and validation |
| `test-backupCT.sh` | Hook state, snapshots, generations, hard links, and cluster helpers |
| `test-temp-storage.sh` | TEMP thin-LV and Proxmox storage reconciliation |
| `test-dry-run.sh` | Non-mutating lifecycle previews |
| `test-lifecycle-logging.sh` | Latest-run capture, permissions, redaction, and entry-point coverage |
| `test-moveCT.sh` | Move transaction and rollback |
| `test-permissions.sh` | Compose service-user and bind ownership rules |
| `test-refresh.sh` | Refresh, initialization services, and permissions integration |
| `test-upgradeCT.sh` | Alpine release paths and rollback |

## Test design

- Test policy before mutation.
- Mock Proxmox, SSH, Docker, LVM, ZFS, and network calls at process boundaries.
- Assert both success and fail-closed behavior.
- Keep tests with the feature they protect, even when that feature is not yet
  committed.
- Add regression coverage for operational incidents before changing the owning
  code path.

No repository-wide CI currently runs these suites, so a complete local run is a
required verification step for lifecycle changes.

## Related documentation

- [Tests folder](../tests/README.md)
- [Architecture](architecture.md)
- [Troubleshooting](troubleshooting.md)
