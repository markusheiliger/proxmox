# Custom Container Images

This directory contains source for custom container images used by managed CT
workloads.

- `caddy-dnsimple/`: Caddy with the DNSimple DNS provider plugin.
- `caddy-stepca/`: Caddy with Step CA support for private-domain certificates.
- `ddns-update/`: Reconciles a DNSimple AAAA record with a UniFi WAN IPv6 address.
- `garm/`: GARM with the external Docker provider installed.
- `garm-dind/`: Project-tagged Docker-in-Docker sidecar for isolated jobs.
- `garm-runner/`: GitHub Actions runner with Docker CLI, Buildx, and Compose.

Each image directory owns its `Dockerfile` and entrypoint. Build context is the
image directory; deployment references belong in Compose files rather than in
this source folder.

## Caddy release lifecycle

`image-version.json` is the authoritative map from each project image name to
its reviewed base or application version. The `caddy-dnsimple` and
`caddy-stepca` entries must contain the same bare stable semantic version, such
as `2.11.4`. To adopt a new stable release, review its upstream release notes
and update both entries. The container workflow verifies that the pins match
the latest stable Caddy release before publishing either image.

Build both variants locally with the same release input used by CI:

```bash
CADDY_RELEASE=$(jq --exit-status --raw-output '."caddy-stepca"' containers/image-version.json)
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

The `ddns-update` entry in `image-version.json` is the independently reviewed
application version for `ghcr.io/markusheiliger/ddns-update`. The image uses
only the Python standard library and receives all site-specific configuration
at runtime; credentials must never be included in the image.

Run the source tests locally:

```bash
python3 -m unittest discover -s containers/ddns-update/tests -v
python3 -m py_compile \
	containers/ddns-update/ddns_update.py \
	containers/ddns-update/tests/test_ddns_update.py
```

Build the same tested image locally:

```bash
DDNS_UPDATE_VERSION=$(jq --exit-status --raw-output '."ddns-update"' containers/image-version.json)
docker build \
	--build-arg DDNS_UPDATE_VERSION="$DDNS_UPDATE_VERSION" \
	--tag ddns-update:verify containers/ddns-update
docker run --rm ddns-update:verify --version
```

The GitHub workflow publishes full, minor, major, and `latest` tags and verifies
the result by immutable digest. For version `1.1.0`, these are `1.1.0`, `1.1`,
`1`, and `latest`. Compose deployments use the explicit stable tag
`ghcr.io/markusheiliger/ddns-update:1.1.0`; `latest` is only a registry
convenience tag.

`DNSIMPLE_RECORD` is an optional explicit override. When it is absent, the
updater selects the one UniFi gateway that owns the global `wan1.ipv6` address,
reads `site_id` and `device_id` from that same API object, normalizes both by
trimming and lowercasing, and derives the record as:

```text
HMAC-SHA256(key=site_id, message=device_id).hexdigest()[0:16]
```

`UNIFI_SITE` remains the API path selector (commonly `default`); it is not the
opaque `site_id`. The generated lowercase hexadecimal label is a deterministic,
non-semantic fleet naming convention, not a security boundary. Persist the
resulting DNS identity in the operator inventory. A UniFi database reset or
readoption may change either source ID, but the updater never deletes the old
record automatically; use an explicit `DNSIMPLE_RECORD` during migration or
rollback when a stable prior name must be retained.

## GARM appliance image lifecycle

The `garm`, `garm-runner`, and `garm-dind` entries in `image-version.json`
select the exact upstream application versions used by the build runner
appliance. CI publishes only those exact tags; it does not publish moving or
abbreviated aliases. Each workflow run records the immutable resulting digest.

Build and test all three images locally with the same inputs used by CI:

```bash
GARM_VERSION=$(jq --exit-status --raw-output '.garm' containers/image-version.json)
RUNNER_VERSION=$(jq --exit-status --raw-output '."garm-runner"' containers/image-version.json)
DIND_VERSION=$(jq --exit-status --raw-output '."garm-dind"' containers/image-version.json)

docker build --build-arg GARM_VERSION="$GARM_VERSION" \
	--tag garm:verify containers/garm
containers/garm/tests/test-image.sh garm:verify

docker build --build-arg RUNNER_VERSION="$RUNNER_VERSION" \
	--tag garm-runner:verify containers/garm-runner
containers/garm-runner/tests/test-image.sh garm-runner:verify

docker build --build-arg DIND_VERSION="$DIND_VERSION" \
	--tag garm-dind:verify containers/garm-dind
containers/garm-dind/tests/test-image.sh garm-dind:verify
```

The runner image deliberately contains Docker client tooling but removes
`dockerd`, `containerd`, `runc`, and `docker-proxy`. GARM's Docker provider
creates one privileged `garm-dind` sidecar per job and shares only that job's
private socket with its runner. Neither dynamic container receives the host
Docker socket.

## Documentation

- [Networking and authentication](../documentation/networking-and-authentication.md)
- [Compose templates](../compose/README.md)
- [Architecture](../documentation/architecture.md)
