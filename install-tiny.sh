#!/usr/bin/env bash
set -euo pipefail

repo_raw="${REPO_RAW:-https://raw.githubusercontent.com/xfs1990/mtg-whitelist-proxy/main}"
vendor_raw="${VENDOR_RAW:-https://raw.githubusercontent.com/xfs1990/mtg-whitelist-proxy/vendor-bin}"
install_dir="${INSTALL_DIR:-/opt/mtg-whitelist-proxy-tiny}"
existing_env="${install_dir}/mtg-whitelist.env"
mtg_version="${MTG_VERSION:-2.2.8}"
mtg_url="${MTG_URL:-}"
mtg_vendor_url="${MTG_VENDOR_URL:-}"
mtg_file="${MTG_FILE:-}"
domain="${DOMAIN:-}"
secret_mode="${SECRET_MODE:-}"
port="${PORT:-}"
add_port="${ADD_PORT:-}"
ip_mode="${IP_MODE:-}"
whitelist_mode="${WHITELIST_MODE:-}"
ipv4_subnet="${IPV4_SUBNET:-}"
ipv6_subnet="${IPV6_SUBNET:-}"
add_token="${ADD_TOKEN:-}"
secret="${SECRET:-}"
provided_secret="${SECRET:-}"
public_host="${PUBLIC_HOST:-}"
public_ipv4="${PUBLIC_IPV4:-}"
public_ipv6="${PUBLIC_IPV6:-}"
mtg_doh_ip="${MTG_DOH_IP:-}"
force_ipv4="${FORCE_IPV4:-0}"
force_ipv6="${FORCE_IPV6:-0}"
apt_lock_timeout="${APT_LOCK_TIMEOUT:-120}"
cache_bust="${CACHE_BUST:-$(date +%s)}"
init_system=""

apt_cmd() {
  local deadline
  local status

  deadline=$((SECONDS + apt_lock_timeout))

  while true; do
    set +e
    if [ "$force_ipv4" = "1" ]; then
      apt-get -o Acquire::ForceIPv4=true "$@"
    elif [ "$force_ipv6" = "1" ]; then
      apt-get -o Acquire::ForceIPv6=true "$@"
    else
      apt-get "$@"
    fi
    status="$?"
    set -e

    if [ "$status" -eq 0 ]; then
      return 0
    fi

    if [ "$status" -ne 100 ] || [ "$SECONDS" -ge "$deadline" ]; then
      return "$status"
    fi

    echo "apt 正在被其他进程占用，等待 5 秒后重试..." >&2
    sleep 5
  done
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
  elif [ "$force_ipv6" = "1" ]; then
    curl -6 "$@"
  else
    curl "$@"
  fi
}

raw_url() {
  local path="$1"
  local sep="?"

  if [[ "$repo_raw" == *\?* ]]; then
    sep="&"
  fi

  printf '%s/%s%s_cb=%s\n' "$repo_raw" "$path" "$sep" "$cache_bust"
}

random_hex() {
  local bytes="$1"
  LC_ALL=C od -An -N"$bytes" -tx1 /dev/urandom | tr -d ' \n'
}

is_simple_secret() {
  [[ "$1" =~ ^[0-9a-fA-F]{32}$ ]]
}

existing_value() {
  local name="$1"
  if [ -f "$existing_env" ]; then
    awk -F= -v key="$name" '$1 == key { print substr($0, length(key) + 2); exit }' "$existing_env"
  fi
}

init_value() {
  local name="$1"
  local current="$2"
  local fallback="$3"
  local value

  if [ -n "$current" ]; then
    value="$current"
  else
    value="$(existing_value "$name")"
    if [ -z "$value" ]; then
      value="$fallback"
    fi
  fi

  printf '%s\n' "$value"
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

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "请使用 root 运行安装脚本。" >&2
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
      echo "不支持当前 CPU 架构：$(uname -m)" >&2
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
    public_ipv4="$(ip -o -4 addr show scope global 2>/dev/null | awk 'NR == 1 { split($4, a, "/"); value = a[1] } END { if (value) print value }')"
  fi
  if [ -z "$public_ipv6" ]; then
    public_ipv6="$(ip -o -6 addr show scope global 2>/dev/null | awk 'NR == 1 { split($4, a, "/"); value = a[1] } END { if (value) print value }')"
  fi
}

validate_port() {
  local name="$1"
  local value="$2"
  if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt 1 ] || [ "$value" -gt 65535 ]; then
    echo "$name 必须是 1 到 65535 之间的端口号。" >&2
    exit 2
  fi
}

