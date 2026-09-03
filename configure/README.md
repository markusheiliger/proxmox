# Configure Libraries

This directory is the host-side source of truth for shared POSIX shell helpers
used by per-CT `_config/configure.sh` scripts.

- `lib-common.sh`: tool installation, environment loading, data-directory, and
  credential-delivery helpers.
- `lib-authentik.sh`: idempotent Authentik API, OIDC application/provider,
  outpost, and group reconciliation.

`commonCT.sh` mirrors these files to `/mnt/docker/_config/shared/` inside each CT
before running its configure script. Delivered copies are generated and must not
be edited. Code in this directory must remain compatible with Alpine BusyBox
`sh`.

## Documentation

- [Configuration](../documentation/configuration.md)
- [Networking and authentication](../documentation/networking-and-authentication.md)
- [Architecture](../documentation/architecture.md)
