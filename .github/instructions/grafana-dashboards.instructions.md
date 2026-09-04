---
applyTo: "**/grafana/provisioning/**"
description: "Use when editing provisioned Grafana dashboards or datasources: template-variable escaping, datasource UID replacement, reload semantics, telemetry labels, Tempo, and source verification."
---

# Grafana provisioning

## Template variables in label matchers

`${var:regex}` escapes dots as `\.`. Inside a double-quoted PromQL, LogQL, or TraceQL matcher this becomes an invalid Go escape and can return HTTP 400. For multi-value matchers use `(${var:pipe})`, with explicit parentheses, and set `allValue` to `.*`.

- Bad: `service=~"${scope:regex}(/.*)?"`
- Good: `service=~"(${scope:pipe})(/.*)?"`

## Datasource YAML

Never add or change `uid:` on an already provisioned datasource in place. Put the old datasource in `deleteDatasources:` above `datasources:`, then recreate it.

## Reload semantics

- Dashboard JSON is polled according to `updateIntervalSeconds`; no restart is needed.
- Dashboard-provider and datasource YAML are loaded at startup and require a Grafana restart.
- Collector and Tempo configuration-file changes require an explicit restart of that service; `compose up -d` does not restart a container whose Compose spec is unchanged.

## File layout

Keep dashboard JSON in a subfolder separate from provider YAML, for example `provisioning/dashboards/json-apps/*.json`. Otherwise the provider may try to load its own YAML as a dashboard.

## Telemetry labels

- Span metrics use `service`.
- Loki logs use `service_name`.
- Telegraf infrastructure metrics use `job`.
- Canonical values use `<host>/<container>`.

## Tempo

Pin Tempo to a real release tag; do not use `latest`. Its data directory must be owned by UID 10001.

## Verification

Verify dashboards in the real browser. `POST /api/ds/query` may return zero frames for valid Infinity queries. To prove a metric, series, or label exists, query Prometheus, Loki, or Tempo directly using the `internal-api-debug` skill. Verify telemetry sidecar output by `__name__`, not a raw `job` value.
