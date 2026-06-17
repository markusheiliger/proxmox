FROM caddy:builder AS builder

RUN xcaddy build \
	--with github.com/caddy-dns/dnsimple \
	--with github.com/lucaslorentz/caddy-docker-proxy/v2

FROM alpine:latest

RUN apk add --no-cache bash ca-certificates

COPY --from=builder /usr/bin/caddy /usr/bin/caddy

COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

ENTRYPOINT ["/bin/bash", "/docker-entrypoint.sh"]
CMD ["caddy", "docker-proxy"]
