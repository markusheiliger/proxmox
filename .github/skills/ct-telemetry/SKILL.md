---
name: ct-telemetry
description: Idempotent workflow to add, fix, refresh, verify, migrate, or remove application telemetry for a CT Docker Compose stack. Prefers native OpenTelemetry/OTLP, falls back to one Prometheus-scraping collector sidecar, prevents double shipping, and garbage-collects unused wiring after a mandatory plan-and-confirm gate.
---

# Reconcile CT telemetry

Use for application metrics/traces in a CT stack. This is one idempotent reconcile, not an add/remove toggle: every run recomputes the correct state for every service and may add, update, migrate, remove, or leave wiring unchanged.

Before planning, read `.github/instructions/docker-compose.instructions.md`. Read `.github/instructions/compose-hardware-profiles.instructions.md` if profile variants are involved.

This skill edits only after confirmation and never deploys. The user applies changes with `refreshCT.sh <hostname>`.

## Inputs and ownership

- `CT`: CT hostname or CTID.
- `SERVICES`: optional services highlighted by the request; always inspect and reconcile the complete stack telemetry state.
- `EVIDENCE` and `ACCEPTANCE_CRITERIA`: optional context supplied by an optimization prompt; verify it against current state before planning.

This skill owns application metrics and traces, native OTLP, Caddy tracing, Prometheus scrape sidecars, telemetry identity, duplicate-shipping prevention, migration, and stale-wiring garbage collection. It does not own image pinning, general health checks, authentication, permissions, storage, LXC/device hardening, or other non-telemetry Compose remediation; route those concerns to `ct-compose` as separate work.

Central Telegraf, Docker fluentd logging, syslog, Proxmox RRD, and CT resource-series availability are infrastructure telemetry and remain outside this skill. If a request combines either infrastructure telemetry or unrelated Compose hardening with application telemetry, split the work before planning instead of broadening this reconciliation.

## Fleet telemetry model

The central collector host comes from `commonCT.json .telemetry.hostname` and receives:

- OTLP/HTTP on `:4318` through `OTEL_EXPORTER_OTLP_ENDPOINT` and protocol `http/protobuf` for application SDKs.
- OTLP/gRPC on `:4317` through `OTEL_EXPORTER_OTLP_GRPC_ENDPOINT` for Caddy and collector sidecars.

Telegraf, Docker fluentd logging, and syslog are configured centrally by `commonCT.sh`; never modify them here.

Canonical identity is `<hostname>/<container_name>` across Loki `service_name`, Prometheus application label `service`, and native `resource.service.name`. Every Compose service requires deterministic `container_name`.

## Wiring preference

### 1. Native application OTLP

Use when official image/version documentation confirms an OTLP exporter:

```yaml
environment:
  OTEL_EXPORTER_OTLP_ENDPOINT: ${OTEL_EXPORTER_OTLP_ENDPOINT}
  OTEL_EXPORTER_OTLP_PROTOCOL: ${OTEL_EXPORTER_OTLP_PROTOCOL}
  OTEL_SERVICE_NAME: <hostname>/<container_name>
```

### 2. Caddy native tracing

Verify the running image contains the tracing module before adding:

```yaml
environment:
  OTEL_EXPORTER_OTLP_ENDPOINT: ${OTEL_EXPORTER_OTLP_GRPC_ENDPOINT}
  OTEL_EXPORTER_OTLP_PROTOCOL: grpc
  OTEL_EXPORTER_OTLP_INSECURE: ${OTEL_EXPORTER_OTLP_INSECURE}
  OTEL_SERVICE_NAME: <hostname>/caddy
```

Add `caddy.tracing: ""` to reverse-proxied sites. If the module is absent, report the required image rebuild and do not wire tracing.

### 3. Prometheus collector sidecar

Use only when the app exposes Prometheus metrics but not native OTLP. Maintain exactly one service named `telemetry`, with `container_name: telemetry`, no published ports, and a read-only `/mnt/docker/telemetry/config.yaml` mount.

The collector:

