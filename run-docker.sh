#!/usr/bin/env bash
set -euo pipefail

image="${IMAGE:-ghcr.io/xfs1990/mtg-whitelist-proxy:latest}"
container="${CONTAINER_NAME:-mtg-whitelist-proxy}"
data_dir="${DATA_DIR:-/opt/mtg-whitelist-proxy/data}"
replace="${RECREATE:-0}"

public_ipv4="${PUBLIC_IPV4:-}"
public_ipv6="${PUBLIC_IPV6:-}"

require_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "未找到 Docker。请先安装 Docker，或使用 install.sh 自动安装。" >&2
    exit 1
  fi
}

container_exists() {
  docker ps -a --format '{{.Names}}' | grep -Fxq "$container"
}

container_running() {
  docker ps --format '{{.Names}}' | grep -Fxq "$container"
}

env_args() {
  for name in \
    ADD_TOKEN SECRET DOMAIN PORT ADD_PORT IP_MODE WHITELIST_MODE \
    IPV4_SUBNET IPV6_SUBNET PUBLIC_HOST PUBLIC_IPV4 PUBLIC_IPV6 \
    LOG_LEVEL NFT_TABLE; do
    value="${!name:-}"
    if [ -n "$value" ]; then
      printf '%s\0%s\0' "-e" "${name}=${value}"
    fi
  done
}

detect_public_addresses() {
  if [ -z "$public_ipv4" ] && command -v curl >/dev/null 2>&1; then
    public_ipv4="$(curl -fsS --max-time 4 https://api.ipify.org 2>/dev/null || true)"
  fi
  if [ -z "$public_ipv6" ] && command -v curl >/dev/null 2>&1; then
    public_ipv6="$(curl -6 -fsS --max-time 4 https://api64.ipify.org 2>/dev/null || true)"
  fi

  if [ -z "$public_ipv4" ]; then
    public_ipv4="$(ip -o -4 addr show scope global 2>/dev/null | awk 'NR == 1 { split($4, a, "/"); value = a[1] } END { if (value) print value }')"
  fi
  if [ -z "$public_ipv6" ]; then
    public_ipv6="$(ip -o -6 addr show scope global 2>/dev/null | awk 'NR == 1 { split($4, a, "/"); value = a[1] } END { if (value) print value }')"
  fi
}

wait_generated_values() {
  for _ in $(seq 1 20); do
    if [ -s "${data_dir}/generated/add_token" ] && [ -s "${data_dir}/generated/add_port" ]; then
      return 0
    fi
    sleep 0.5
  done

  echo "容器已启动，但还没有生成白名单地址。最近日志：" >&2
  docker logs "$container" --tail=80 >&2 || true
  exit 1
}

print_urls() {
  local add_token
  local add_port
  local proxy_port

  add_token="$(head -n 1 "${data_dir}/generated/add_token")"
  add_port="$(head -n 1 "${data_dir}/generated/add_port")"
  proxy_port="$(head -n 1 "${data_dir}/generated/port" 2>/dev/null || true)"
  detect_public_addresses

  echo
  echo "MTG Docker 版已启动。"
  if [ -n "$proxy_port" ]; then
    echo "代理端口：${proxy_port}"
  fi
  if [ -n "$public_ipv4" ]; then
    echo "IPv4-URL: http://${public_ipv4}:${add_port}/add/${add_token}"
  fi
  if [ -n "$public_ipv6" ]; then
    echo "IPv6-URL: http://[${public_ipv6}]:${add_port}/add/${add_token}"
  fi
  echo "配置目录：${data_dir}"
  echo "日志：docker logs -f ${container}"
  echo
}

require_docker
mkdir -p "$data_dir"

docker pull "$image" >/dev/null

if [ "$replace" = "1" ] && container_exists; then
  docker rm -f "$container" >/dev/null
fi

if container_exists; then
  if ! container_running; then
    docker start "$container" >/dev/null
  fi
else
  args=()
  while IFS= read -r -d '' item; do
    args+=("$item")
  done < <(env_args)

  docker run -d \
    --name "$container" \
    --restart unless-stopped \
    --network host \
    --cap-add NET_ADMIN \
    -v "${data_dir}:/data" \
    "${args[@]}" \
    "$image" >/dev/null
fi

wait_generated_values
print_urls
