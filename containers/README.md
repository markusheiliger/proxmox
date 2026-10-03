# Custom Container Images

This directory contains source for custom container images used by managed CT
workloads.

- `caddy-dnsimple/`: Caddy with the DNSimple DNS provider plugin.
- `caddy-stepca/`: Caddy with Step CA support for private-domain certificates.
- `ddns-update/`: Reconciles a DNSimple AAAA record with a UniFi WAN IPv6 address.

Each image directory owns its `Dockerfile` and entrypoint. Build context is the
image directory; deployment references belong in Compose files rather than in
this source folder.

## Caddy release lifecycle

`caddy-version` is the reviewed Caddy core version used by both custom images.
It contains a bare stable semantic version, such as `2.11.4`. To adopt a new
stable release, review its upstream release notes and update this file. The
container workflow verifies that the pin matches the latest stable Caddy
release before publishing either image.

Build both variants locally with the same release input used by CI:

```bash
CADDY_RELEASE=$(cat containers/caddy-version)
docker build --build-arg CADDY_RELEASE="$CADDY_RELEASE" \
	--tag caddy-stepca:verify containers/caddy-stepca
docker build --build-arg CADDY_RELEASE="$CADDY_RELEASE" \
	--tag caddy-dnsimple:verify containers/caddy-dnsimple
```

Bypass the custom entrypoint when auditing the embedded binaries:

```bash
docker run --rm --entrypoint caddy caddy-stepca:verify version
docker run --rm --entrypoint caddy caddy-stepca:verify list-modules --packages
docker run --rm --entrypoint step caddy-stepca:verify version
docker run --rm --entrypoint caddy caddy-dnsimple:verify version
docker run --rm --entrypoint caddy caddy-dnsimple:verify list-modules --packages
```

The GitHub Actions workflow can also be dispatched manually and runs weekly to
detect an outdated release pin. The shared release job fails before either
variant starts building unless the pin equals the latest stable upstream Caddy
release. For each variant, its job summary records the previous `latest` digest
and Caddy version status, then verifies the newly published image by the
immutable digest returned from the build.

Each successful build publishes the same image digest under tags matching the
official Caddy release family. For Caddy `2.11.4`, these are `2.11.4`, `2.11`,
`2`, and `latest`.

Deployments must continue to use the project images
`ghcr.io/markusheiliger/caddy-stepca:latest` and
`ghcr.io/markusheiliger/caddy-dnsimple:latest`. After a successful build,
refresh affected CTs through the repository lifecycle tooling so they pull the
new digest.

## DDNS updater release lifecycle

`ddns-update-version` is the independently reviewed application version for
`ghcr.io/markusheiliger/ddns-update`. The image uses only the Python standard
library and receives all site-specific configuration at runtime; credentials
must never be included in the image.

Run the source tests locally:

```bash
python3 -m unittest discover -s containers/ddns-update/tests -v
python3 -m py_compile \
	containers/ddns-update/ddns_update.py \
	containers/ddns-update/tests/test_ddns_update.py
```

Build the same tested image locally:

```bash
DDNS_UPDATE_VERSION=$(cat containers/ddns-update-version)
docker build \
	--build-arg DDNS_UPDATE_VERSION="$DDNS_UPDATE_VERSION" \
	--tag ddns-update:verify containers/ddns-update
docker run --rm ddns-update:verify --version
```

The GitHub workflow publishes full, minor, major, and `latest` tags and verifies
the result by immutable digest. For version `1.0.0`, these are `1.0.0`, `1.0`,
`1`, and `latest`. Compose deployments use the explicit stable tag
`ghcr.io/markusheiliger/ddns-update:1.0.0`; `latest` is only a registry
convenience tag.

## Documentation

- [Networking and authentication](../documentation/networking-and-authentication.md)
- [Compose templates](../compose/README.md)
- [Architecture](../documentation/architecture.md)
