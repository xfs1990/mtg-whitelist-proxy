#!/usr/bin/env bash
set -euo pipefail

mode="${IP_MODE:-auto}"
timeout="${DETECT_TIMEOUT:-3}"

case "$mode" in
  prefer-ipv4|prefer-ipv6|only-ipv4|only-ipv6)
    printf '%s\n' "$mode"
    exit 0
    ;;
  auto)
    ;;
  *)
    echo "Invalid IP_MODE: $mode" >&2
    exit 2
    ;;
esac

dc_hosts=(
  "149.154.175.50"
  "149.154.167.51"
  "149.154.175.100"
  "149.154.167.91"
  "91.108.56.130"
)

dc_hosts_v6=(
  "2001:b28:f23d:f001::a"
  "2001:67c:4e8:f002::a"
  "2001:b28:f23d:f003::a"
  "2001:67c:4e8:f004::a"
  "2001:b28:f23f:f005::a"
)

can_connect() {
  local host="$1"
  timeout "$timeout" bash -c ":</dev/tcp/${host}/443" >/dev/null 2>&1
}

check_family() {
  for host in "$@"; do
    if can_connect "$host"; then
      return 0
    fi
  done

  # MVP policy: one reachable Telegram DC is enough to consider a family usable.
  return 1
}

ipv4_ok=0
ipv6_ok=0
if check_family "${dc_hosts[@]}"; then
  ipv4_ok=1
fi
if check_family "${dc_hosts_v6[@]}"; then
  ipv6_ok=1
fi

if [ "$ipv4_ok" -eq 1 ] && [ "$ipv6_ok" -eq 1 ]; then
  printf '%s\n' "${AUTO_PREFER:-prefer-ipv6}"
elif [ "$ipv4_ok" -eq 1 ]; then
  printf '%s\n' "only-ipv4"
elif [ "$ipv6_ok" -eq 1 ]; then
  printf '%s\n' "only-ipv6"
else
  echo "No reachable Telegram DC over IPv4 or IPv6." >&2
  exit 1
fi
