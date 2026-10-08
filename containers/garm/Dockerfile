ARG GARM_VERSION=v0.2.1

FROM alpine:3.22 AS provider

ARG TARGETARCH
ARG PROVIDER_VERSION=v0.2.0
ARG PROVIDER_SHA256_AMD64=17a2562e149557faa21acb829faf1e33272e6d24e424385f071d4a4e0da69b6d
ARG PROVIDER_SHA256_ARM64=5c3c2b975d0dcf9bd1a969310062d95fc8b8fb1f50ade56db50f81a4438f3aa9

RUN apk add --no-cache ca-certificates curl \
    && case "${TARGETARCH}" in \
        amd64) provider_sha256="${PROVIDER_SHA256_AMD64}" ;; \
        arm64) provider_sha256="${PROVIDER_SHA256_ARM64}" ;; \
        *) echo "Unsupported provider architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && provider_asset="garm-provider-docker_${PROVIDER_VERSION}_linux_${TARGETARCH}" \
    && curl --fail --location --show-error \
        --output /garm-provider-docker \
        "https://github.com/TzuH-Hsu/garm-provider-docker/releases/download/${PROVIDER_VERSION}/${provider_asset}" \
    && echo "${provider_sha256}  /garm-provider-docker" | sha256sum -c - \
    && chmod 0755 /garm-provider-docker

FROM ghcr.io/cloudbase/garm:${GARM_VERSION}

ARG GARM_VERSION
ARG PROVIDER_VERSION=v0.2.0

LABEL org.opencontainers.image.version="${GARM_VERSION}" \
      org.opencontainers.image.garm-provider-docker.version="${PROVIDER_VERSION}"

COPY --from=provider /garm-provider-docker /opt/garm/providers.d/garm-provider-docker
COPY --chmod=0755 healthcheck.sh /usr/local/bin/healthcheck

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD ["/usr/local/bin/healthcheck"]