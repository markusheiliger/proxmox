---
applyTo: "**/{docker-compose.yaml,compose-profile.sh,resolve-compose-profile.py,select-compose-profile.sh,commonCT.sh,createCT.sh,refreshCT.sh,moveCT.sh}"
description: "Use when implementing or modifying hardware-aware CT Compose profiles, GPU/Vulkan device selection, or lifecycle handling of profile variants."
---

# Hardware-aware Compose profiles

- `commonCT.json` is the only capability-policy source. It defines ordered CT-local tests and one default for each group.
- Do not add `x-profiles` to Compose. Workloads opt into a managed group only through normal service `profiles:` entries named `<group>-<name>`, such as `gpu-drm_intel` and `gpu-none`.
- Lifecycle evaluates only groups declared by the authoritative owner-local Compose file, persists one `profile-<group>-<name>` Proxmox tag for each relevant group, and IMDS exposes the sanitized `<group>-<name>` value. Irrelevant groups have no managed tag, IMDS winner, predicate execution, or device passthrough.
- Every managed winner must be supported by at least one workload service. Unsupported winners fail closed; workloads do not silently substitute another profile.
- Compose owns all devices, capabilities, environment, topology, initializers, and fallback service behavior. Profile variants may share a network alias to preserve a stable endpoint.
- Use stable in-CT device paths; never persist `COMPOSE_PROFILES`, node identity, or discovered device indices in `.env`.
- Lifecycle scripts must use `ct_compose()`. Selected operations consume IMDS; all-profile operations validate declarations without requiring IMDS.
- `_config/select-compose-profile.sh` and its `profile|device` output are legacy compatibility only. Never combine a selector with managed group-qualified service profiles.
- GPU profiles describe exposed kernel interfaces and vendors, not userspace API readiness. Central predicates use `/dev` and `/sys`, never workload packages such as `nvidia-smi`, `vulkaninfo`, CUDA, Vulkan, or VA-API libraries.
- Full architecture is documented in `documentation/hardware-compose-profiles.md`.
