---
name: ct-compose
description: Multi-step workflow to plan, confirm, and implement or remediate a Docker Compose application stack for a Proxmox CT identified by hostname or CTID. Use for new or updated CT workloads, image selection, health/readiness, Caddy/TLS exposure, Authentik authentication, initialization services, secrets, permissions, and storage mapping. Route grouped hardware profile selection to ct-compose-profiles.
---

# Configure CT Compose

Use this skill when the user asks to configure or update a CT application workload.

Before planning, read:

- `.github/instructions/docker-compose.instructions.md`
- `.github/instructions/compose-hardware-profiles.instructions.md` when accelerators or profile variants are relevant.
- `.github/instructions/configure-sh.instructions.md` when post-deploy configuration or Authentik registration is needed.

## Inputs

- `CT`: CT hostname or CTID.
- `IMAGE`: optional explicit application image.
- `WORKLOAD`: optional workload name when no image is supplied.
- `OUTCOME`, `EVIDENCE`, and `ACCEPTANCE_CRITERIA`: optional remediation context supplied by an optimization prompt.

When optimization context is supplied, verify it against the current workload and preserve its outcome rather than treating proposed implementation details as established fact.

## Ownership boundaries

This skill owns ordinary Compose application structure and readiness. Grouped hardware service profiles, accelerator variants, central capability policy, and fallback remediation belong to `ct-compose-profiles`. Full application telemetry reconciliation belongs to `ct-telemetry`; keep ordinary `container_name` and Compose compatibility work here, but split native OTLP, scrape-sidecar, telemetry migration, duplicate-shipping, and telemetry garbage-collection work into that skill.

Host or LXC device exposure, lifecycle-script changes, central Telegraf/Proxmox resource telemetry, and node preparation are outside this skill. Report them as separate prerequisites under their applicable repository instructions rather than editing them as part of a Compose remediation.

## 0. Mandatory plan and confirmation

Always produce an implementation plan and wait for explicit confirmation before editing.

The plan must include:

- Primary and supporting services.
- Image selection and tradeoffs when `IMAGE` is not supplied; ask the user to choose before implementation.
- Caddy exposure and TLS mode.
- Authentication strategy: native OIDC, Caddy forward auth, or a justified no-auth exception.
- A `Storage Mapping` section listing each writable source, data type, owner service, storage class, expected growth, and workload-based rationale.
- A minimal-footprint note per service.
- An `Initialization Services` section describing each one-shot service's completion condition, idempotency, retries, and dependents, or explicitly stating none are needed.
- Every file to create or change.
- `[Instruction-Dependent]` on steps derived from project instructions, with the source named.

## 1. Resolve the CT

Accept hostname or CTID. Resolve identity and the current owner node through cluster resources and numeric `/etc/pve/lxc/<CTID>.conf` entries rather than inventing a local-node `pct` assumption. Host paths such as `/mnt/docker/<hostname>` and `/mnt/docker-data/<hostname>` are node-local and must be inspected on the owner node; inside the CT they remain `/mnt/docker` and `/mnt/docker-data`.

Before editing, verify that the workspace's `/mnt/docker/<hostname>/docker-compose.yaml` is the owner node's workload tree. If the CT is owned by another node and its tree is not available in the current workspace, stop and ask the user to open that owner node's workspace. Never edit a same-named local directory as a substitute and never modify remote files through shell or SSH commands.

## 2. Select and configure services

If an image is supplied, use it. Otherwise curate stable, maintained open-source/community candidates, explain tradeoffs, recommend a default, and ask the user to choose.

For third-party images, select an explicit readable stable version tag after reviewing compatibility, migrations, registry availability, and required platforms. Do not deploy floating tags such as `latest`, `stable`, an unversioned variant, or an unbounded major tag. Keep resolved digests as verification and rollback evidence rather than appending them to Compose references. The mandatory repository-controlled Caddy images are the sole `:latest` exception.

Preserve existing ordering, comments, label style, restart policies, and composition patterns. Add databases, caches, workers, or queues only when required by the application.

### Minimal footprint

The fleet serves single-digit user counts:

- One replica per service; no unnecessary HA copies.
- Keep required upstream components separate even when they share an image.
- Reduce web/background concurrency to the smallest supported correct value.
- Avoid optional sidecars/exporters unless required.
- Prefer supported slim/Alpine variants.

### Volumes and permissions

Follow `docker-compose.instructions.md`:

