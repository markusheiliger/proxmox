---
applyTo: "**/{docker-compose.yaml,docker-compose.md}"
description: "Use when creating or editing CT Docker Compose stacks or their companion documentation under /mnt/docker: documentation placement, mount paths, storage rationale, permissions, deterministic container names, telemetry identity, initialization services, networking, and raw secrets."
---

# CT Docker Compose authoring

Each `/mnt/docker/<hostname>/docker-compose.yaml` defines a stack running inside one Proxmox LXC CT.

## Workload-local documentation

When a workload needs documentation for non-obvious Compose intent, architecture,
profiles or devices, storage, initialization, exposure, migration, acceptance,
rollback, or troubleshooting, use exactly `docker-compose.md` directly beside
that workload's `docker-compose.yaml`.

The companion is optional; do not create an empty file when the Compose stack is
self-explanatory. Keep repository-wide architecture under
`/root/scripts/documentation`. Generated `_config/shared/README.md` mirrors and
unrelated service documentation are outside this convention and must not be
renamed or edited as Compose companions.

## Image versioning

- Use an explicit, readable stable version tag for third-party images, such as `postgres:16.10-alpine` or `smallstep/step-ca:0.30.2`.
- Review release notes, compatibility, migrations, registry availability, and required platforms before selecting a tag. A newer tag is not automatically safe.
- Do not use floating tags such as `latest`, `stable`, an unversioned variant such as `alpine`, or an unbounded major tag for third-party deployments.
- Do not append `@sha256:` digests to Compose image references by default. Record resolved digests for verification, drift detection, provenance, and rollback identification.
- Services that intentionally share one artifact must use the same exact version tag.
- The repository-controlled `ghcr.io/markusheiliger/caddy-stepca:latest` and `ghcr.io/markusheiliger/caddy-dnsimple:latest` images are the sole floating-tag exception, as described under Networking.

## CT-local volume paths

The host mounts `/mnt/docker/<hostname>` at `/mnt/docker` in the CT and `/mnt/docker-data/<hostname>` at `/mnt/docker-data`. Compose executes inside the CT, so bind sources must never repeat the hostname.

- Good: `/mnt/docker/caddy/data:/data`
- Good: `/mnt/docker-data/seafile:/shared`
- Bad: `/mnt/docker/seafile.thesaints.de/caddy/data:/data`
- Bad: `/mnt/docker-data/seafile.thesaints.de/seafile:/shared`

Namespace writable sources by the owning Compose service. Use the reserved `shared` subfolder only when multiple services genuinely write the same data.

Choose storage deliberately and add a concise rationale comment:

- `/mnt/docker` is SSD-backed and suits Caddy state, configuration, small databases, and latency-sensitive low-volume state.
- `/mnt/docker-data` is HDD-backed and suits media, recordings, backups, and large or growing data.
- Caddy always uses `/mnt/docker/caddy`.

## Permission reconciliation

Lifecycle scripts run `reconcile_compose_permissions` before startup.

- Writable binds below `/mnt/docker` and `/mnt/docker-data` are reconciled automatically; read-only binds, named volumes, tmpfs, devices, sockets, and external paths are not mutated.
- Ownership resolution order is `permissions.thesaints.user`, Compose `user:`, paired `PUID`/`PGID`, then image `Config.User`.
- Most services need no permission label. Add `permissions.thesaints.user: "UID:GID"` only when the image changes to a runtime identity not declared in Compose or image metadata.
- Use `permissions.thesaints.recursive: "false"` only when the service owns the mount root but existing descendants must not be rewritten.
- Use `permissions.thesaints.skip` only for a verified application-managed exception.
- Shared writable sources are valid only when all writers resolve to the same UID/GID.
- File-backed secrets must live below `/mnt/docker/_secrets`; reconciliation keeps the parent CT-root-only.
- Raw `env_file` sources are read by CT-root Compose before container launch. Reconciliation makes these files CT-root-owned and mode `0400`.
- Top-level Compose secret sources mounted into containers remain mode `0444` unless the runtime user contract proves a stricter mode is compatible.

## Container and telemetry identity

Every service must declare `container_name:`. Conventionally it equals the service name.

Canonical identity is `<hostname>/<container_name>`:

- Loki label: `service_name`.
- Prometheus application/span label: `service`.
- Native trace resource: `OTEL_SERVICE_NAME`.

For native OTLP, the second segment of `OTEL_SERVICE_NAME` must exactly match `container_name`. Legacy dot-form identities are not a current convention.

## Initialization services

An explicit `restart: "no"` marks a mandatory finite initializer consumed by `refreshCT.sh`.

- Use it only for idempotent one-shot setup, never for apps, proxies, databases, workers, telemetry, or manual jobs.
- Exit zero only after the desired state is complete; retry transient prerequisites internally.
- A permission-driven Compose restart may execute it twice during one refresh.
- Use long-form `depends_on` with `condition: service_completed_successfully` when startup ordering matters.
- Use `_config/configure.sh` instead for work requiring the complete post-reboot stack, DNS, or external APIs.

## Networking

Expose services through the CT Caddy proxy and its labels. Internal service communication uses Docker container names. Do not publish internal-only service ports merely for diagnostics.

The Caddy image is mandatory by domain mode:

- Primary/internal domains: `ghcr.io/markusheiliger/caddy-stepca:latest`.
- Public domains: `ghcr.io/markusheiliger/caddy-dnsimple:latest`.

Use these exact `:latest` references. Never substitute official Caddy, another Caddy implementation, a fork, a version tag, or a digest reference. Remediate Caddy vulnerabilities by rebuilding and reviewing the applicable project image, then keep the Compose reference unchanged.

## Secrets containing special characters

Do not interpolate secrets containing `$`, quotes, `#`, or whitespace through Compose `.env`.

Store them in `_secrets/<service>.env` and use raw env files:

```yaml
env_file:
  - path: ./_secrets/<service>.env
    format: raw
```

Write bare `KEY=VALUE` lines. Remove the same key from `environment:` because `environment` overrides `env_file`. When a command reads the container environment at runtime, escape `$` as `$$` to prevent Compose interpolation. The `_secrets` prefix also protects the directory from `refreshCT.sh --reset`.
Lifecycle permission reconciliation requires the `_secrets` parent to be mode `0700` and each raw env file to be CT-root-owned mode `0400`.