write_env() {
  umask 077
  cat >"${install_dir}/mtg-whitelist.env" <<EOF
PORT=${port}
ADD_PORT=${add_port}
SECRET=${secret}
SECRET_MODE=${secret_mode}
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
MTG_DOH_IP=${mtg_doh_ip}
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
args=(simple-run --prefer-ip "\${IP_MODE}")
if [ "\${LOG_LEVEL:-info}" = "debug" ]; then
  args=(simple-run --debug --prefer-ip "\${IP_MODE}")
fi
if [ "\${SECRET_MODE:-tls}" = "tls" ]; then
  args+=(--doh-ip "\${MTG_DOH_IP}")
fi
args+=("[::]:\${PORT}" "\${SECRET}")
exec "${install_dir}/bin/mtg" "\${args[@]}"
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

  echo "未找到支持的服务管理器，需要 systemd 或 OpenRC。" >&2
  exit 1
}

start_services() {
  case "$init_system" in
    systemd)
      systemctl daemon-reload
      systemctl enable mtg-whitelist-server.service >/dev/null
      systemctl restart mtg-whitelist-server.service
      systemctl restart mtg-whitelist-proxy.service
      systemctl enable mtg-whitelist-proxy.service >/dev/null
      ;;
    openrc)
      rc-update add mtg-whitelist-server default >/dev/null
      rc-update add mtg-whitelist-proxy default >/dev/null
      rc-service mtg-whitelist-proxy stop >/dev/null 2>&1 || true
      rc-service mtg-whitelist-server stop >/dev/null 2>&1 || true
      rc-service mtg-whitelist-server start || true
      rc-service mtg-whitelist-proxy start || true
      if ! rc-service mtg-whitelist-server status >/dev/null 2>&1; then
        echo "白名单 HTTP 服务未能启动。" >&2
        exit 1
      fi
      if ! rc-service mtg-whitelist-proxy status >/dev/null 2>&1; then
        echo "MTG 代理服务未能启动。" >&2
        exit 1
      fi
      ;;
  esac
}

select_doh_ip() {
  local candidates
  local candidate
  local url

  if [ "$secret_mode" != "tls" ]; then
    mtg_doh_ip=""
    return
  fi

  if [ -n "$mtg_doh_ip" ]; then
    return
  fi

  case "$ip_mode" in
    only-ipv6|prefer-ipv6)
      candidates="2606:4700:4700::1111 2001:4860:4860::8888 1.1.1.1 8.8.8.8"
      ;;
    *)
      candidates="1.1.1.1 8.8.8.8 2606:4700:4700::1111 2001:4860:4860::8888"
      ;;
  esac

  for candidate in $candidates; do
    if [[ "$candidate" == *:* ]]; then
      url="https://[${candidate}]/dns-query"
    else
      url="https://${candidate}/dns-query"
    fi

    if curl_cmd -sS -o /dev/null --connect-timeout 3 --max-time 5 "$url" >/dev/null 2>&1; then
      mtg_doh_ip="$candidate"
      return
    fi
  done

  echo "无法提前确认可用 DoH，继续使用 MTG 默认值 1.1.1.1。" >&2
  mtg_doh_ip="1.1.1.1"
}

print_urls() {
  echo
  echo "MTG tiny 版安装完成。"
  echo "代理端口：${port}"
  echo "出站模式：${ip_mode}"
  echo "secret 模式：${secret_mode}"
  if [ "$secret_mode" = "tls" ]; then
    echo "DoH 解析地址：${mtg_doh_ip}"
  else
    echo "DoH 解析地址：未使用"
  fi
  if [ -n "$public_ipv4" ]; then
    echo "IPv4-URL: http://${public_ipv4}:${add_port}/add/${add_token}"
  fi
  if [ -n "$public_ipv6" ]; then
    echo "IPv6-URL: http://[${public_ipv6}]:${add_port}/add/${add_token}"
  fi
  echo "配置文件：${install_dir}/mtg-whitelist.env"
  if [ "$init_system" = "openrc" ]; then
    echo "日志：tail -f /var/log/mtg-whitelist-proxy.log /var/log/mtg-whitelist-server.log"
  else
    echo "日志：journalctl -u mtg-whitelist-proxy -u mtg-whitelist-server -f"
  fi
  echo
}

require_root
if [ "$force_ipv4" = "1" ] && [ "$force_ipv6" = "1" ]; then
  echo "FORCE_IPV4 和 FORCE_IPV6 不能同时启用。" >&2
  exit 2
fi
install_packages

domain="$(init_value DOMAIN "$domain" cloudflare.com)"
secret_mode="$(init_value SECRET_MODE "$secret_mode" tls)"
secret_mode="${secret_mode,,}"
port="$(init_value PORT "$port" "$(random_port 20000 20000)")"
add_port="$(init_value ADD_PORT "$add_port" "$(random_port 10000 10000)")"
ip_mode="${ip_mode:-auto}"
whitelist_mode="$(init_value WHITELIST_MODE "$whitelist_mode" SUBNET)"
ipv4_subnet="$(init_value IPV4_SUBNET "$ipv4_subnet" 32)"
ipv6_subnet="$(init_value IPV6_SUBNET "$ipv6_subnet" 64)"
add_token="$(init_value ADD_TOKEN "$add_token" "$(random_hex 12)")"
public_host="$(init_value PUBLIC_HOST "$public_host" "")"
public_ipv4="$(init_value PUBLIC_IPV4 "$public_ipv4" "")"
public_ipv6="$(init_value PUBLIC_IPV6 "$public_ipv6" "")"

