ARG MTG_IMAGE=nineseconds/mtg:2.2.8
FROM ${MTG_IMAGE} AS mtg

FROM alpine:3.20

ARG TARGETARCH
ARG MTG_V1_VERSION=1.0.12

RUN apk add --no-cache \
    bash \
    curl \
    iproute2 \
    nftables \
    python3 \
    tar

COPY --from=mtg /mtg /usr/local/bin/mtg
RUN set -eu; \
    case "${TARGETARCH:-amd64}" in \
      amd64) mtg_arch="amd64" ;; \
      arm64) mtg_arch="arm64" ;; \
      386) mtg_arch="386" ;; \
      *) echo "Unsupported TARGETARCH for MTG v1: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    archive="mtg-${MTG_V1_VERSION}-linux-${mtg_arch}.tar.gz"; \
    curl -fsSL "https://github.com/9seconds/mtg/releases/download/v${MTG_V1_VERSION}/${archive}" -o "/tmp/${archive}"; \
    mkdir -p /tmp/mtg-v1; \
    tar -xzf "/tmp/${archive}" -C /tmp/mtg-v1; \
    mtg_path="$(find /tmp/mtg-v1 -type f -name mtg -print -quit)"; \
    test -n "$mtg_path"; \
    install -m 0755 "$mtg_path" /usr/local/bin/mtg-v1; \
    rm -rf /tmp/mtg-v1 "/tmp/${archive}"
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
    SECRET_MODE=tls \
    DOMAIN=cloudflare.com \
    LOG_LEVEL=info

VOLUME ["/data"]
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD /usr/local/bin/healthcheck.sh || exit 1
STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
