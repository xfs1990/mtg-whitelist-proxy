#!/bin/sh
set -eu

repo_raw="${REPO_RAW:-https://raw.githubusercontent.com/xfs1990/mtg-whitelist-proxy/main}"

if [ "$(id -u)" -ne 0 ]; then
  echo "请使用 root 运行 bootstrap。" >&2
  exit 1
fi

if command -v apk >/dev/null 2>&1; then
  apk update
  apk add bash curl ca-certificates
elif command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y bash curl ca-certificates
else
  echo "不支持当前包管理器，请先安装 bash 和 curl。" >&2
  exit 1
fi

tmp_file="$(mktemp)"
trap 'rm -f "$tmp_file"' EXIT

if command -v curl >/dev/null 2>&1; then
  curl -fsSL "${repo_raw}/install-tiny.sh" -o "$tmp_file"
elif command -v wget >/dev/null 2>&1; then
  wget -qO "$tmp_file" "${repo_raw}/install-tiny.sh"
else
  echo "需要 curl 或 wget 来下载安装脚本。" >&2
  exit 1
fi

exec bash "$tmp_file"