- Scrapes each app by Compose container name.
- Sets `service.namespace` to the full CT hostname.
- Uses the scrape `job_name` as `service.name`.
- Copies `<namespace>/<name>` into datapoint attribute `service` so remote-write produces the same label/value as native span metrics.
- Exports OTLP/gRPC through `${OTEL_EXPORTER_OTLP_GRPC_ENDPOINT}`.

Known defaults must be reverified at runtime:

| Image/application | Expected method |
| --- | --- |
| `ghcr.io/markusheiliger/wuns` | native OTLP/HTTP |
| `ghcr.io/markusheiliger/fde-scraper` | native OTLP/HTTP |
| Caddy images | native tracing when module exists |
| CoreDNS | sidecar, `:9153/metrics` |
| Authentik server | sidecar, `:9300/metrics` |
| Frigate | sidecar, `:5000/api/metrics` |
| Glances | sidecar after Prometheus export is enabled |
| Stirling PDF OSS, RustDesk, Homepage, whoami | none unless current docs prove support |
| PostgreSQL/Redis base images | none; dedicated exporters are out of scope |

CoreDNS trace output is Zipkin/Datadog, not OTLP, so it remains a Prometheus-sidecar case.

## Workflow

### 0. Plan and confirmation

Produce a per-service table with current method, target method, and action. Include a `Sidecar` line describing whether it is created, kept, changed, or removed and its final jobs. List every affected file, tag instruction-derived steps, and wait for explicit confirmation.

### 1. Resolve scope

Accept hostname or CTID. Resolve identity and the current owner node through cluster resources and read-only numeric `/etc/pve/lxc/<CTID>.conf` files; never modify pmxcfs. Host paths under `/mnt/docker/<hostname>` are node-local, so inspect the target Compose stack on its owner node rather than assuming the current shell node owns it. CT-local Compose paths remain rooted at `/mnt/docker`.

Before editing, verify that the workspace's `/mnt/docker/<hostname>/docker-compose.yaml` is the owner node's workload tree. If a remote owner's tree is unavailable in the workspace, stop and ask the user to open that owner node's workspace. Never edit a same-named local tree as a substitute or change remote files through shell/SSH commands.

Stop for `ca.*` and the central telemetry host; they are intentionally out of scope.

### 2. Inspect current wiring

Enumerate services/images and detect:

- Native OTLP environment.
- Caddy tracing labels/environment.
- Existing telemetry service and scrape jobs.
- App configuration that enables metrics.

### 3. Classify fresh

For every image/tag, consult current official documentation when possible:

1. Native OTLP supported: native.
2. Otherwise Prometheus endpoint supported: sidecar.
3. Otherwise: none.

Do not trust existing wiring or the defaults table without rechecking version capabilities. Cite documentation for unknown or changed images.

### 4. Reconcile minimally

- Native: normalize required environment and identity; remove stale/duplicate keys and any sidecar job.
- Caddy: add tracing only after module verification.
- Sidecar: enable the application's metrics endpoint, ensure one scrape job, and ensure the collector service/config.
- Sidecar-to-native migration: add native wiring, then remove the scrape job and obsolete metrics enablement.
- None: remove stale OTLP, tracing, and scrape wiring.
- If no scrape jobs remain, remove the telemetry service and delete its config. Never leave an idle sidecar.
- Preserve comments, ordering, and existing formatting.

### 5. Validate and report

Confirm YAML is valid, identities match `container_name`, no service is both native and scraped, and sidecar presence exactly matches whether jobs exist. Report final per-service state, jobs, changed files, and the apply command:

```sh
cd /root/scripts && ./refreshCT.sh <hostname>
```

Suggest post-deploy checks in Tempo and Prometheus. Use the `ct-probe` skill when querying unpublished source APIs.

## Guardrails

- Mandatory plan and explicit confirmation.
- No diff when capabilities and desired state are unchanged.
- Native before sidecar; never double ship.
- One unpublished telemetry sidecar per CT; remove it when empty.
- Follow service-namespaced CT-local volume rules.
- Do not change authentication or unrelated configuration.
- Never deploy from this skill.
