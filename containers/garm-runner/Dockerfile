ARG RUNNER_VERSION=2.338.0

FROM alpine:3.22 AS compose

ARG TARGETARCH
ARG COMPOSE_VERSION=5.6.0
ARG COMPOSE_SHA256_AMD64=40343e21ca777173e69cff5dbafeb37c6f81f3b0d57d9e597f036e95eb63e76a
ARG COMPOSE_SHA256_ARM64=733ec76717ceb59052a9609b9dadfb523b2df8eab57a54212872d10a58078ea2

RUN apk add --no-cache ca-certificates curl \
    && case "${TARGETARCH}" in \
        amd64) compose_arch="x86_64"; compose_sha256="${COMPOSE_SHA256_AMD64}" ;; \
        arm64) compose_arch="aarch64"; compose_sha256="${COMPOSE_SHA256_ARM64}" ;; \
        *) echo "Unsupported Docker Compose architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && curl --fail --location --show-error \
        --output /docker-compose \
        "https://github.com/docker/compose/releases/download/v${COMPOSE_VERSION}/docker-compose-linux-${compose_arch}" \
    && echo "${compose_sha256}  /docker-compose" | sha256sum -c - \
    && chmod 0755 /docker-compose

FROM ghcr.io/actions/actions-runner:${RUNNER_VERSION}

ARG RUNNER_VERSION
ARG COMPOSE_VERSION=5.6.0

LABEL org.opencontainers.image.version="${RUNNER_VERSION}" \
      org.opencontainers.image.docker-compose.version="${COMPOSE_VERSION}"

USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends util-linux \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f \
        /usr/bin/containerd \
        /usr/bin/containerd-shim-runc-v2 \
        /usr/bin/ctr \
        /usr/bin/docker-init \
        /usr/bin/docker-proxy \
        /usr/bin/dockerd \
        /usr/bin/runc \
    && find /usr/bin -maxdepth 1 -type f -name 'containerd*' -delete \
    && command -v docker >/dev/null \
    && command -v setpriv >/dev/null \
    && ! command -v dockerd >/dev/null \
    && ! command -v containerd >/dev/null \
    && ! command -v runc >/dev/null

COPY --from=compose /docker-compose /usr/local/lib/docker/cli-plugins/docker-compose
COPY --chmod=0755 entrypoint.sh /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
CMD ["/home/runner/run.sh"]