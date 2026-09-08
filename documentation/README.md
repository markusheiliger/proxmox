# Documentation

This directory contains cross-cutting architecture, policy, and troubleshooting
for the Proxmox LXC lifecycle scripts. Command syntax and script-specific
recovery live beside each top-level script in `[scriptname].md`.

## Guides

- [Architecture](architecture.md): system boundaries, lifecycle, and reliability
  model.
- [Configuration](configuration.md): `commonCT.json`, per-CT environment, and
  sizing.
- [Storage and permissions](storage-and-permissions.md): mount layout, ownership,
  secrets, and backup staging.
- [Container image versioning](container-image-versioning.md): readable release
  tags, registry evidence, rollback, and the controlled Caddy exception.
- [Networking and authentication](networking-and-authentication.md): VLANs, DNS,
  Caddy, Authentik, and telemetry identity.
- [Testing](testing.md): suite ownership, commands, and test design.
- [Troubleshooting](troubleshooting.md): cross-cutting diagnosis and recovery.
- [Backup design](backup-design.md): consistency, immutable generations,
  retention, state, and failure handling.

## Lifecycle guides

- [Create](../createCT.md)
- [Refresh](../refreshCT.md)
- [Delete](../deleteCT.md)
- [Move](../moveCT.md)
- [Rename](../renameCT.md)
- [Upgrade](../upgradeCT.md)
- [CT backup](../backupCT.md)
- [VM backup](../backupVM.md)
- [Monitor](../monitorCT.md)
- [Forward authentication](../forwardAuthCT.md)
- [Forward DNS](../forwardDNSCT.md)

## Folder guides

- [Backup helpers](../backup/README.md)
- [Compose templates](../compose/README.md)
- [Configure libraries](../configure/README.md)
- [Custom container images](../containers/README.md)
- [Tests](../tests/README.md)
