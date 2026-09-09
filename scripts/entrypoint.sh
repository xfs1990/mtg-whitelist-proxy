#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -gt 0 ]; then
  exec /usr/local/bin/mtg "$@"
fi

DATA_DIR="${DATA_DIR:-/data}"
GENERATED_DIR="${DATA_DIR}/generated"
PORT="${PORT:-}"
ADD_PORT="${ADD_PORT:-}"
DOMAIN="${DOMAIN:-cloudflare.com}"
SECRET_MODE="${SECRET_MODE:-tls}"
SECRET_MODE="${SECRET_MODE,,}"
IP_MODE="${IP_MODE:-auto}"
IP_MODE="${IP_MODE,,}"
WHITELIST_MODE="${WHITELIST_MODE:-SUBNET}"
WHITELIST_MODE="${WHITELIST_MODE^^}"
LOG_LEVEL="${LOG_LEVEL:-info}"
SECRET="${SECRET:-}"
ADD_TOKEN="${ADD_TOKEN:-}"
IPV4_SUBNET="${IPV4_SUBNET:-32}"
IPV6_SUBNET="${IPV6_SUBNET:-64}"
PUBLIC_IPV4="${PUBLIC_IPV4:-}"
PUBLIC_IPV6="${PUBLIC_IPV6:-}"
MTG_DOH_IP="${MTG_DOH_IP:-}"

mkdir -p "$GENERATED_DIR"

random_hex() {
  local bytes="$1"
  LC_ALL=C od -An -N"$bytes" -tx1 /dev/urandom | tr -d ' \n'
}

random_port() {
  local minimum="$1"
  local span="$2"
  local candidate

  for _ in $(seq 1 20); do
    candidate="$((minimum + 0x$(random_hex 2) % span))"
    if ! ss -ltn 2>/dev/null | awk -v port=":${candidate}" '$4 ~ port "$" {found = 1} END {exit found ? 0 : 1}'; then
      printf '%s\n' "$candidate"
      return
    fi
  done

  printf '%s\n' "$((minimum + 0x$(random_hex 2) % span))"
}

saved_value() {
  local name="$1"
  local file="${GENERATED_DIR}/${name}"

  if [ -s "$file" ]; then
    head -n 1 "$file"
  fi
  return 0
}

save_value() {
  local name="$1"
  local value="$2"
  local file="${GENERATED_DIR}/${name}"

  umask 077
  printf '%s\n' "$value" >"$file"
}

init_value() {
  local name="$1"
  local current="$2"
  local generated="$3"
  local value

  if [ -n "$current" ]; then
    value="$current"
  else
    value="$(saved_value "$name")"
    if [ -z "$value" ]; then
      value="$generated"
    fi
  fi

  save_value "$name" "$value"
  printf '%s\n' "$value"
}

PORT="$(init_value port "$PORT" "$(random_port 20000 20000)")"
ADD_PORT="$(init_value add_port "$ADD_PORT" "$(random_port 10000 10000)")"

if [ "$PORT" = "$ADD_PORT" ]; then
  ADD_PORT="$(random_port 10000 10000)"
  save_value add_port "$ADD_PORT"
fi

validate_number() {
  local name="$1"
  local value="$2"
  local minimum="$3"
  local maximum="$4"

  if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt "$minimum" ] || [ "$value" -gt "$maximum" ]; then
    echo "$name must be an integer between $minimum and $maximum." >&2
    exit 2
  fi
}

validate_number PORT "$PORT" 1 65535
validate_number ADD_PORT "$ADD_PORT" 1 65535
validate_number IPV4_SUBNET "$IPV4_SUBNET" 0 32
validate_number IPV6_SUBNET "$IPV6_SUBNET" 0 128

if [ "$PORT" = "$ADD_PORT" ]; then
  echo "PORT and ADD_PORT must be different." >&2
  exit 2
fi

export DATA_DIR PORT ADD_PORT DOMAIN IP_MODE WHITELIST_MODE IPV4_SUBNET IPV6_SUBNET

case "$SECRET_MODE" in
  tls|simple) ;;
  *)
    echo "Invalid SECRET_MODE: $SECRET_MODE" >&2
    exit 2
    ;;
esac

if [ -z "$SECRET" ]; then
  if [ "$SECRET_MODE" = "tls" ]; then
    SECRET="$(saved_value secret_tls)"
    if [ -z "$SECRET" ]; then
      SECRET="$(saved_value secret)"
    fi
  else
    SECRET="$(saved_value secret_simple)"
  fi
fi
if [ -z "$SECRET" ]; then
  if [ "$SECRET_MODE" = "tls" ]; then
    SECRET="$(/usr/local/bin/mtg generate-secret "$DOMAIN")"
    echo "已为伪装域名生成 MTG 密钥：$DOMAIN"
  else
    SECRET="$(random_hex 16)"
    echo "已生成普通 MTG 密钥。"
  fi
fi
save_value "secret_${SECRET_MODE}" "$SECRET"
if [ "$SECRET_MODE" = "tls" ]; then
  save_value secret "$SECRET"
fi
export SECRET SECRET_MODE

if [ "$WHITELIST_MODE" != "OFF" ] && [ -z "$ADD_TOKEN" ]; then
  ADD_TOKEN="$(saved_value add_token)"
  if [ -z "$ADD_TOKEN" ]; then
    ADD_TOKEN="$(random_hex 12)"
    echo "已生成白名单访问令牌。"
  fi
