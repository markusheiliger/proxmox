---
name: ct-compose-profiles
description: "Plan, confirm, implement, or remediate portable grouped service profiles for a Proxmox CT Compose workload. Use for accelerator variants, central capability policy, CPU fallback, profile selection, or migration from select-compose-profile.sh."
---

# Configure CT Compose profiles

Use this skill for a single CT workload that needs portable runtime-selected Compose variants.

Before planning, read:

- `.github/instructions/docker-compose.instructions.md`
- `.github/instructions/compose-hardware-profiles.instructions.md`
- `documentation/hardware-compose-profiles.md`

## Plan and confirmation

Always inspect the current owner-local workload, produce an implementation plan, and wait for explicit confirmation before editing. The plan must identify each independent group, central policy behavior, defaults, stable service endpoints, Compose-owned effects, lifecycle prerequisites, files changed, tests, deployment commands, and rollback.

Resolve the CT and owner node through cluster resources. Edit only the owner node's workspace tree. Never use a same-named local directory as a substitute for an unavailable remote workload.

## Implementation

- Never add `x-profiles`. Declare supported `<group>-<name>` values directly on services with normal Compose `profiles:`.
- Treat those declarations as the workload opt-in for that managed group. Lifecycle must not evaluate, tag, publish, or expose devices for groups absent from the authoritative Compose file.
- A workload that opts into a group must declare every winner configured centrally; unsupported winners fail closed.
- Keep ordered tests and the group default only in `commonCT.json`; do not duplicate policy in a workload.
- Keep devices, capabilities, environment, topology, and application configuration in Compose.
- Keep profile endpoints stable with aliases where variants replace one another.
- Do not persist selection, node identity, or discovered device indices.
- Do not combine managed group-qualified service profiles with `_config/select-compose-profile.sh`.
- Keep central hardware predicates package-free. They describe exposed `/dev` and `/sys` interfaces, not CUDA, Vulkan, VA-API, or application readiness.

Migration from a legacy selector is complete only when equivalent accelerated and fallback behavior works through stable in-CT paths. If the legacy selector's output is needed as a dynamic Compose value, stop and report that the workload is not yet migratable under the predicate-only contract.

## Validation and deployment

Before deployment, validate source structure with `configure/resolve-compose-profile.py --validate`, render every supported profile, and test success, unsupported-winner failure, and default paths. Prove that switching a group winner with `up -d --remove-orphans` removes the previous variant while preserving stable endpoints.

After confirmation, use `testCT.sh <hostname>` and `refreshCT.sh <hostname>` through the repository lifecycle. Verify the selected profiles after refresh and reboot. Do not directly run Docker Compose as a substitute for lifecycle deployment.

## Guardrails

- Never edit or deploy before explicit confirmation.
- Never invent generic hardware names or requirement output bindings.
- Never add JSON manifests, schemas, capability catalogs, or persisted selection state.
- Never remove a working fallback until its replacement has been tested.
- Keep NVR, AI, and other workload migrations separate unless the user explicitly scopes them together.