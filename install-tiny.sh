#!/usr/bin/env bash
set -euo pipefail

repo_raw="${REPO_RAW:-https://raw.githubusercontent.com/xfs1990/mtg-whitelist-proxy/main}"
install_dir="${INSTALL_DIR:-/opt/mtg-whitelist-proxy-tiny}"
mtg_version="${MTG_VERSION:-2.2.8}"
domain="${DOMAIN:-cloudflare.com}"
port="${PORT:-18188}"
add_port="${ADD_PORT:-8080}"
ip_mode="${IP_MODE:-auto}"
whitelist_mode="${WHITELIST_MODE:-SUBNET}"
ipv4_subnet="${IPV4_SUBNET:-32}"
ipv6_subnet="${IPV6_SUBNET:-64}"
add_token="${ADD_TOKEN:-}"
secret="${SECRET:-}"
public_host="${PUBLIC_HOST:-}"
public_ipv4="${PUBLIC_IPV4:-}"
public_ipv6="${PUBLIC_IPV6:-}"
force_ipv4="${FORCE_IPV4:-0}"
init_system=""

apt_cmd() {
  if [ "$force_ipv4" = "1" ]; then
    apt-get -o Acquire::ForceIPv4=true "$@"
  else
    apt-get "$@"
  fi
}

install_packages() {
  if command -v apk >/dev/null 2>&1; then
    apk update
    apk add bash curl ca-certificates python3 nftables iproute2 tar coreutils openrc
    return
  fi

  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt_cmd update
    apt_cmd install -y ca-certificates curl tar python3-minimal nftables iproute2 coreutils
    return
  fi

  echo "Unsupported package manager. Install bash, curl, python3, nftables, iproute2, tar, and coreutils first." >&2
  exit 1
}

curl_cmd() {
  if [ "$force_ipv4" = "1" ]; then
    curl -4 "$@"
  else
    curl "$@"
  fi
}

random_hex() {
  local bytes="$1"
  LC_ALL=C od -An -N"$bytes" -tx1 /dev/urandom | tr -d ' \n'
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Run this installer as root." >&2
    exit 1
  fi
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'amd64\n' ;;
    aarch64|arm64) printf 'arm64\n' ;;
    i386|i686) printf '386\n' ;;
    armv7l) printf 'armv7\n' ;;
    armv6l) printf 'armv6\n' ;;
    *)
      echo "Unsupported architecture: $(uname -m)" >&2
      exit 1
      ;;
  esac
}

detect_public_addresses() {
  if [ -z "$public_ipv4" ]; then
    public_ipv4="$(curl_cmd -fsS --max-time 4 https://api.ipify.org 2>/dev/null || true)"
  fi
  if [ -z "$public_ipv6" ]; then
    public_ipv6="$(curl -6 -fsS --max-time 4 https://api64.ipify.org 2>/dev/null || true)"
  fi

  if [ -z "$public_ipv4" ]; then
    public_ipv4="$(ip -o -4 addr show scope global 2>/dev/null | awk '{split($4, a, "/"); print a[1]; exit}')"
  fi
  if [ -z "$public_ipv6" ]; then
    public_ipv6="$(ip -o -6 addr show scope global 2>/dev/null | awk '{split($4, a, "/"); print a[1]; exit}')"
  fi
}

validate_port() {
  local name="$1"
  local value="$2"
  if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt 1 ] || [ "$value" -gt 65535 ]; then
    echo "$name must be an integer between 1 and 65535." >&2
    exit 2
  fi
}

write_env() {
  umask 077
  cat >"${install_dir}/mtg-whitelist.env" <<EOF
PORT=${port}
ADD_PORT=${add_port}
SECRET=${secret}
DOMAIN=${domain}
PUBLIC_HOST=${public_host}
PUBLIC_IPV4=${public_ipv4}
PUBLIC_IPV6=${public_ipv6}
IP_MODE=${ip_mode}
WHITELIST_MODE=${whitelist_mode}
IPV4_SUBNET=${ipv4_subnet}
IPV6_SUBNET=${ipv6_subnet}
ADD_TOKEN=${add_token}
LOG_LEVEL=info
WHITELIST_FILE=${install_dir}/data/whitelist.json
FIREWALL_SCRIPT=${install_dir}/scripts/firewall.sh
DATA_DIR=${install_dir}/data
EOF
}

write_runner_scripts() {
  cat >"${install_dir}/run-server.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
set -a
. "${install_dir}/mtg-whitelist.env"
set +a
exec /usr/bin/python3 "${install_dir}/app/server.py"
EOF

  cat >"${install_dir}/run-proxy.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
set -a
. "${install_dir}/mtg-whitelist.env"
set +a
exec "${install_dir}/bin/mtg" simple-run --prefer-ip "\${IP_MODE}" "[::]:\${PORT}" "\${SECRET}"
EOF

  chmod +x "${install_dir}/run-server.sh" "${install_dir}/run-proxy.sh"
}

write_systemd_units() {
  cat >/etc/systemd/system/mtg-whitelist-server.service <<EOF
[Unit]
Description=MTG whitelist HTTP service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=${install_dir}/mtg-whitelist.env
ExecStart=${install_dir}/run-server.sh
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

  cat >/etc/systemd/system/mtg-whitelist-proxy.service <<EOF
[Unit]
Description=MTG proxy
After=network-online.target mtg-whitelist-server.service
Wants=network-online.target mtg-whitelist-server.service

[Service]
Type=simple
EnvironmentFile=${install_dir}/mtg-whitelist.env
ExecStartPre=${install_dir}/scripts/firewall.sh reset
ExecStart=${install_dir}/run-proxy.sh
ExecStopPost=${install_dir}/scripts/firewall.sh destroy
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
}

