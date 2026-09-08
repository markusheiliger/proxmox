---
applyTo: "**/{docker-compose.yaml,compose-profile.sh,select-compose-profile.sh,commonCT.sh,createCT.sh,refreshCT.sh,moveCT.sh}"
description: "Use when implementing or modifying hardware-aware CT Compose profiles, GPU/Vulkan device selection, or lifecycle handling of profile variants."
---

# Hardware-aware Compose profiles

- Portable accelerator stacks use generic profiles `no-discrete-gpu` and `vulkan`; `cuda` is reserved for future end-to-end support.
- Opt in with executable `/mnt/docker/_config/select-compose-profile.sh`. It must print exactly `profile|device` and rediscover hardware inside the CT on every operation and boot.
- Never persist `COMPOSE_PROFILES`, node identity, or `renderD<N>` in `.env`.
- NVIDIA Vulkan selection must verify PCI vendor `0x10de` through sysfs; `/dev/dri` alone may expose only an Intel iGPU.
- Exactly one hardware profile runs. Pull and down operations may cover all variants; runtime startup selects one variant and may combine the independent `published` profile.
- Profile variants may share a Docker network alias to preserve a stable internal endpoint.
- Lifecycle scripts must use `ct_compose()` so CTs with and without selectors remain compatible.
- CPU-only stacks may include an empty `/mnt/docker/_config/disable-managed-gpu` marker. Lifecycle operations resolve it from the authoritative owner-node workload tree and remove managed DRM passthrough; the marker must not contain node or device identity.
- Full architecture is documented in `documentation/hardware-compose-profiles.md`.
