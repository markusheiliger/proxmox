# Compose Templates

This directory contains domain-specific fallback Compose files used when a CT
does not already have `/mnt/docker/<hostname>/docker-compose.yaml`.

- `thesaints.de.yaml`: public-domain fallback Caddy stack.
- `thesaints.home.yaml`: private-domain fallback Caddy stack.

Lifecycle scripts copy the relevant template into the CT's host-side compose
directory and then operate on the per-CT copy. Templates must follow repository
rules for explicit `container_name`, Caddy storage paths, CT-local bind sources,
and canonical telemetry identity.

## Documentation

- [Create guide](../createCT.md)
- [Architecture](../documentation/architecture.md)
- [Storage and permissions](../documentation/storage-and-permissions.md)
- [Networking and authentication](../documentation/networking-and-authentication.md)
