ARG MTG_IMAGE=nineseconds/mtg:2.2.8
FROM ${MTG_IMAGE} AS mtg

FROM alpine:3.20

RUN apk add --no-cache \
    bash \
    curl \
    iproute2 \
    nftables \
    python3

COPY --from=mtg /mtg /usr/local/bin/mtg
COPY scripts/ /usr/local/bin/
COPY app/ /app/

RUN chmod +x /usr/local/bin/entrypoint.sh \
    /usr/local/bin/detect-network.sh \
    /usr/local/bin/firewall.sh \
    /usr/local/bin/healthcheck.sh \
    && mkdir -p /data

ENV IP_MODE=auto \
    WHITELIST_MODE=SUBNET \
    IPV4_SUBNET=32 \
    IPV6_SUBNET=64 \
    DOMAIN=cloudflare.com \
    LOG_LEVEL=info

VOLUME ["/data"]
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD /usr/local/bin/healthcheck.sh || exit 1
STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
