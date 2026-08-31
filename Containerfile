# Merkleye certspotter sidecar.
#
# This is the primary ingestion source. It does not tail CT logs itself —
# SSLMate's certspotter already implements RFC6962 *and* static-ct-api tiled
# fetching, per-log checkpointing, and a parser hardened against null-byte and
# encoding evasion. See merkleye/merkleye's docs/DESIGN.md §06.
#
# Consumed by merkleye/merkleye's deploy/docker-compose.yml as
# ghcr.io/merkleye/merkleye-certspotter — this repo owns the source and
# CI/CD for that image; merkleye/merkleye only references the published tag.
FROM golang:1.27-alpine AS build

# Pin the version rather than tracking latest: this is the component that
# decides whether a certificate is seen at all, so upgrades should be a
# deliberate, reviewed change.
ARG CERTSPOTTER_VERSION=v0.24.2
RUN go install software.sslmate.com/src/certspotter/cmd/certspotter@${CERTSPOTTER_VERSION}

FROM alpine:3.24

ARG OCI_VERSION=0.0.0
ARG OCI_REVISION=unknown
ARG OCI_CREATED=unknown
ARG OCI_REF_NAME=dev
ARG OCI_SOURCE=https://github.com/merkleye/certspotter

LABEL org.opencontainers.image.title="Merkleye certspotter sidecar" \
      org.opencontainers.image.description="RFC6962 / static-ct-api Certificate Transparency log tailer" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.source="${OCI_SOURCE}" \
      org.opencontainers.image.url="${OCI_SOURCE}" \
      org.opencontainers.image.version="${OCI_VERSION}" \
      org.opencontainers.image.revision="${OCI_REVISION}" \
      org.opencontainers.image.created="${OCI_CREATED}" \
      org.opencontainers.image.ref.name="${OCI_REF_NAME}"

RUN apk add --no-cache curl jq ca-certificates tini

COPY --from=build /go/bin/certspotter /usr/local/bin/certspotter
COPY hook.sh /usr/local/bin/merkleye-hook.sh
COPY healthcheck.sh /usr/local/bin/merkleye-healthcheck.sh
RUN chmod +x /usr/local/bin/merkleye-hook.sh /usr/local/bin/merkleye-healthcheck.sh

# certspotter's state_dir holds per-log checkpoints. Losing it means restarting
# at the log tip and losing every certificate issued since the last checkpoint,
# which is why it is a named volume in merkleye/merkleye's docker-compose.yml
# and not scratch space.
ENV CERTSPOTTER_STATE_DIR=/var/lib/certspotter
RUN mkdir -p /var/lib/certspotter /var/lib/merkleye

# tini reaps the short-lived hook processes certspotter forks per certificate.
ENTRYPOINT ["/sbin/tini", "--"]

# -start_at_end: begin at the log tip. Starting from the beginning would mean
#   downloading hundreds of millions of entries over several days; historical
#   coverage comes from the SSLMate backfill plugin instead (DESIGN G-02).
# -no_save: Merkleye persists what it needs in Postgres; a second copy on disk
#   here would grow unbounded.
CMD ["sh", "-c", "exec certspotter \
    -watchlist /var/lib/merkleye/watchlist.txt \
    -state_dir \"$CERTSPOTTER_STATE_DIR\" \
    -script /usr/local/bin/merkleye-hook.sh \
    -start_at_end \
    -no_save \
    -verbose"]

# Process liveness + checkpoint freshness, plus a heartbeat POST to the
# backend on success — see healthcheck.sh and merkleye/merkleye's
# docs/OPERATIONS.md. autoheal (merkleye/merkleye's deploy/docker-compose.yml)
# restarts this container when Docker marks it unhealthy; plain
# `restart: unless-stopped` alone only catches an exit, not a hung-but-running
# process.
HEALTHCHECK --interval=1m --timeout=10s --start-period=30s --retries=3 \
    CMD /usr/local/bin/merkleye-healthcheck.sh