case "$secret_mode" in
  tls|simple) ;;
  *)
    echo "SECRET_MODE 只能是 tls 或 simple。" >&2
    exit 2
    ;;
esac

existing_secret_mode="$(existing_value SECRET_MODE)"
existing_secret="$(existing_value SECRET)"
if [ -n "$provided_secret" ]; then
  secret="$provided_secret"
elif [ -n "$existing_secret" ] && { [ -z "$existing_secret_mode" ] || [ "$existing_secret_mode" = "$secret_mode" ]; }; then
  secret="$existing_secret"
else
  secret=""
fi
if [ "$secret_mode" = "simple" ] && [ -n "$secret" ] && ! is_simple_secret "$secret"; then
  echo "检测到已保存的 secret 不是普通模式格式，重新生成普通 MTG 密钥。" >&2
  secret=""
fi

validate_port PORT "$port"
validate_port ADD_PORT "$add_port"

if [ "$port" = "$add_port" ]; then
  if [ -z "${ADD_PORT:-}" ]; then
    add_port="$(random_port 10000 10000)"
    validate_port ADD_PORT "$add_port"
  fi
fi

if [ "$port" = "$add_port" ]; then
  echo "PORT 和 ADD_PORT 不能相同。" >&2
  exit 2
fi

if [[ "$add_token" == */* ]]; then
  echo "ADD_TOKEN 不能包含 /。" >&2
  exit 2
fi

mkdir -p "${install_dir}/bin" "${install_dir}/app" "${install_dir}/scripts" "${install_dir}/data"

arch="$(detect_arch)"
mtg_archive="mtg-${mtg_version}-linux-${arch}.tar.gz"
if [ -z "$mtg_url" ]; then
  mtg_url="https://github.com/9seconds/mtg/releases/download/v${mtg_version}/${mtg_archive}"
fi
if [ -z "$mtg_vendor_url" ]; then
  mtg_vendor_url="${vendor_raw}/vendor/${mtg_archive}"
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

if [ -n "$mtg_file" ]; then
  if [ ! -f "$mtg_file" ]; then
    echo "MTG_FILE 指定的文件不存在：${mtg_file}" >&2
    exit 1
  fi
  cp "$mtg_file" "${tmp_dir}/${mtg_archive}"
else
  if ! curl_cmd -fsSL "$mtg_url" -o "${tmp_dir}/${mtg_archive}"; then
    echo "官方下载 MTG 失败，尝试备用 raw 包：${mtg_vendor_url}" >&2
    if curl_cmd -fsSL "$mtg_vendor_url" -o "${tmp_dir}/${mtg_archive}"; then
      echo "已从备用 raw 包下载 MTG。" >&2
    elif [ -x "${install_dir}/bin/mtg" ]; then
      echo "下载 MTG 失败，继续复用已安装的 MTG：${install_dir}/bin/mtg" >&2
      mtg_path="${install_dir}/bin/mtg"
    else
      echo "下载 MTG 失败：${mtg_url}" >&2
      echo "备用 raw 包也不可用：${mtg_vendor_url}" >&2
      echo "如果这台机器不能访问 github.com，可以设置 MTG_URL 指向可访问的镜像地址，或先上传压缩包后设置 MTG_FILE=/path/to/${mtg_archive}。" >&2
      exit 1
    fi
  fi
fi
if [ -z "${mtg_path:-}" ]; then
  tar -xzf "${tmp_dir}/${mtg_archive}" -C "$tmp_dir"
  mtg_path="$(find "$tmp_dir" -type f -name mtg -print -quit)"
  if [ -z "$mtg_path" ]; then
    echo "在 ${mtg_archive} 中没有找到 mtg 二进制文件。" >&2
    exit 1
  fi
  install -m 0755 "$mtg_path" "${install_dir}/bin/mtg"
fi

curl_cmd -fsSL "$(raw_url app/server.py)" -o "${install_dir}/app/server.py"
curl_cmd -fsSL "$(raw_url scripts/firewall.sh)" -o "${install_dir}/scripts/firewall.sh"
curl_cmd -fsSL "$(raw_url scripts/detect-network.sh)" -o "${install_dir}/scripts/detect-network.sh"
chmod +x "${install_dir}/scripts/firewall.sh" "${install_dir}/scripts/detect-network.sh"
echo "已刷新 tiny 服务文件。"

if [ -z "$secret" ]; then
  if [ "$secret_mode" = "tls" ]; then
    secret="$("${install_dir}/bin/mtg" generate-secret "$domain")"
  else
    secret="$(random_hex 16)"
  fi
fi
selected_ip_mode="$(IP_MODE="$ip_mode" "${install_dir}/scripts/detect-network.sh")"
ip_mode="$selected_ip_mode"
select_doh_ip
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
