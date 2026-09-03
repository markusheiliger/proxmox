# Configuration

`commonCT.json` is the cluster-level configuration source used by the lifecycle
scripts. It is intentionally ignored by Git because it contains credentials and
environment-specific values.

## Data flow

```mermaid
flowchart LR
    JSON[commonCT.json] --> Getters[commonCT.sh getters]
    Getters --> Script[Lifecycle scripts]
    Script --> Env[/mnt/docker/hostname/.env]
    Env --> Compose[Docker Compose]
    Env --> Configure[_config/configure.sh]
```

## Major sections

The configuration currently covers these concerns:

- `domains`: supported public and private domain suffixes.
- `sizes`: named CPU and memory allocations.
- `ssl`: certificate issuer settings and domain-specific policy.
- `registries`: container registry credentials.
- `newt`: connectivity settings consumed by relevant workloads.
- `udmpro`: network controller integration.
- `authentik`: authentication host, API access, and flow slugs.
- `telemetry`: central telemetry endpoints and identity settings.
- `splitdns`: split-DNS service and domain policy.
- `backup`: storage, staging, retention, and snapshot policy.

Use the `config_get_*` and `config_*_configured` functions in `commonCT.sh`
instead of parsing the file independently. Validation functions fail before
mutation when required values are absent or malformed.

## Container environment

Lifecycle scripts merge derived values into each CT's `.env`. Product-agnostic
names are used for shared infrastructure, including `AUTH_HOSTNAME`,
`AUTH_API_TOKEN`, `AUTH_AUTHORIZATION_FLOW`, and `AUTH_INVALIDATION_FLOW`.
Upstream product variables are reserved for the product that defines them.

The `.env` file is shared by Compose interpolation and `configure.sh`. Secrets
with characters that Compose interpolation can alter belong in raw files below
the CT's `_secrets/` directory and must not be duplicated in `environment:`.

Bridge placement is deliberately not configured in `commonCT.json` or through
a `BRIDGE` override. It is derived from each Proxmox node's Linux bridge
`entities:` comments; see the networking guide.

## Sizing

Named sizes come from `sizes` and are selected with `--size`. Explicit
`--cores` and `--memory` values form a custom allocation and are mutually
exclusive with a named size. CPU priority is independent and maps the selected
priority to Proxmox CPU units.

## Safety

- Never commit `commonCT.json`, generated `.env` files, tokens, passwords, or
  registry credentials.
- Document configuration keys and semantics, not live values.
- Make configuration changes through the existing getters and validators.
- Keep generated per-CT environment updates idempotent.

## Related documentation

- [Architecture](architecture.md)
- [Storage and permissions](storage-and-permissions.md)
- [Networking and authentication](networking-and-authentication.md)
- [Troubleshooting](troubleshooting.md)
