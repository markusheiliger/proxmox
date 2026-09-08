---
applyTo: "**/test-*.sh"
description: "Use when creating or modifying Bash tests: cluster-aware CT fixtures, workload-test ownership, owner-node execution, and shared test boundaries."
---

# Cluster-aware Bash tests

All tests must preserve the repository's multi-node Proxmox model. A test may use
synthetic CTIDs, hostnames, and paths, but it must not imply that the
administrative node owns every CT.

## CT and node behavior

- Any test that exercises CT-specific production behavior must include at least
  one fixture where the administrative node and CT owner differ, such as
  `pve01` and `pve02`.
- Assert the destination node as well as the command. Prove that `pct`, rootfs,
  storage, `/etc/pve/lxc`, `/mnt/docker/<hostname>`, and
  `/mnt/docker-data/<hostname>` operations use the resolved owner.
- Mock the same boundary production uses: `get_ct_owner_node`, `run_on_node`,
  `run_node_shell`, `ct_pct`, or the relevant node-safe wrapper. Do not replace a
  cluster-aware wrapper with a local command mock in a way that hides routing.
- For batch behavior, include CTs on different owner nodes and verify each item
  is dispatched independently.
- Exercise owner-resolution failure where it is part of the production
  contract. Tests must fail closed rather than silently fall back to localhost.
- Keep remote-owner mocks isolated in a subshell or restore them before later
  cases so fixture state cannot leak through a shared sourced script.

Direct local `pct`, ZFS, LVM, or host-path access is valid only for code that is
intentionally node-local, such as a vzdump hook invoked on the owner node. The
test must make that execution context explicit. Cluster-global policy,
documentation contracts, and pure parsing tests do not need artificial CT-owner
fixtures when they perform no CT-specific operation.

## Workload test ownership

- Shared lifecycle, generator, policy, and mocked infrastructure tests belong in
  `/root/scripts/tests`.
- A test that reads one workload's real Compose, configuration, migration, or
  state files belongs directly in `/mnt/docker/<hostname>/` beside
  `docker-compose.yaml`.
- Name workload tests `test-*.sh`, such as `test-compose.sh`,
  `test-permissions.sh`, or `test-readiness.sh`. Do not add `_tests/`, `tests/`,
  or a metadata manifest.
- Derive `WORKLOAD_ROOT` from `BASH_SOURCE[0]`. Do not embed a CTID, owner node,
  or absolute hostname-qualified source root.
- A workload test must not read a sibling workload tree or depend on
  `/root/scripts` existing on a worker node. Move shared policy and generator
  assertions into `/root/scripts/tests`.
- Keep Compose paths inside asserted workload configuration CT-local:
  `/mnt/docker` and `/mnt/docker-data`, never hostname-qualified host paths.

## Execution and validation

- Run workload tests through `/root/scripts/testCT.sh`; it resolves current CT
  ownership and executes root-level tests against authoritative owner-node
  storage in lexical order.
- Workload tests execute on the owner host, not inside the CT. They must work
  when invoked from an unrelated current directory and when the CT is stopped.
- An explicitly selected CT without tests is an error; interactive and `--all`
  batches skip untested CTs.
- Run the focused suite first, then all `/root/scripts/tests/test-*.sh` suites.
  For workload changes, also run the relevant explicit `testCT.sh` target and
  `testCT.sh --all` when cluster access is available.
- Validate strict-mode syntax, executable file modes, editor diagnostics, and
  `git diff --check` for every changed test.