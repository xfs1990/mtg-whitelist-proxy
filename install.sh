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
auto_install_docker="${AUTO_INSTALL_DOCKER:-1}"
force_ipv4="${FORCE_IPV4:-0}"
docker_install_source="${DOCKER_INSTALL_SOURCE:-auto}"

apt_cmd() {
  if [ "$force_ipv4" = "1" ]; then
    apt-get -o Acquire::ForceIPv4=true "$@"
  else
    apt-get "$@"
  fi
}

compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
    return
  fi

  if command -v docker-compose >/dev/null 2>&1; then
    docker-compose "$@"
    return
  fi

  return 127
}

start_docker_service() {
  systemctl enable --now docker >/dev/null 2>&1 || systemctl start docker
}

disable_official_docker_apt_source() {
  for source_file in \
    /etc/apt/sources.list.d/docker.sources \
    /etc/apt/sources.list.d/docker.list; do
    if [ -f "$source_file" ] && grep -q 'download.docker.com' "$source_file"; then
      mv "$source_file" "${source_file}.disabled-by-mtg-whitelist-proxy"
      echo "Disabled unreachable Docker apt source: $source_file"
    fi
  done
}

install_docker_from_distro() {
  echo "Installing Docker from the distribution apt repository..."
  export DEBIAN_FRONTEND=noninteractive
  disable_official_docker_apt_source
  apt_cmd update

  if apt_cmd install -y docker.io docker-compose-plugin; then
    start_docker_service
    return
  fi

  apt_cmd install -y docker.io docker-compose
  start_docker_service
}

install_docker_from_official() {
  # shellcheck disable=SC1091
  . /etc/os-release

  case "${ID:-}" in
    debian)
      docker_repo="https://download.docker.com/linux/debian"
      docker_codename="${VERSION_CODENAME:-}"
      ;;
    ubuntu)
      docker_repo="https://download.docker.com/linux/ubuntu"
      docker_codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
      ;;
    *)
      echo "Docker is not installed. Automatic Docker install supports Debian/Ubuntu only." >&2
      exit 1
      ;;
  esac

  if [ -z "$docker_codename" ]; then
    echo "Could not detect OS codename for Docker apt repository." >&2
    exit 1
  fi

  echo "Installing Docker Engine from Docker's official apt repository..."
  export DEBIAN_FRONTEND=noninteractive

  apt_cmd update
  apt_cmd install -y ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  if [ "$force_ipv4" = "1" ]; then
    curl -4 -fsSL "$docker_repo/gpg" -o /etc/apt/keyrings/docker.asc
  else
    curl -fsSL "$docker_repo/gpg" -o /etc/apt/keyrings/docker.asc
  fi
  chmod a+r /etc/apt/keyrings/docker.asc

  cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: $docker_repo
Suites: $docker_codename
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

  apt_cmd update
  apt_cmd install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  start_docker_service
}

install_docker_engine() {
  if [ "$auto_install_docker" != "1" ]; then
    echo "Docker is required. Install Docker Engine first, or rerun with AUTO_INSTALL_DOCKER=1." >&2
    exit 1
  fi

  if [ "$(id -u)" -ne 0 ]; then
    echo "Docker is not installed. Run this installer as root so it can install Docker Engine." >&2
    exit 1
  fi

  if [ ! -r /etc/os-release ]; then
    echo "Docker is not installed and /etc/os-release is unavailable." >&2
    exit 1
  fi

  case "$docker_install_source" in
    official)
      install_docker_from_official
      ;;
    distro)
      install_docker_from_distro
      ;;
    auto)
      if ! install_docker_from_official; then
        echo "Official Docker installation failed. Falling back to distribution packages..." >&2
        install_docker_from_distro
      fi
      ;;
    *)
      echo "DOCKER_INSTALL_SOURCE must be auto, official, or distro." >&2
      exit 1
      ;;
  esac
}

case "$install_dir" in
  ""|/)
    echo "INSTALL_DIR must be a dedicated directory, not '/'." >&2
    exit 2
    ;;
esac

if ! command -v docker >/dev/null 2>&1; then
  install_docker_engine
fi

if ! compose_cmd version >/dev/null 2>&1; then
  install_docker_engine
fi

if ! compose_cmd version >/dev/null 2>&1; then
  echo "Docker Compose is required but still unavailable after Docker installation." >&2
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

if docker compose version >/dev/null 2>&1; then
  docker compose --project-directory "$install_dir" --env-file "$env_file" -f "$compose_file" up -d
else
  (cd "$install_dir" && docker-compose --env-file "$env_file" -f "$compose_file" up -d)
fi

add_token="$(awk -F= '$1 == "ADD_TOKEN" {sub(/^[^=]*=/, ""); print; exit}' "$env_file")"
add_port="$(awk -F= '$1 == "ADD_PORT" {sub(/^[^=]*=/, ""); print; exit}' "$env_file")"

echo
echo "MTG whitelist proxy is running."
echo "Allow this device: http://<VPS-IP>:${add_port}/add/${add_token}"
echo "Configuration: $env_file"
echo "Logs: docker logs -f mtg-whitelist-proxy"
