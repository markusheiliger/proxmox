ARG GARM_VERSION=v0.2.1

FROM alpine:3.22 AS garm-source

ARG GARM_VERSION

RUN apk add --no-cache curl patch \
    && mkdir -p /build/garm \
    && curl --fail --location --show-error \
        "https://github.com/cloudbase/garm/archive/refs/tags/${GARM_VERSION}.tar.gz" \
        | tar --extract --gzip --strip-components=1 --directory /build/garm

COPY list-instances-v011.patch /tmp/list-instances-v011.patch

RUN patch --directory /build/garm --strip=1 < /tmp/list-instances-v011.patch \
    && grep -Fq 'if err != nil {' /build/garm/runner/providers/v0.1.1/external.go

FROM node:22-alpine3.22 AS webapp

WORKDIR /build/webapp

COPY --from=garm-source /build/garm/webapp/package.json /build/garm/webapp/package-lock.json ./
RUN npm ci --ignore-scripts \
    && chmod +x node_modules/@esbuild/linux-x64/bin/esbuild
COPY --from=garm-source /build/garm/webapp/ ./
RUN ESBUILD_BINARY_PATH=/build/webapp/node_modules/@esbuild/linux-x64/bin/esbuild npm run build

FROM golang:1.26-alpine3.22 AS garm-builder

ARG GARM_VERSION

RUN apk add --no-cache gcc g++ git libtool linux-headers m4 make musl-dev util-linux-dev

COPY --from=garm-source /build/garm/ /build/garm/
COPY --from=webapp /build/webapp/build/ /build/garm/webapp/assets/

RUN cd /build/garm \
    && go build -o /garm \
        -tags osusergo,netgo,sqlite_omit_load_extension \
        -ldflags "-linkmode external -extldflags '-static' -s -w -X github.com/cloudbase/garm/util/appdefaults.Version=${GARM_VERSION}" \
        ./cmd/garm

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
    org.opencontainers.image.garm-provider-docker.version="${PROVIDER_VERSION}" \
    org.opencontainers.image.garm.patch.list-instances-v011="true"

COPY --from=garm-builder /garm /bin/garm
COPY --from=provider /garm-provider-docker /opt/garm/providers.d/garm-provider-docker
COPY --chmod=0755 healthcheck.sh /usr/local/bin/healthcheck

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD ["/usr/local/bin/healthcheck"]