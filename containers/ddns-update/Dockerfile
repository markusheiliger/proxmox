ARG PYTHON_IMAGE=python:3.14.8-alpine3.24
FROM ${PYTHON_IMAGE} AS test

ARG DDNS_UPDATE_VERSION=required
ENV DDNS_UPDATE_VERSION=${DDNS_UPDATE_VERSION}
WORKDIR /app
COPY ddns_update.py .
COPY tests ./tests
RUN python -m unittest discover -s tests -v

FROM ${PYTHON_IMAGE}

ARG DDNS_UPDATE_VERSION=required
LABEL org.opencontainers.image.version="${DDNS_UPDATE_VERSION}"

ENV DDNS_UPDATE_VERSION=${DDNS_UPDATE_VERSION} \
    HEALTH_FILE=/run/ddns-update/last-success \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

RUN addgroup -S -g 10001 ddns-update \
    && adduser -S -D -H -u 10001 -G ddns-update ddns-update \
    && mkdir -p /app /run/ddns-update \
    && chown ddns-update:ddns-update /run/ddns-update

COPY --from=test --chown=10001:10001 /app/ddns_update.py /app/ddns_update.py

USER 10001:10001
ENTRYPOINT ["python", "/app/ddns_update.py"]
HEALTHCHECK --interval=1m --timeout=10s --start-period=2m --retries=3 \
    CMD ["python", "/app/ddns_update.py", "--healthcheck"]