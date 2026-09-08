#!/usr/bin/env bash
set -euo pipefail

data_dir="${DATA_DIR:-/data}"
port="${ADD_PORT:-}"

if [ -z "$port" ] && [ -s "${data_dir}/generated/add_port" ]; then
  port="$(head -n 1 "${data_dir}/generated/add_port")"
fi

if [ -z "$port" ]; then
  exit 1
fi

curl -fsS "http://127.0.0.1:${port}/healthz" >/dev/null
