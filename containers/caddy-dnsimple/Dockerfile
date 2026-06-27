FROM caddy:builder AS builder

RUN xcaddy build \
	--with github.com/caddy-dns/dnsimple \
	--with github.com/lucaslorentz/caddy-docker-proxy/v2

FROM alpine:latest

RUN apk add --no-cache bash ca-certificates

# Restore the official caddy image's storage locations (dropped by the alpine base).
# Without these, Caddy stores certs/ACME state in the ephemeral /root/.local/share/caddy
# instead of the persistent /data bind mount, forcing cert re-issuance on every recreate.
ENV XDG_CONFIG_HOME=/config
ENV XDG_DATA_HOME=/data

COPY --from=builder /usr/bin/caddy /usr/bin/caddy

COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

ENTRYPOINT ["/bin/bash", "/docker-entrypoint.sh"]
CMD ["caddy", "docker-proxy"]
