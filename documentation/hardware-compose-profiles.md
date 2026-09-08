# Hardware-aware Compose profiles

Portable CT workloads may select one hardware backend at runtime without storing node-specific device names in `.env`.

## Contract

A stack opts in by providing executable `/mnt/docker/_config/select-compose-profile.sh`. It must be POSIX `sh` and print exactly one line:

```text
<profile>|<device>
```

Supported profiles are:

- `no-discrete-gpu|` — CPU fallback.
- `vulkan|/dev/dri/renderD<N>` — Vulkan through one accessible DRM render node.
- `cuda` is reserved for future end-to-end NVIDIA Container Toolkit support.

The selector must discover hardware on every invocation. It must not persist `COMPOSE_PROFILES`, a render-node index, or node identity. NVIDIA Vulkan selectors verify PCI vendor `0x10de` through `/sys/class/drm/renderD<N>/device/vendor`; the mere presence of `/dev/dri` is insufficient because it may expose an Intel iGPU.

## Compose integration

The shared `configure/compose-profile.sh` wrapper validates selector output, exports process-local `COMPOSE_PROFILES` and `VULKAN_DEVICE`, and executes Docker Compose. If valid Newt credentials exist, it combines the independent `published` profile with the selected hardware profile.

Profile variants use workload-specific service and container names, but may share a network alias for a stable internal endpoint. Exactly one hardware variant is active. Pull and down operations intentionally enable every profile; validation, startup, status, initializer discovery, permission rendering, and post-deploy configuration select current hardware.

Lifecycle scripts synchronize the wrapper before Compose use. Selector-enabled Alpine CTs also receive an OpenRC service that reselects hardware and reconciles Compose after Docker starts. CTs without a selector retain direct Compose behavior.

## CPU-only stacks

A stack that never uses an accelerator may include an empty marker at
`/mnt/docker/_config/disable-managed-gpu`. Lifecycle operations check the
authoritative workload tree on the CT owner node and remove the managed DRM
cgroup allow and `/dev/dri` bind entries when the marker exists.

The marker moves with the stack's mp0 storage and must remain empty. It must not
contain a node name, PCI identity, or render-device path. Without the marker,
the existing node-capability behavior remains unchanged. Certificate authority
CTs retain their existing implicit GPU-disable rule.

## Moves and fallback

Before moving a running selector-enabled CT, all profile variants are brought down before the final data sync. The destination selects its local profile only after migration and mount restoration. Rollback reselects on the source. A CT moved from an NVIDIA node to a node without a supported discrete GPU therefore starts the `no-discrete-gpu` variant automatically.

Vulkan via the normal DRM render node permits GPU sharing between CTs, but does not provide hard VRAM or compute quotas. The RTX 3060 does not support MIG.