fi
if [ -n "$ADD_TOKEN" ]; then
  save_value add_token "$ADD_TOKEN"
fi
export ADD_TOKEN

if [[ "$ADD_TOKEN" == */* ]]; then
  echo "ADD_TOKEN must not contain '/'." >&2
  exit 2
fi

case "$WHITELIST_MODE" in
  OFF|IP|SUBNET) ;;
  *)
    echo "Invalid WHITELIST_MODE: $WHITELIST_MODE" >&2
    exit 2
    ;;
esac

touch "${DATA_DIR}/whitelist.json"
if [ ! -s "${DATA_DIR}/whitelist.json" ]; then
  printf '{"entries":[]}\n' >"${DATA_DIR}/whitelist.json"
fi

selected_ip_mode="$(IP_MODE="$IP_MODE" /usr/local/bin/detect-network.sh)"
echo "MTG 出站 IP 模式：$selected_ip_mode"
echo "MTG secret 模式：$SECRET_MODE"

doh_url() {
  local host="$1"
  if [[ "$host" == *:* ]]; then
    printf 'https://[%s]/dns-query\n' "$host"
  else
    printf 'https://%s/dns-query\n' "$host"
  fi
}

can_reach_doh() {
  local host="$1"
  curl -sS -o /dev/null --connect-timeout 3 --max-time 5 "$(doh_url "$host")" >/dev/null 2>&1
}

select_doh_ip() {
  local candidates=()
  local candidate

  if [ -n "$MTG_DOH_IP" ]; then
    printf '%s\n' "$MTG_DOH_IP"
    return
  fi

  case "$selected_ip_mode" in
    only-ipv6|prefer-ipv6)
      candidates=(2606:4700:4700::1111 2001:4860:4860::8888 1.1.1.1 8.8.8.8)
      ;;
    *)
      candidates=(1.1.1.1 8.8.8.8 2606:4700:4700::1111 2001:4860:4860::8888)
      ;;
  esac

  for candidate in "${candidates[@]}"; do
    if can_reach_doh "$candidate"; then
      printf '%s\n' "$candidate"
      return
    fi
  done

  echo "无法提前确认可用 DoH，继续使用 MTG 默认值 1.1.1.1。" >&2
  printf '%s\n' "1.1.1.1"
}

if [ "$SECRET_MODE" = "tls" ]; then
  selected_doh_ip="$(select_doh_ip)"
  echo "MTG DoH 解析地址：$selected_doh_ip"
else
  selected_doh_ip=""
  echo "MTG DoH 解析地址：未使用"
fi

/usr/local/bin/firewall.sh reset

detect_public_addresses() {
  if [ -z "$PUBLIC_IPV4" ]; then
    PUBLIC_IPV4="$(ip -o -4 addr show scope global 2>/dev/null | awk 'NR == 1 { split($4, a, "/"); value = a[1] } END { if (value) print value }')"
  fi
  if [ -z "$PUBLIC_IPV6" ]; then
    PUBLIC_IPV6="$(ip -o -6 addr show scope global 2>/dev/null | awk 'NR == 1 { split($4, a, "/"); value = a[1] } END { if (value) print value }')"
  fi
  export PUBLIC_IPV4 PUBLIC_IPV6
}

print_add_urls() {
  detect_public_addresses

  echo
  echo "白名单访问地址："
  if [ -n "$PUBLIC_IPV4" ]; then
    echo "IPv4-URL: http://${PUBLIC_IPV4}:${ADD_PORT}/add/${ADD_TOKEN}"
  fi
  if [ -n "$PUBLIC_IPV6" ]; then
    echo "IPv6-URL: http://[${PUBLIC_IPV6}]:${ADD_PORT}/add/${ADD_TOKEN}"
  fi
  echo "用手机打开其中一个地址，页面会自动放行当前 IP，并显示可点击的 Telegram 导入链接。"
  echo
}

if [ "$WHITELIST_MODE" != "OFF" ]; then
  print_add_urls
else
  detect_public_addresses
fi

server_pid=""
mtg_pid=""

cleanup() {
  local status="$?"
  trap - EXIT INT TERM

  if [ -n "$server_pid" ]; then
    kill "$server_pid" >/dev/null 2>&1 || true
  fi
  if [ -n "$mtg_pid" ]; then
    kill "$mtg_pid" >/dev/null 2>&1 || true
  fi
  wait "$server_pid" >/dev/null 2>&1 || true
  wait "$mtg_pid" >/dev/null 2>&1 || true
  /usr/local/bin/firewall.sh destroy >/dev/null 2>&1 || true
  exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

python3 /app/server.py &
server_pid="$!"

mtg_args=(simple-run --prefer-ip "$selected_ip_mode")
if [ "$LOG_LEVEL" = "debug" ]; then
  mtg_args=(simple-run --debug --prefer-ip "$selected_ip_mode")
fi
if [ "$SECRET_MODE" = "tls" ]; then
  mtg_args+=(--doh-ip "$selected_doh_ip")
fi
mtg_args+=("[::]:${PORT}" "$SECRET")

mtg "${mtg_args[@]}" &
mtg_pid="$!"

set +e
wait -n "$server_pid" "$mtg_pid"
status="$?"
set -e

if ! kill -0 "$server_pid" >/dev/null 2>&1; then
  echo "白名单 HTTP 服务异常退出。" >&2
  [ "$status" -ne 0 ] || status=1
fi

exit "$status"
