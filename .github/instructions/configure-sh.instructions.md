---
applyTo: "**/_config/configure.sh"
description: "Use when creating or modifying a per-CT _config/configure.sh: POSIX ash, idempotent post-deploy configuration, shared helpers, CT .env loading, and Authentik/OIDC registration."
---

# Per-CT configuration scripts

A CT may provide `_config/configure.sh` next to its Compose file. `createCT.sh` and `refreshCT.sh` run it inside the CT as the final provisioning step, after reboot and DNS health checks, with the CT hostname as `$1`.

- Use `#!/bin/sh`, `set -eu`, and BusyBox/POSIX syntax. Do not use Bash features such as `[[ ]]` or `==`.
- The script must be idempotent because it runs on every create and refresh.
- A non-zero exit is fatal to provisioning.
- Use it for service/API configuration that requires the complete stack, DNS, or external control planes. Use a Compose initializer instead for finite work that must complete before dependent services start.

## Shared configure library

The source of truth is `/root/scripts/configure/` on the Proxmox host. `sync_config_shared()` mirrors it into each CT at `/mnt/docker/_config/shared/` before configuration runs. Never edit the delivered CT copy.

After `set -eu`, source only what is needed:

```sh
SHARED_LIB_DIR="/mnt/docker/_config/shared"
if [ ! -f "${SHARED_LIB_DIR}/lib-common.sh" ]; then
  echo "  [!] Shared configure library missing under ${SHARED_LIB_DIR}"
  exit 1
fi
. "${SHARED_LIB_DIR}/lib-common.sh"
# Only for Authentik integration:
. "${SHARED_LIB_DIR}/lib-authentik.sh"
load_env_file "/mnt/docker/.env"
```

Do not copy shared implementations into individual scripts. Key helpers include:

- `ensure_tools`, `ensure_data_dir`, and `load_env_file`.
- `ak_init`, `ak_oidc_ensure_app`, and `ak_assign_outpost`.
- `ak_ensure_group` and `ak_group_add_superusers`.
- `oidc_apply_credentials`.

## CT `.env` is the configuration source

`/mnt/docker/.env` is the single source consumed by Compose and `configure.sh`. Do not create `_config/configure.env` or rely on hidden process injection.

Use product-neutral names written by `update_env_file`:

- `AUTH_HOSTNAME`
- `AUTH_API_TOKEN`
- `AUTH_AUTHORIZATION_FLOW`
- `AUTH_INVALIDATION_FLOW`

Do not invent `AUTHENTIK_*` names outside the upstream Authentik stack. Default optional values safely with `VAR="${VAR:-}"`. If integration prerequisites are absent, print an informational message and exit zero.

## Authentik/OIDC

Prefer native OpenID Connect over OAuth2 or proxy-only gating when the application supports it. Do not enable authentication silently; present the strategy and wait for confirmation.

- Derive a stable application slug with `oidc_slug "$CT_HOSTNAME"`. Add a service suffix only for multiple OIDC workloads in one CT.
- Redirect URIs use `https://<CT_HOSTNAME>/<callback>`.
- Call `ak_init`, then `ak_oidc_ensure_app`; do not hand-roll Authentik REST helpers.
- `ak_oidc_ensure_app` must receive explicit grant types, strict redirect URI, required scope mappings, authorization/invalidation flow slugs, and launch URL. It self-heals existing providers and always reasserts grant types, redirects, and scopes.
- Standard web clients use `authorization_code`; add `refresh_token` only when required. Common scopes are `openid email profile`.
- OAuth login providers do not need an outpost. Proxy/forward-auth providers use `ak_assign_outpost`.
- Deliver credentials with `oidc_apply_credentials`, which updates the raw secret env file and restarts only the affected service when content changed.
- Forward auth is managed exclusively by `forwardAuthCT.sh`; never implement its provider/application or Caddy-label reconciliation in lifecycle entry points.

## Readiness and error handling

Do not gate readiness on BusyBox `wget -qO-`; it treats redirects and authentication responses as failures. Retry the actual successful API operation and print the raw response body on failure.

Reference implementations:

- `dashboard.thesaints.home/_config/configure.sh` for Authentik/OIDC.
- `dns.thesaints.home/_config/configure.sh` for a non-Authentik script using common helpers.
