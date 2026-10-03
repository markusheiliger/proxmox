# testCT.sh

Runs workload-owned Bash contracts from the authoritative Proxmox owner node.

## Usage

```bash
./testCT.sh <CTID|hostname>
./testCT.sh --all
./testCT.sh
```

| Form | Effect |
| --- | --- |
| `<CTID|hostname>` | Test one explicitly selected CT |
| `--all` | Test every discovered CT and skip CTs without tests |
| No arguments | Open the standard multi-select checklist |
| `-h`, `--help` | Show usage |

An explicitly selected CT without workload tests is an error. Interactive and
`--all` runs report such CTs as skipped. The final exit status is nonzero when
discovery fails or any workload test fails; remaining selected tests still run.

## Discovery and execution

For each selected CT, the runner:

1. Resolves the CTID and hostname from cluster inventory.
2. Resolves the CT's current owner node.
3. Discovers regular direct `/mnt/docker/<hostname>/_tests/test-*.sh` files on
   that node.
4. Sorts test basenames lexically.
5. Runs each test with Bash on the owner host.

Tests do not run inside the CT. This allows contracts to inspect files that are
not mounted into the guest and allows stopped CTs to be tested. Owner-node
resolution also avoids reading stale or absent workload trees after migration.

## Workload test contract

Place tests directly under `_tests/` beside the workload's `docker-compose.yaml`:

```text
/mnt/docker/example.thesaints.home/
├── docker-compose.yaml
└── _tests/
   ├── test-compose.sh
   ├── test-permissions.sh
   └── test-readiness.sh
```

Each script must use Bash strict mode and derive its workload root from the
parent of its `_tests/` directory:

```bash
#!/usr/bin/env bash
set -euo pipefail

WORKLOAD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="${WORKLOAD_ROOT}/docker-compose.yaml"
```

Only direct regular `test-*.sh` children are discovered; nested files and
symlinks are ignored. Do not embed a CTID, owner node, or sibling workload path.
Keep shared lifecycle and generator tests under `/root/scripts/tests`.

## Related

- [Testing](documentation/testing.md)
- [Tests folder](tests/README.md)
- [Move](moveCT.md)