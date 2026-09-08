#!/usr/bin/env bash
set -euo pipefail

table_name="${NFT_TABLE:-mtproxy_guard}"
chain_name="input"
port="${PORT:-18188}"
add_port="${ADD_PORT:-8080}"
whitelist_mode="${WHITELIST_MODE:-SUBNET}"
data_file="${WHITELIST_FILE:-/data/whitelist.json}"

if ! [[ "$table_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
  echo "NFT_TABLE may contain only letters, numbers, and underscores." >&2
  exit 2
fi

for value in "$port" "$add_port"; do
  if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt 1 ] || [ "$value" -gt 65535 ]; then
    echo "Invalid TCP port: $value" >&2
    exit 2
  fi
done

require_nft() {
  if ! command -v nft >/dev/null 2>&1; then
    echo "nft command not found" >&2
    exit 1
  fi
}

init_table() {
  require_nft
  nft delete table inet "$table_name" >/dev/null 2>&1 || true
  nft add table inet "$table_name"
  nft "add set inet $table_name allowed_v4 { type ipv4_addr; flags interval; }"
  nft "add set inet $table_name allowed_v6 { type ipv6_addr; flags interval; }"
  nft "add chain inet $table_name $chain_name { type filter hook input priority -90; policy accept; }"
  nft "add rule inet $table_name $chain_name tcp dport $add_port accept"

  if [ "$whitelist_mode" != "OFF" ]; then
    nft "add rule inet $table_name $chain_name ip saddr @allowed_v4 tcp dport $port accept"
    nft "add rule inet $table_name $chain_name ip6 saddr @allowed_v6 tcp dport $port accept"
    nft "add rule inet $table_name $chain_name tcp dport $port drop"
  else
    nft "add rule inet $table_name $chain_name tcp dport $port accept"
  fi
}

add_network() {
  local network
  network="$(python3 - "$1" <<'PY'
import ipaddress
import sys

try:
    print(ipaddress.ip_network(sys.argv[1], strict=True))
except ValueError as exc:
    print(f"Invalid network: {exc}", file=sys.stderr)
    sys.exit(2)
PY
)"

  if ! nft list table inet "$table_name" >/dev/null 2>&1; then
    echo "nftables table inet $table_name is not initialized." >&2
    return 1
  fi

  if [[ "$network" == *:* ]]; then
    nft "add element inet $table_name allowed_v6 { $network }" >/dev/null 2>&1 || true
  else
    nft "add element inet $table_name allowed_v4 { $network }" >/dev/null 2>&1 || true
  fi
}

restore() {
  if [ ! -s "$data_file" ]; then
    return 0
  fi

  while IFS= read -r network; do
    [ -n "$network" ] || continue
    if ! add_network "$network"; then
      echo "跳过无法恢复的白名单条目：$network" >&2
    fi
  done < <(python3 - "$data_file" <<'PY'
import json
import sys

path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except (FileNotFoundError, json.JSONDecodeError):
    sys.exit(0)

for item in data.get("entries", []):
    network = item.get("network")
    if network:
        print(network)
PY
)
}

case "${1:-}" in
  init)
    init_table
    ;;
  add)
    [ -n "${2:-}" ] || { echo "Usage: firewall.sh add <network>" >&2; exit 2; }
    add_network "$2"
    ;;
  restore)
    restore
    ;;
  reset)
    init_table
    restore
    ;;
  destroy)
    require_nft
    nft delete table inet "$table_name" >/dev/null 2>&1 || true
    ;;
  *)
    echo "Usage: firewall.sh init|restore|reset|destroy|add <network>" >&2
    exit 2
    ;;
esac
