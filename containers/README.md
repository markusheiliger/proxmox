# Custom Container Images

This directory contains source for custom container images used by managed CT
workloads.

- `caddy-dnsimple/`: Caddy with the DNSimple DNS provider plugin.
- `caddy-stepca/`: Caddy with Step CA support for private-domain certificates.

Each image directory owns its `Dockerfile` and entrypoint. Build context is the
image directory; deployment references belong in Compose files rather than in
this source folder.

## Documentation

- [Networking and authentication](../documentation/networking-and-authentication.md)
- [Compose templates](../compose/README.md)
- [Architecture](../documentation/architecture.md)