- Writable paths are namespaced by their writing service under `/mnt/docker/<service>` or `/mnt/docker-data/<service>`.
- Use `shared` only for data written by multiple services.
- Read-only consumers use the writer's path.
- Single-file binds remain under the owner's subfolder.
- Never include the CT hostname in a Compose source path and never mount a bare mount root.
- Add permission metadata only when automatic identity discovery cannot determine the runtime UID/GID.

### Secrets

Put service secrets in `_secrets/<service>.env` and reference them with `env_file: { path, format: raw }`. Commit placeholders when a generated secret file must exist before first startup. Remove duplicate keys from `environment:` because it overrides `env_file`. Escape runtime `$` as `$$` inside Compose commands.

### Container identity

Every service declares `container_name:`. For native OTLP, `OTEL_SERVICE_NAME` must be `<hostname>/<container_name>`.

### Initialization services

Use `restart: "no"` only for finite, mandatory, idempotent initialization. Use long-form `depends_on` with `condition: service_completed_successfully` when ordering matters. Use `_config/configure.sh` instead for post-reboot work requiring the complete stack, DNS, or external APIs.

## 3. Exposure and TLS

Expose web workloads through Caddy. Determine domain mode from hostname and `/root/scripts/commonCT.json`:

- Primary/internal domain: use exactly `ghcr.io/markusheiliger/caddy-stepca:latest`.
- Public domain: use exactly `ghcr.io/markusheiliger/caddy-dnsimple:latest`.

These project images and their mutable `:latest` references are mandatory. Never propose or implement official Caddy, another Caddy implementation, a fork, a version tag, or a digest deployment reference, even when the user requests general image pinning. For a Caddy security or version update, update and review the applicable project image build, publish it as `:latest`, verify the fixed runtime version, and leave the Compose image reference unchanged.

If the workload has no suitable web UI, propose `nicolargo/glances` as a fallback UI and expose it through Caddy/TLS. Glances never requires authentication: do not recommend or configure OIDC, forward auth, or another authentication layer for it. Do not publish port 61208 directly unless a separately documented consumer requires it. Do not add Glances silently.

## 4. Authentication

Classify the primary web workload as exactly one of:

1. Native OIDC against Authentik, preferred when supported.
2. Caddy forward auth when the app cannot authenticate itself.
3. A justified public/no-auth exception.

Glances is exempt from this classification and always uses the no-authentication policy defined above.

### Native OIDC

- Derive endpoints from `AUTH_HOSTNAME` and use the app's documented callback path.
- Keep non-secret settings in `environment:` and generated credentials in `_secrets/<service>-oidc.env` using raw format.
- Implement idempotent self-registration in `_config/configure.sh` by following `configure-sh.instructions.md` and calling shared helpers, especially `ak_oidc_ensure_app` and `oidc_apply_credentials`.
- Load `/mnt/docker/.env`; do not create `_config/configure.env`.
- Use `AUTH_AUTHORIZATION_FLOW` and `AUTH_INVALIDATION_FLOW` from that environment.
- Do not enable forward auth for a native-OIDC service.

### Forward-auth fallback

Forward auth is managed only through `forwardAuthCT.sh`. The protected service must use one `caddy.route` block with numeric bands:

- `0_`: injector-managed Authentik outpost callback proxy.
- `1_`–`49_`: author-owned unauthenticated bypasses.
- `50_`: injector-managed `forward_auth`.
- `51_`–`98_`: author-owned authenticated auxiliary routes.
- `99_`: application catch-all reverse proxy.

Do not hand-edit managed bands. Show the post-deploy command `./forwardAuthCT.sh <hostname>`; show `--remove` when documenting removal.

## 5. Validation and report

After confirmed edits:

- Validate YAML and rendered Compose configuration.
- Verify every service has `container_name`.
- Verify bind sources, raw secrets, and permission metadata follow project rules.
- Verify intended initializers render with restart policy exactly `no`, no long-running service does, and required dependencies use `service_completed_successfully`.
- Summarize exact changes and provide `Operator Notes`: required services, Caddy choice, authentication, UI endpoint, initialization, and storage decisions.

## Guardrails

- Never edit before explicit confirmation.
- Never silently enable authentication.
- Never replace either mandatory project Caddy image or its exact `:latest` deployment reference.
- Never place secrets in interpolated `.env` values.
- Never remove unrelated services.
- Prefer minimal diffs and preserve existing style.
