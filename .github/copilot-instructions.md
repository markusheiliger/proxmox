# Copilot Instructions for Proxmox Scripts

## Project Overview

Bash scripts for managing Proxmox LXC containers with Docker. Scripts use `set -euo pipefail` for strict error handling.

## Critical: Arithmetic with `set -e`

### Problem
When `set -e` is enabled, `((expr))` returns exit code 1 if the result is 0 (falsy), causing immediate script termination.

```bash
# BAD - exits script when count=0 because ((0)) returns exit code 1
local count=0
((count++))  # Script exits here!

# BAD - same issue
local current=0
((current++))  # Script exits here!
```

### Solution
Use `$((expr))` assignment syntax instead:

```bash
# GOOD - always succeeds
local count=0
count=$((count + 1))

# GOOD - alternative with || true (less clean)
((count++)) || true
```

### Safe Uses
`for` loops with arithmetic are safe:
```bash
# SAFE - part of loop syntax, not standalone statement
for ((i=1; i<=timeout; i++)); do
  ...
done
```

## Script Structure

- `commonCT.sh` - Shared idempotent functions, sourced by other scripts
- `createCT.sh` - Create new LXC containers
- `refreshCT.sh` - Update existing containers with latest config
- `deleteCT.sh` - Remove containers
- `monitorCT.sh` - Stream container logs

## Configuration

- `commonCT.json` - Contains secrets (gitignored)
- Required sections: `step_ca`, `registries`, `sizes`, `newt`

## Whiptail UI

Use `--separate-output` for checklists to get one item per line:

```bash
# Multi-select with --separate-output for easy parsing
selections=$(whiptail --title "Title" \
  --separate-output \
  --checklist "Select items:" \
  "$height" "$width" "$list_height" \
  "${checklist_args[@]}" \
  3>&1 1>&2 2>&3)

# Parse line by line
while IFS= read -r line; do
  [[ -n "$line" ]] && SELECTED_ITEMS+=("$line")
done <<< "$selections"
```

## Idempotent Functions

All configuration functions must be idempotent:
- Check if already configured before making changes
- Use `--force` flags where available
- Return success even if no changes needed

## Global Variables

Scripts share these globals:
- `CTID` - Current container ID
- `CT_HOSTNAME` - Current container hostname
- `CT_LIST` - Array of all container IDs
- `CT_MAP` - Associative array: CTID -> hostname
- `SELECTED_CTS` - Array from multi-select (refreshCT.sh)
