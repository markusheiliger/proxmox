---
name: ct-probe
description: Query or test an UNPUBLISHED internal container HTTP API from the Proxmox host when the service has no published port. Use to probe localhost-only health or admin endpoints, verify Prometheus metrics, Loki labels, Tempo data, debug a datasource, or reproduce a request without guessing a host port. Attaches a throwaway curl container to the target container's network namespace.
---

# Probe an internal container API

Most services in this project are not host-published. They listen only on the CT's internal Docker network. Do not guess a host port. Run a throwaway curl container inside the target container's network namespace, where `localhost` resolves to the target's own ports.

First resolve the CTID and current owner node from cluster resources. Run `pct exec` on that owner node; never assume the Proxmox host receiving the request owns the CT. If the current shell is on another node, route the complete command through SSH to the owner.

## Core technique

```sh
pct exec <CTID> -- docker run --rm --network container:<container_name> \
  curlimages/curl -s 'http://localhost:<port>/<path>'
```

From a different cluster node:

```sh
ssh <owner-node> pct exec <CTID> -- docker run --rm \
  --network container:<container_name> curlimages/curl -s \
  'http://localhost:<port>/<path>'
```

- `--network container:<container_name>` joins the target's network namespace.
- `--rm` removes the diagnostic container.
- Add `-S` to show errors or `-i` for response headers.
- The command runs on the CT's owner node. The agent sandbox cannot execute `pct` or owner-node SSH; present it for the user.

## Common variants

For query strings, use `-G --data-urlencode` so shells and Prometheus syntax are not mangled:

```sh
pct exec <CTID> -- docker run --rm --network container:prometheus \
  curlimages/curl -s -G 'http://localhost:9090/api/v1/series' \
  --data-urlencode 'match[]={__name__=~"traces_spanmetrics_.*"}'
```

- For self-signed TLS, use `https://` and `-k`.
- Add authentication headers when required.
- Pipe to `jq` outside the curl container.
- If the target already contains curl or wget, `docker exec <container_name>` is a valid alternative.

## Frequent targets

| Service | Port | Useful endpoints |
| --- | --- | --- |
| Prometheus | `9090` | `/api/v1/series`, `/api/v1/query`, `/api/v1/label/__name__/values` |
| Loki | `3100` | `/loki/api/v1/labels`, `/loki/api/v1/label/<name>/values`, `/loki/api/v1/query_range` |
| Tempo | `3200` | `/api/search/tags`, `/api/echo` |

## Rules

- Resolve ownership again immediately before presenting a command because a CT may have migrated.
- Never guess a host port.
- Prefer source APIs such as `/api/v1/series` or `/api/v1/label/__name__/values` over dashboard inspection when proving data exists.
- Verify telemetry sidecar output by `__name__`, not a raw `job` label.