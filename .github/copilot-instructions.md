# Copilot Instructions for Proxmox CT Infrastructure

## Scope

This repository manages Proxmox LXC containers and the Docker Compose workloads stored under
`/mnt/docker`. Apply the domain that matches the file being changed:

- `/root/scripts/**` — Proxmox lifecycle and shared Bash tooling.
- `/mnt/docker/<hostname>/**` — one CT's Compose stack and service configuration.
- `/mnt/docker/<hostname>/_config/configure.sh` — POSIX `sh` executed inside that CT.

Focused authoring rules live in `.github/instructions/`:

- `bash-lifecycle-scripts.instructions.md`
- `docker-compose.instructions.md`
- `compose-hardware-profiles.instructions.md`
- `configure-sh.instructions.md`
- `grafana-dashboards.instructions.md`

Relevant skills must load these modules explicitly when cross-workspace `applyTo` discovery is not available.

## Infrastructure topology

Each `/mnt/docker/<hostname>/docker-compose.yaml` defines a self-hosted service stack inside one Proxmox LXC CT. The CT receives two host bind mounts:

| Purpose | Proxmox-host path | Path inside CT |
| --- | --- | --- |
| Compose/config/low-volume state | `/mnt/docker/<hostname>` | `/mnt/docker` |
| Large application data | `/mnt/docker-data/<hostname>` | `/mnt/docker-data` |

The hostname segment exists only on the host. Compose and commands executed in the CT use the fixed CT-local paths without a hostname segment.

## Running commands in CTs

The user has shell access to the Proxmox host; Docker runs inside CTs, not on that host.

- Wrap CT commands with `pct exec <CTID> -- <command>`.
- For directory changes or shell composition, use `pct exec <CTID> -- sh -c '<commands>'`.
- The Compose file inside a CT is `/mnt/docker/docker-compose.yaml`; Compose operations use `cd /mnt/docker && docker compose ...`.
- Never put `/mnt/docker/<hostname>` or `/mnt/docker-data/<hostname>` inside a `pct exec` command.
- The agent terminal sandbox cannot execute `pct` operations. Do not run them from the sandbox; present them for the user when direct host execution is required.

Known CT identity: `seafile.thesaints.de` is CT `2100`.

## Proxmox lifecycle scripts

Lifecycle scripts are strict-mode Bash and source shared behavior from `commonCT.sh`:

- `createCT.sh` — create and provision CTs.
- `refreshCT.sh` — idempotently refresh existing CTs.
- `deleteCT.sh` — remove CTs and optionally their data.
- `moveCT.sh` — migrate CTs and bind data between nodes.
- `renameCT.sh` — rename CTs and derived identity state.
- `upgradeCT.sh` — upgrade Alpine with rollback points.
- `backupCT.sh` — workload-aware cluster backups and restore tests.
- `monitorCT.sh` — stream container logs.
- `forwardAuthCT.sh` — reconcile Caddy forward auth with Authentik.
- `forwardDNSCT.sh` — reconcile secondary-domain split DNS.

Each user-facing lifecycle script has a matching operator guide. Cross-cutting architecture lives under `documentation/`. Follow `bash-lifecycle-scripts.instructions.md` for strict mode, selection, progress, and idempotency.

## Configuration sources

- `/root/scripts/commonCT.json` is the lifecycle configuration source and contains secrets; it is gitignored.
- The per-CT `/mnt/docker/<hostname>/.env` is the source consumed by Compose and CT `configure.sh` scripts.
- Shared POSIX configure helpers live in `/root/scripts/configure/` and are mirrored into CTs at `/mnt/docker/_config/shared/` during refresh. Never edit the mirrored copy.

## Docker service conventions

- Each CT uses Caddy for reverse proxying and automatic TLS through exactly one mandatory project image: primary/internal domains use `ghcr.io/markusheiliger/caddy-stepca:latest`, and public domains use `ghcr.io/markusheiliger/caddy-dnsimple:latest`.
- Do not replace these images with official Caddy, another Caddy implementation, a fork, or a digest/version deployment reference. Security and version updates must rebuild the applicable project image and continue deploying its mandatory `:latest` reference.
- Internal service-to-service communication uses Docker container names.
- Every Compose service has a deterministic `container_name`; telemetry identity is `<hostname>/<container_name>`.
- Compose bind paths use CT-local `/mnt/docker/<service>` or `/mnt/docker-data/<service>` paths, never host-side hostname-qualified paths.
- One-shot initializers use the repository's explicit `restart: "no"` contract; post-reboot API configuration uses `_config/configure.sh`.
- Service secrets that require literal handling use raw files below `_secrets/`, not Compose `.env` interpolation.

Follow `docker-compose.instructions.md` for the complete Compose contract.

## Authentication

Authentik is the central OIDC provider. When a service supports OIDC/OAuth2/SSO, recommend native OpenID Connect against Authentik; do not silently add authentication. Implement only after user confirmation.

- Use product-neutral `AUTH_*` configuration names.
- Keep client credentials in service environment variables delivered through raw secret env files.
- Redirect URIs use `https://<service-hostname>/<callback>`.
- Forward auth is managed exclusively by `forwardAuthCT.sh`; do not duplicate its provider, application, or Caddy-label logic in lifecycle scripts.
- Authentik registration from `_config/configure.sh` must use the shared configure library and its self-healing helpers.

Follow `configure-sh.instructions.md` for the complete configure/OIDC contract.

## Hardware-aware stacks

Portable accelerator stacks select a generic Compose profile at runtime. Do not persist node or device identity in `.env`. Lifecycle operations use `ct_compose()` so profile-aware and ordinary stacks remain compatible. Follow `compose-hardware-profiles.instructions.md` for the full contract.
