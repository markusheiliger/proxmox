# Testing

Shared tests under `../tests/` are executable Bash programs with TAP-like `ok`
and `not ok` output. They source production functions where practical and
replace external commands with shell functions or fixture executables.

Workload-specific contracts are direct `_tests/test-*.sh` children below their
workload root. They derive that root as the parent of the script's `_tests/`
directory from `BASH_SOURCE[0]` and must not read another workload's tree.

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

Run workload contracts from the administrative node through `testCT.sh`:

```bash
./testCT.sh pdf.thesaints.home
./testCT.sh 2500
./testCT.sh --all
```

With no arguments, `testCT.sh` opens a multi-select checklist. It resolves each
CT's current owner node, discovers direct regular
`/mnt/docker/<hostname>/_tests/test-*.sh` files on that node, and executes them
in lexical order. Nested files and symlinks are ignored. Tests run on the owner
host rather than inside the CT, so stopped CTs and host-only workload files
remain testable. An explicitly selected CT without tests fails; batch modes skip
untested CTs.

A suite prints its pass/fail count and exits non-zero when an assertion fails.
Tests create temporary fixtures and clean them with traps.

## Ownership map

| Suite | Primary behavior |
| --- | --- |
| `test-backup-config.sh` | Backup configuration getters and validation |
| `test-backupCT.sh` | Hook state, snapshots, generations, hard links, and cluster helpers |
| `test-temp-storage.sh` | TEMP thin-LV and Proxmox storage reconciliation |
| `test-dry-run.sh` | Non-mutating lifecycle previews |
| `test-forwardAuthCT.sh` | Generated forward-auth label contract |
| `test-glances-policy.sh` | Shared Glances no-authentication policy |
| `test-lifecycle-logging.sh` | Latest-run capture, permissions, redaction, and entry-point coverage |
| `test-moveCT.sh` | Move transaction and rollback |
| `test-permissions.sh` | Compose service-user and bind ownership rules |
| `test-refresh.sh` | Refresh, initialization services, and permissions integration |
| `test-testCT.sh` | Workload discovery and cluster-owner dispatch |
| `test-upgradeCT.sh` | Alpine release paths and rollback |

## Test design

- Test policy before mutation.
- Mock Proxmox, SSH, Docker, LVM, ZFS, and network calls at process boundaries.
- Assert both success and fail-closed behavior.
- Keep shared lifecycle tests under `tests/` and workload contracts directly
  under the protected workload's `_tests/` directory.
- Treat CTIDs and hostnames used only inside isolated fixtures as test data, not
  workload ownership.
- Keep cross-workload guarantees local where possible; test shared generators
  separately instead of reading several production workload trees.
- Add regression coverage for operational incidents before changing the owning
  code path.

No repository-wide CI currently runs these suites, so a complete local run is a
required verification step for lifecycle changes.

## Related documentation

- [Tests folder](../tests/README.md)
- [Architecture](architecture.md)
- [Troubleshooting](troubleshooting.md)
