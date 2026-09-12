# Hardware-aware Compose profiles

Portable CT workloads use cluster-selected Compose profiles without persisting
node or device identity in workload configuration. Capability policy lives in
`commonCT.json`; workload support is declared with normal Compose service
`profiles:` entries. The obsolete `x-profiles` extension is not used.

## Policy contract

The root `profiles` object in `commonCT.json` is keyed by group. Each group has
one `default` and an ordered `profiles` array. Every candidate contains a name
and non-empty argv tests. Lifecycle runs those tests inside the running target
CT from `/mnt/docker`: all tests must exit 0, and the first matching candidate
wins. If no candidate matches, the configured default wins.

The authoritative owner-local Compose file opts into relevant groups through
ordinary service profiles. Lifecycle evaluates only those groups and persists
exactly one `profile-<group>-<name>` Proxmox tag per relevant group. IMDS
removes only the `profile-` prefix, so `profile-gpu-drm_intel` is exposed as
`gpu-drm_intel` in `/mnt/pve-imds/profiles.json`. If a group is removed from
Compose, lifecycle removes its stale tag and managed device passthrough.

GPU winners describe exposed kernel interfaces and vendors. Their tests use
only `/dev` and `/sys`; they do not assert that CUDA, Vulkan, VA-API, or an
application backend works inside a workload image.

## Compose contract

Compose files declare only supported sanitized values:

```yaml
services:
  app-intel:
    image: example.invalid/app:1.0
    profiles: [gpu-drm_intel]
    devices:
      - /dev/dri:/dev/dri
    networks:
      default:
        aliases: [app]

  app-cpu:
    image: example.invalid/app:1.0
    profiles: [gpu-nvidia_compute, gpu-drm_nvidia, gpu-drm_amd, gpu-none]
    networks:
      default:
        aliases: [app]
```

Managed names use `<group>-<name>`, with lowercase alphanumeric or underscore
components. `configure/resolve-compose-profile.py` discovers groups from those
service profiles, reads IMDS, and requires exactly one supported winner for
each declared group. An unsupported winner fails closed. Separate groups are
combined in `COMPOSE_PROFILES`.

Compose remains responsible for service topology, devices, capabilities,
environment, initialization, and stable aliases. It does not execute
capability tests or choose a fallback. Workloads must implement the central
default explicitly when they declare that group.

## Lifecycle behavior

Create and refresh parse relevant groups from the owner-local Compose file,
expose only their lifecycle-managed devices, start the CT, evaluate central
policy, reconcile profile tags, and then deploy Compose. Boot consumes the
persisted IMDS winners. Move carries the relevant group set in transaction
state, defers destination evaluation until the CT is running on the target,
and restores source device configuration during rollback.

Selected operations use `ct_compose()` and consume IMDS. All-profile operations
validate service declarations without requiring IMDS. A profile switch uses
`up -d --remove-orphans` so services belonging only to the previous winner are
removed while stable aliases remain available.

## Legacy selector

`_config/select-compose-profile.sh` remains legacy compatibility only. A
workload must not combine it with managed group-qualified service profiles.
CPU-only stacks declare no managed GPU profiles and therefore receive no GPU
tag, IMDS winner, predicate execution, or lifecycle-managed GPU passthrough.