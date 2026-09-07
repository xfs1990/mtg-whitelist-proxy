#!/usr/bin/env bash
set -euo pipefail

image="${IMAGE:-ghcr.io/xfs1990/mtg-whitelist-proxy:latest}"
install_dir="${INSTALL_DIR:-/opt/mtg-whitelist-proxy}"
domain="${DOMAIN:-cloudflare.com}"
public_host="${PUBLIC_HOST:-}"
port="${PORT:-18188}"
add_port="${ADD_PORT:-8080}"
ip_mode="${IP_MODE:-auto}"
whitelist_mode="${WHITELIST_MODE:-SUBNET}"

case "$install_dir" in
  ""|/)
    echo "INSTALL_DIR must be a dedicated directory, not '/'." >&2
    exit 2
    ;;
esac

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker is required. Install Docker Engine first." >&2
  exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "Docker Compose v2 is required." >&2
  exit 1
fi

mkdir -p "$install_dir/data"
env_file="$install_dir/.env"
compose_file="$install_dir/docker-compose.yml"

docker pull "$image"

if [ ! -s "$env_file" ]; then
  secret="$(docker run --rm --entrypoint /usr/local/bin/mtg "$image" generate-secret "$domain")"
  if command -v openssl >/dev/null 2>&1; then
    add_token="$(openssl rand -hex 24)"
  else
    add_token="$(LC_ALL=C od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
  fi

  umask 077
  {
    printf 'IMAGE=%s\n' "$image"
    printf 'PORT=%s\n' "$port"
    printf 'ADD_PORT=%s\n' "$add_port"
    printf 'SECRET=%s\n' "$secret"
    printf 'DOMAIN=%s\n' "$domain"
    printf 'PUBLIC_HOST=%s\n' "$public_host"
    printf 'IP_MODE=%s\n' "$ip_mode"
    printf 'WHITELIST_MODE=%s\n' "$whitelist_mode"
    printf 'IPV4_SUBNET=32\n'
    printf 'IPV6_SUBNET=64\n'
    printf 'ADD_TOKEN=%s\n' "$add_token"
    printf 'LOG_LEVEL=info\n'
  } >"$env_file"
else
  echo "Keeping existing configuration at $env_file"
fi

cat >"$compose_file" <<'YAML'
services:
  mtproxy:
    image: ${IMAGE:-ghcr.io/xfs1990/mtg-whitelist-proxy:latest}
    container_name: mtg-whitelist-proxy
    restart: unless-stopped
    network_mode: host
    cap_add:
      - NET_ADMIN
    volumes:
      - ./data:/data
    env_file:
      - .env
YAML

docker compose --project-directory "$install_dir" --env-file "$env_file" -f "$compose_file" up -d

add_token="$(awk -F= '$1 == "ADD_TOKEN" {sub(/^[^=]*=/, ""); print; exit}' "$env_file")"
add_port="$(awk -F= '$1 == "ADD_PORT" {sub(/^[^=]*=/, ""); print; exit}' "$env_file")"

echo
echo "MTG whitelist proxy is running."
echo "Allow this device: http://<VPS-IP>:${add_port}/add/${add_token}"
echo "Configuration: $env_file"
echo "Logs: docker logs -f mtg-whitelist-proxy"
