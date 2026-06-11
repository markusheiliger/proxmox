# Copilot Instructions for Proxmox Scripts

## Project Overview

Bash scripts for managing Proxmox LXC containers with Docker. Scripts use `set -euo pipefail` for strict error handling.

## Critical: Strict Mode (`set -euo pipefail`)

All generated bash code MUST handle the strict mode requirements:

### `set -e` - Exit on Error

Commands that may fail must be handled explicitly:

```bash
# BAD - exits script if grep finds nothing
result=$(grep "pattern" file.txt)

# GOOD - handle failure explicitly
result=$(grep "pattern" file.txt || true)

# GOOD - check return code
if grep -q "pattern" file.txt; then
  # found
fi
```

### `set -u` - Unset Variables are Errors

All variables must be defined or have defaults:

```bash
# BAD - exits if $1 not provided
local value="$1"

# GOOD - provide default
local value="${1:-}"
local value="${1:-default}"
```

### `set -o pipefail` - Pipeline Failures

Any command in a pipeline can cause exit:

```bash
# BAD - exits if getent returns non-zero (not found)
local ip=$(getent hosts example.com | awk '{print $1}')

# GOOD - suppress failure
local ip=$(getent hosts example.com 2>/dev/null | awk '{print $1}' || true)
```

### Functions Returning Non-Zero

Functions that fail will exit the entire script:

```bash
# BAD - if bootstrap fails, script exits
pct exec "${CTID}" -- step ca bootstrap --install --force

# GOOD - catch failure, warn, continue
if ! pct exec "${CTID}" -- step ca bootstrap --install --force 2>&1; then
  echo "Warning: bootstrap failed"
  return 0  # Non-fatal, continue
fi
```

### Arithmetic with `set -e`

`((expr))` returns exit code 1 if result is 0, causing script termination:

```bash
# BAD - exits script when count=0 because ((0)) returns exit code 1
local count=0
((count++))  # Script exits here!

# GOOD - always succeeds
local count=0
count=$((count + 1))
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

## Docker Volume Mounts

**IMPORTANT**: Each CT instance has bind mounts that point to hostname-specific folders:
- `/mnt/docker` in CT → `/mnt/docker/[hostname]` on host
- `/mnt/docker-data` in CT → `/mnt/docker-data/[hostname]` on host

**This means docker-compose volume paths should NOT include the hostname:**

```yaml
# WRONG - hostname is redundant, creates nested folder
volumes:
  - /mnt/docker-data/oidc.thesaints.home/postgresql:/var/lib/postgresql/data

# CORRECT - CT already resolves to hostname folder
volumes:
  - /mnt/docker-data/postgresql:/var/lib/postgresql/data
```

### Storage Characteristics

Choose the appropriate mount based on service requirements:

| Mount | Storage | Best For |
|-------|---------|----------|
| `/mnt/docker` | **SSD** | Low volume, fast IO (configs, small DBs, app state) |
| `/mnt/docker-data` | **HDD** | Large volume, slow IO (media, recordings, backups, large DBs) |

**Always add a comment explaining the mount choice:**

```yaml
volumes:
  # SSD: fast IO for database operations
  - /mnt/docker/postgresql:/var/lib/postgresql/data
  # HDD: large media storage
  - /mnt/docker-data/media:/media
  # HDD: video recordings (large files)
  - /mnt/docker-data/recordings:/recordings
```

### Hard Rules

- **Caddy**: Always uses `/mnt/docker/caddy` - certificates and config require fast IO

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

## Interactive Selection Patterns

Scripts support two selection modes for containers:

- `select_ct_interactive_single` - whiptail `--menu` for single selection
- `select_ct_interactive_multi` - whiptail `--checklist` for multi-selection

**When to use which:**
- **Multi-select**: Only when NO arguments/options provided (batch operations)
- **Single-select**: When options like `--gpu`, `--size`, `--monitor` are given

```bash
# Pattern: track if options were provided
local has_options=false

case "$1" in
  --gpu)
    GPU_PASSTHROUGH=true
    has_options=true
    ;;
esac

# Select based on context
if [[ -z "$ct_arg" ]]; then
  if [[ "$has_options" == "true" ]]; then
    select_ct_interactive_single "action" || exit 1
  else
    select_ct_interactive_multi "action" || exit 1
  fi
fi
```

**Rationale**: Options like `--monitor` only make sense for single CTs. Multi-select is for bulk operations with default settings.

## Status Bar Progress

Scripts use ANSI escape codes to display a persistent status bar at the bottom of the terminal while output scrolls above.

**Functions (in commonCT.sh):**
- `status_bar_init()` - Initialize status bar, reserve bottom line
- `status_update "message"` - Update status text
- `status_progress current total "message"` - Show `[N/total] X% - message`
- `status_bar_cleanup()` - Restore normal terminal (also in EXIT trap)

**Usage pattern:**
```bash
status_bar_init

status_progress 1 5 "Step one..."
do_step_one

status_progress 2 5 "Step two..."
do_step_two

status_bar_cleanup
```

**IMPORTANT: When adding new steps to a script, always:**
1. Update `total_steps` count in scripts using numbered progress
2. Add corresponding `status_progress` call before the new operation
3. Verify step numbers are sequential and total is correct

This ensures the progress percentage remains accurate.

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