write_openrc_services() {
  cat >/etc/init.d/mtg-whitelist-server <<EOF
#!/sbin/openrc-run
name="MTG whitelist HTTP service"
command="${install_dir}/run-server.sh"
command_background="yes"
pidfile="/run/mtg-whitelist-server.pid"
output_log="/var/log/mtg-whitelist-server.log"
error_log="/var/log/mtg-whitelist-server.log"

depend() {
  need net
}
EOF

  cat >/etc/init.d/mtg-whitelist-proxy <<EOF
#!/sbin/openrc-run
name="MTG proxy"
command="${install_dir}/run-proxy.sh"
command_background="yes"
pidfile="/run/mtg-whitelist-proxy.pid"
output_log="/var/log/mtg-whitelist-proxy.log"
error_log="/var/log/mtg-whitelist-proxy.log"

depend() {
  need net
  need mtg-whitelist-server
}

start_pre() {
  ${install_dir}/scripts/firewall.sh reset
}

stop_post() {
  ${install_dir}/scripts/firewall.sh destroy || true
}
EOF

  chmod +x /etc/init.d/mtg-whitelist-server /etc/init.d/mtg-whitelist-proxy
}

detect_init_system() {
  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    init_system="systemd"
    return
  fi

  if command -v rc-service >/dev/null 2>&1; then
    init_system="openrc"
    return
  fi

  echo "No supported service manager found. Need systemd or OpenRC." >&2
  exit 1
}

start_services() {
  case "$init_system" in
    systemd)
      systemctl daemon-reload
      systemctl enable --now mtg-whitelist-server.service
      systemctl restart mtg-whitelist-proxy.service
      systemctl enable mtg-whitelist-proxy.service >/dev/null
      ;;
    openrc)
      rc-update add mtg-whitelist-server default >/dev/null
      rc-update add mtg-whitelist-proxy default >/dev/null
      rc-service mtg-whitelist-server restart
      rc-service mtg-whitelist-proxy restart
      ;;
  esac
}

print_urls() {
  echo
  echo "MTG tiny install complete."
  if [ -n "$public_ipv4" ]; then
    echo "IPv4-URL: http://${public_ipv4}:${add_port}/add/${add_token}"
  fi
  if [ -n "$public_ipv6" ]; then
    echo "IPv6-URL: http://[${public_ipv6}]:${add_port}/add/${add_token}"
  fi
  echo "Config: ${install_dir}/mtg-whitelist.env"
  if [ "$init_system" = "openrc" ]; then
    echo "Logs: tail -f /var/log/mtg-whitelist-proxy.log /var/log/mtg-whitelist-server.log"
  else
    echo "Logs: journalctl -u mtg-whitelist-proxy -u mtg-whitelist-server -f"
  fi
  echo
}

require_root
validate_port PORT "$port"
validate_port ADD_PORT "$add_port"

if [ "$port" = "$add_port" ]; then
  echo "PORT and ADD_PORT must be different." >&2
  exit 2
fi

if [[ "$add_token" == */* ]]; then
  echo "ADD_TOKEN must not contain '/'." >&2
  exit 2
fi

install_packages

mkdir -p "${install_dir}/bin" "${install_dir}/app" "${install_dir}/scripts" "${install_dir}/data"

arch="$(detect_arch)"
mtg_archive="mtg-${mtg_version}-linux-${arch}.tar.gz"
mtg_url="https://github.com/9seconds/mtg/releases/download/v${mtg_version}/${mtg_archive}"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

curl_cmd -fsSL "$mtg_url" -o "${tmp_dir}/${mtg_archive}"
tar -xzf "${tmp_dir}/${mtg_archive}" -C "$tmp_dir"
mtg_path="$(find "$tmp_dir" -type f -name mtg | head -n 1)"
if [ -z "$mtg_path" ]; then
  echo "Could not find mtg binary in ${mtg_archive}." >&2
  exit 1
fi
install -m 0755 "$mtg_path" "${install_dir}/bin/mtg"

curl_cmd -fsSL "${repo_raw}/app/server.py" -o "${install_dir}/app/server.py"
curl_cmd -fsSL "${repo_raw}/scripts/firewall.sh" -o "${install_dir}/scripts/firewall.sh"
curl_cmd -fsSL "${repo_raw}/scripts/detect-network.sh" -o "${install_dir}/scripts/detect-network.sh"
chmod +x "${install_dir}/scripts/firewall.sh" "${install_dir}/scripts/detect-network.sh"

if [ -z "$secret" ]; then
  secret="$("${install_dir}/bin/mtg" generate-secret "$domain")"
fi
if [ -z "$add_token" ]; then
  add_token="$(random_hex 12)"
fi

selected_ip_mode="$(IP_MODE="$ip_mode" "${install_dir}/scripts/detect-network.sh")"
ip_mode="$selected_ip_mode"
detect_public_addresses

touch "${install_dir}/data/whitelist.json"
if [ ! -s "${install_dir}/data/whitelist.json" ]; then
  printf '{"entries":[]}\n' >"${install_dir}/data/whitelist.json"
fi

write_env
write_runner_scripts
detect_init_system
if [ "$init_system" = "openrc" ]; then
  write_openrc_services
else
  write_systemd_units
fi
start_services

print_urls
