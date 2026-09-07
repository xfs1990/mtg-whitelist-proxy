#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -gt 0 ]; then
  exec /usr/local/bin/mtg "$@"
fi

PORT="${PORT:-18188}"
ADD_PORT="${ADD_PORT:-8080}"
DOMAIN="${DOMAIN:-cloudflare.com}"
IP_MODE="${IP_MODE:-auto}"
IP_MODE="${IP_MODE,,}"
WHITELIST_MODE="${WHITELIST_MODE:-SUBNET}"
WHITELIST_MODE="${WHITELIST_MODE^^}"
LOG_LEVEL="${LOG_LEVEL:-info}"
SECRET="${SECRET:-}"
ADD_TOKEN="${ADD_TOKEN:-}"
IPV4_SUBNET="${IPV4_SUBNET:-32}"
IPV6_SUBNET="${IPV6_SUBNET:-64}"

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

if [ -z "$SECRET" ]; then
  echo "SECRET is required. Generate one with: docker run --rm nineseconds/mtg:2 generate-secret $DOMAIN" >&2
  exit 2
fi

if [ "$WHITELIST_MODE" != "OFF" ] && [ -z "$ADD_TOKEN" ]; then
  echo "ADD_TOKEN is required unless WHITELIST_MODE=OFF." >&2
  exit 2
fi

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

mkdir -p /data
touch /data/whitelist.json
if [ ! -s /data/whitelist.json ]; then
  printf '{"entries":[]}\n' >/data/whitelist.json
fi

selected_ip_mode="$(IP_MODE="$IP_MODE" /usr/local/bin/detect-network.sh)"
echo "Selected MTG IP mode: $selected_ip_mode"

/usr/local/bin/firewall.sh reset

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

mtg_args=(simple-run --prefer-ip "$selected_ip_mode" "[::]:${PORT}" "$SECRET")
if [ "$LOG_LEVEL" = "debug" ]; then
  mtg_args=(simple-run --debug --prefer-ip "$selected_ip_mode" "[::]:${PORT}" "$SECRET")
fi

mtg "${mtg_args[@]}" &
mtg_pid="$!"

set +e
wait -n "$server_pid" "$mtg_pid"
status="$?"
set -e

if ! kill -0 "$server_pid" >/dev/null 2>&1; then
  echo "Whitelist HTTP service exited unexpectedly." >&2
  [ "$status" -ne 0 ] || status=1
fi

exit "$status"
