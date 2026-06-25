# syntax=docker/dockerfile:1

# Self-compiled RustDesk OSS web client (Flutter web).
# Build recipe mirrors the upstream `build-rustdesk-web` job in
# rustdesk/rustdesk -> .github/workflows/flutter-build.yml
# (ref: https://rustdesk.com/docs/en/dev/build/web/).
# NOTE: upstream labels the web client "preview and not full functionality".

############################
# Stage 1: build the web app
############################
ARG FLUTTER_VERSION=3.24.5
ARG RUSTDESK_REF=1.4.8

FROM ubuntu:22.04 AS builder

ARG FLUTTER_VERSION
ARG RUSTDESK_REF
ENV DEBIAN_FRONTEND=noninteractive \
    FLUTTER_HOME=/opt/flutter \
    PATH=/opt/flutter/bin:/opt/flutter/bin/cache/dart-sdk/bin:/usr/local/bin:/usr/bin:/bin

# Build dependencies. `wget` + `npm` match the upstream job; the rest are
# needed to clone (with submodules) and bootstrap Flutter from git.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl wget git unzip xz-utils \
        npm bash; \
    rm -rf /var/lib/apt/lists/*

# Install Flutter at the pinned version (git checkout so the upstream patch
# can be `git apply`-ed against the SDK, exactly like the CI job does).
RUN set -eux; \
    git clone --depth 1 --branch "${FLUTTER_VERSION}" \
        https://github.com/flutter/flutter.git "${FLUTTER_HOME}"; \
    git config --global --add safe.directory "${FLUTTER_HOME}"; \
    flutter --version; \
    flutter config --enable-web --no-analytics; \
    flutter precache --web

# Clone the RustDesk sources (submodules are required for the web build).
RUN set -eux; \
    git clone --depth 1 --branch "${RUSTDESK_REF}" --recurse-submodules \
        https://github.com/rustdesk/rustdesk.git /opt/rustdesk; \
    git config --global --add safe.directory /opt/rustdesk

WORKDIR /opt/rustdesk

# Apply the Flutter dropdown patch to the SDK (only for 3.24.5, per upstream).
RUN set -eux; \
    if [ "${FLUTTER_VERSION}" = "3.24.5" ]; then \
        cd "$(dirname "$(dirname "$(command -v flutter)")")"; \
        git apply /opt/rustdesk/.github/patches/flutter_3.24.4_dropdown_menu_enableFilter.diff; \
    fi

# Build the JS/TS + WASM bridge bundle (vite must stay <= 2.8 per upstream).
RUN set -eux; \
    cd /opt/rustdesk/flutter/web/js; \
    npm install yarn -g; \
    npm install typescript -g; \
    npm install protoc -g; \
    npm install ts-proto; \
    npm install vite@2.8; \
    yarn install; \
    yarn build

# Fetch the prebuilt web dependencies (CanvasKit / WASM blobs) published by
# the RustDesk doc repo's `console` release.
RUN set -eux; \
    cd /opt/rustdesk/flutter/web; \
    wget -q https://github.com/rustdesk/doc.rustdesk.com/releases/download/console/web_deps.tar.gz; \
    tar xzf web_deps.tar.gz; \
    rm -f web_deps.tar.gz

# Produce the static site at flutter/build/web.
RUN set -eux; \
    cd /opt/rustdesk/flutter; \
    flutter build web --release

############################
# Stage 2: runtime (static)
############################
FROM nginx:alpine AS runtime

ARG RUSTDESK_REF
LABEL org.opencontainers.image.title="rustdesk-webclient" \
      org.opencontainers.image.description="Self-compiled RustDesk OSS web client (preview)" \
      org.opencontainers.image.source="https://github.com/rustdesk/rustdesk" \
      org.opencontainers.image.version="${RUSTDESK_REF}"

# Connection defaults (overridable at runtime via the compose `environment:`).
# Empty values leave the field blank so it can be set in the web UI instead.
ENV RUSTDESK_ID_SERVER="" \
    RUSTDESK_RELAY_SERVER="" \
    RUSTDESK_API_SERVER="" \
    RUSTDESK_KEY=""

COPY nginx-default.conf /etc/nginx/conf.d/default.conf
COPY docker-entrypoint.d/40-rustdesk-config.sh /docker-entrypoint.d/40-rustdesk-config.sh
RUN chmod +x /docker-entrypoint.d/40-rustdesk-config.sh

COPY --from=builder /opt/rustdesk/flutter/build/web /usr/share/nginx/html

EXPOSE 80
