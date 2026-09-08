# Container image versioning

Compose files should make the deployed software version readable while operational evidence makes the selected artifact traceable.

## Readable deployment references

Use explicit stable release tags for third-party images:

```yaml
image: smallstep/step-ca:0.30.2
```

Do not use `latest`, `stable`, an unversioned variant such as `alpine`, or an unbounded major tag for third-party deployments. Review release notes, migrations, application compatibility, required variants, and registry platform support before changing a tag. Services that intentionally share an image must use the same exact tag.

Do not normally append a registry digest to the Compose reference. A readable tag is the maintained deployment intent.

## Verification and rollback evidence

Resolve and record the immutable digest separately when inspecting or changing an image. Evidence should identify:

- the authored image reference;
- the resolved registry digest for each required platform;
- the running container image ID and application version;
- the release and compatibility sources used to choose the tag;
- the previously deployed tag and digest needed for rollback.

Compare this evidence during optimization and deployment verification to detect registry drift. A readable tag does not replace digest verification, and a mutable tag alone is never proof of the running version.

Rollback restores the previously verified readable tag. The recorded digest identifies the exact former artifact and confirms that the registry still resolves the rollback tag as expected.

## Sole floating-tag exception

The only permitted floating deployment references are:

```yaml
image: ghcr.io/markusheiliger/caddy-stepca:latest
image: ghcr.io/markusheiliger/caddy-dnsimple:latest
```

These images are built and controlled by this repository's operator, so urgent Caddy or plugin fixes can be rebuilt and deployed without changing every stack. Do not replace them with official Caddy images, version tags, or digest-appended references.

The exception does not weaken verification. Record each running digest and embedded Caddy version, verify the expected plugins and target platforms, and retain prior build evidence for rollback.
