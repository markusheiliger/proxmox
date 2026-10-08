---
applyTo: "**/*.sh"
description: "Use when creating or modifying Proxmox lifecycle Bash scripts: strict mode, idempotency, CT selection, progress accounting, and shared globals."
---

# Proxmox lifecycle Bash scripts

Scripts run with `set -euo pipefail`; all generated Bash must be safe under strict mode.

## Strict-mode rules

- Handle expected command failures explicitly with `if`, `!`, or `|| true`. A command substitution such as `value=$(grep ... || true)` must not terminate the script when no match is valid.
- Default optional arguments and variables with `${1:-}` or `${VAR:-default}` before use.
- Under `pipefail`, handle failure from every command in a pipeline, not only the last command.
- Catch non-fatal function failures explicitly and return success only when continuing is intentional.
- Do not use `((count++))` as a standalone statement under `set -e`; it returns status 1 when the expression evaluates to zero. Use `count=$((count + 1))`.

## Idempotency

Configuration and reconciliation functions must be idempotent:

- Inspect current state before changing it.
- Use supported force/reconcile flags where appropriate.
- Re-running an already-converged operation must succeed without destructive side effects.
- Distinguish fatal failures from explicit non-fatal warnings.

## Workload boundary

Lifecycle scripts own Proxmox, CT, storage, network, generic Compose deployment,
and Compose-derived permission state. They must not contain service names,
service credential schemas, service-specific files, or workload-specific desired
state. In particular, they must never generate, rotate, validate, or repair the
contents of workload raw env files below `_secrets/`.

Generic permission reconciliation may normalize ownership and modes for existing
Compose-discovered files. That does not transfer content ownership to the
lifecycle layer. Keep workload configuration and operator procedures beside the
workload unless a separately designed mechanism explicitly owns them.

## Interactive CT selection

Shared selectors in `commonCT.sh` are:

- `select_ct_interactive_single` — `whiptail --menu` for one CT.
- `select_ct_interactive_multi` — `whiptail --checklist` for batch operations.

Use multi-select only when no target or target-specific options were supplied. Options such as `--gpu`, `--size`, or `--monitor` imply single selection unless a script explicitly defines safe per-CT batch semantics.

Always add `--separate-output` to `whiptail` checklists and parse one selected value per line.

## Status-bar progress

Lifecycle scripts use `status_bar_init`, `status_update`, `status_progress`, and `status_bar_cleanup` from `commonCT.sh`.

When adding or removing a numbered operation:

1. Update the total step count.
2. Add or remove the matching `status_progress` call.
3. Verify numbering is sequential for every branch.

## Shared CT state

Common globals include:

- `CTID` — active CT ID.
- `CT_HOSTNAME` — active CT hostname.
- `CT_LIST` — discovered CT IDs.
- `CT_MAP` — CTID-to-hostname map.
- `CT_NODE` — CTID-to-owner-node map.
- `SELECTED_CTS` — multi-select result.

Prefer existing owner-node-safe wrappers from `commonCT.sh` over direct local `pct` assumptions.
