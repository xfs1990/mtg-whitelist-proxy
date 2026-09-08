#!/usr/bin/env python3
import ipaddress
import hmac
import html
import json
import os
import socket
import subprocess
import tempfile
import threading
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlencode, urlparse


ADD_PORT = int(os.getenv("ADD_PORT", "8080"))
ADD_TOKEN = os.getenv("ADD_TOKEN", "")
PORT = int(os.getenv("PORT", "18188"))
SECRET = os.getenv("SECRET", "")
PUBLIC_HOST = os.getenv("PUBLIC_HOST", "").strip()
PUBLIC_IPV4 = os.getenv("PUBLIC_IPV4", "").strip()
PUBLIC_IPV6 = os.getenv("PUBLIC_IPV6", "").strip()
WHITELIST_MODE = os.getenv("WHITELIST_MODE", "SUBNET").upper()
IPV4_SUBNET = int(os.getenv("IPV4_SUBNET", "32"))
IPV6_SUBNET = int(os.getenv("IPV6_SUBNET", "64"))
DATA_FILE = Path(os.getenv("WHITELIST_FILE", "/data/whitelist.json"))
FIREWALL_SCRIPT = os.getenv("FIREWALL_SCRIPT", "/usr/local/bin/firewall.sh")
TRUST_PROXY_HEADERS = os.getenv("TRUST_PROXY_HEADERS", "false").lower() == "true"

lock = threading.Lock()


class DualStackServer(ThreadingHTTPServer):
    address_family = socket.AF_INET6

    def server_bind(self):
        try:
            self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        except OSError:
            pass
        super().server_bind()


def load_data():
    try:
        with DATA_FILE.open("r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (FileNotFoundError, json.JSONDecodeError):
        data = {"entries": []}

    if not isinstance(data, dict) or not isinstance(data.get("entries"), list):
        return {"entries": []}
    return data


def save_data(data):
    DATA_FILE.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=".whitelist.", suffix=".json", dir=str(DATA_FILE.parent))
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2, sort_keys=True)
        fh.write("\n")
    os.replace(tmp_name, DATA_FILE)


def client_ip(handler):
    raw = handler.client_address[0]
    if TRUST_PROXY_HEADERS:
        forwarded = handler.headers.get("X-Forwarded-For", "").split(",")[0].strip()
        if forwarded:
            raw = forwarded

    ip = ipaddress.ip_address(raw)
    if isinstance(ip, ipaddress.IPv6Address) and ip.ipv4_mapped:
        return ip.ipv4_mapped
    return ip


def allowed_network(ip):
    if WHITELIST_MODE == "IP":
        prefix = 32 if ip.version == 4 else 128
    elif WHITELIST_MODE == "SUBNET":
        prefix = IPV4_SUBNET if ip.version == 4 else IPV6_SUBNET
    elif WHITELIST_MODE == "OFF":
        prefix = 32 if ip.version == 4 else 128
    else:
        raise ValueError(f"Invalid WHITELIST_MODE: {WHITELIST_MODE}")

    return ipaddress.ip_network(f"{ip}/{prefix}", strict=False)


def proxy_host(host_header):
    if PUBLIC_HOST:
        return PUBLIC_HOST.strip("[]")
    if host_header.startswith("["):
        closing_bracket = host_header.find("]")
        if closing_bracket > 0:
            return host_header[1:closing_bracket]
    return host_header.split(":", 1)[0] if host_header else "<server>"


def add_url(host, token):
    display_host = f"[{host}]" if ":" in host else host
    return f"http://{display_host}:{ADD_PORT}/add/{token}"


def render_add_page(ip, network, host, proxy_query):
    display_host = f"[{host}]" if ":" in host else host
    proxy_url = f"{display_host}:{PORT}"
    tg_url = f"tg://proxy?{proxy_query}"
    web_url = f"https://t.me/proxy?{proxy_query}"
    current_add_url = add_url(host, ADD_TOKEN)
    ipv4_add_url = add_url(PUBLIC_IPV4, ADD_TOKEN) if PUBLIC_IPV4 else ""
    ipv6_add_url = add_url(PUBLIC_IPV6, ADD_TOKEN) if PUBLIC_IPV6 else ""

    values = {
        "ip": html.escape(str(ip)),
        "network": html.escape(str(network)),
        "mode": html.escape(WHITELIST_MODE),
        "proxy_url": html.escape(proxy_url),
        "tg_url": html.escape(tg_url, quote=True),
        "tg_text": html.escape(tg_url),
        "web_url": html.escape(web_url, quote=True),
        "web_text": html.escape(web_url),
        "add_url": html.escape(current_add_url, quote=True),
        "add_text": html.escape(current_add_url),
        "ipv4_add_url": html.escape(ipv4_add_url, quote=True),
        "ipv4_add_text": html.escape(ipv4_add_url),
        "ipv6_add_url": html.escape(ipv6_add_url, quote=True),
        "ipv6_add_text": html.escape(ipv6_add_url),
    }

    add_links = []
    if ipv4_add_url:
        add_links.append(
            f"""<div class="linkbox">
        <span class="label">IPv4-URL</span>
        <a href="{values["ipv4_add_url"]}">{values["ipv4_add_text"]}</a>
      </div>"""
        )
    if ipv6_add_url:
        add_links.append(
            f"""<div class="linkbox">
        <span class="label">IPv6-URL</span>
        <a href="{values["ipv6_add_url"]}">{values["ipv6_add_text"]}</a>
      </div>"""
        )
    add_links_html = "\n\n      ".join(add_links)

    return f"""<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>MTG 代理已就绪</title>
  <style>
    :root {{
      color-scheme: light dark;
      --bg: #f6f7f9;
      --panel: #ffffff;
      --text: #14171f;
      --muted: #626a78;
      --line: #dfe3ea;
      --accent: #0877ff;
      --accent-text: #ffffff;
      --ok: #0f8f5f;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }}
    @media (prefers-color-scheme: dark) {{
      :root {{
        --bg: #111318;
        --panel: #191c23;
        --text: #f0f3f7;
        --muted: #a4abba;
        --line: #313743;
        --accent: #4c9dff;
        --accent-text: #07111f;
      }}
    }}
    * {{ box-sizing: border-box; }}
    body {{
      margin: 0;
      background: var(--bg);
      color: var(--text);
      line-height: 1.45;
    }}
    main {{
      width: min(760px, 100%);
      margin: 0 auto;
      padding: 24px 16px 40px;
    }}
    .panel {{
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 8px;
      padding: 18px;
    }}
    h1 {{
      margin: 0 0 6px;
      font-size: 24px;
      font-weight: 700;
      letter-spacing: 0;
    }}
    .status {{
      margin: 0 0 18px;
      color: var(--ok);
      font-weight: 650;
    }}
    .grid {{
      display: grid;
      gap: 10px;
      margin: 16px 0 20px;
    }}
    @media (min-width: 680px) {{
      .grid {{ grid-template-columns: repeat(3, 1fr); }}
    }}
    .metric {{
      border: 1px solid var(--line);
      border-radius: 8px;
      padding: 12px;
      min-width: 0;
    }}
    .label {{
      display: block;
      color: var(--muted);
      font-size: 12px;
      margin-bottom: 4px;
    }}
    .value {{
      overflow-wrap: anywhere;
      font-size: 14px;
      font-weight: 650;
    }}
    .actions {{
      display: grid;
      gap: 10px;
      margin: 18px 0;
    }}
    @media (min-width: 520px) {{
      .actions {{ grid-template-columns: repeat(2, 1fr); }}
    }}
    a.button {{
      display: flex;
      align-items: center;
      justify-content: center;
      min-height: 48px;
      padding: 12px 14px;
      border-radius: 8px;
      background: var(--accent);
      color: var(--accent-text);
      text-decoration: none;
      font-weight: 700;
      text-align: center;
    }}
    a.secondary {{
      background: transparent;
      color: var(--accent);
      border: 1px solid var(--accent);
    }}
    .linkbox {{
      margin-top: 12px;
      border: 1px solid var(--line);
      border-radius: 8px;
      padding: 12px;
    }}
    .linkbox a {{
      color: var(--accent);
      overflow-wrap: anywhere;
      word-break: break-word;
    }}
  </style>
</head>
<body>
  <main>
    <section class="panel">
      <h1>MTG 代理已就绪</h1>
      <p class="status">白名单已更新，可以导入 Telegram。</p>

      <div class="grid">
        <div class="metric">
          <span class="label">识别到的 IP</span>
          <span class="value">{values["ip"]}</span>
        </div>
        <div class="metric">
          <span class="label">已放行范围</span>
          <span class="value">{values["network"]}</span>
        </div>
        <div class="metric">
          <span class="label">代理地址</span>
          <span class="value">{values["proxy_url"]}</span>
        </div>
      </div>

      <div class="actions">
        <a class="button" href="{values["tg_url"]}">打开 Telegram</a>
        <a class="button secondary" href="{values["web_url"]}">打开 t.me 链接</a>
      </div>

      <div class="linkbox">
        <span class="label">Telegram 导入链接</span>
        <a href="{values["tg_url"]}">{values["tg_text"]}</a>
      </div>

      <div class="linkbox">
        <span class="label">网页导入链接</span>
        <a href="{values["web_url"]}">{values["web_text"]}</a>
      </div>

      {add_links_html}

      <div class="linkbox">
        <span class="label">当前白名单链接</span>
        <a href="{values["add_url"]}">{values["add_text"]}</a>
      </div>
    </section>
  </main>
</body>
</html>
"""


def persist_and_apply(ip, network):
    now = datetime.now(timezone.utc).isoformat()
    with lock:
        data = load_data()
        entries = data.setdefault("entries", [])
        network_text = str(network)
        found = False
        for item in entries:
            if item.get("network") == network_text:
                item["last_seen_ip"] = str(ip)
                item["updated_at"] = now
                found = True
                break

        if not found:
            entries.append(
                {
                    "network": network_text,
                    "family": f"ipv{ip.version}",
                    "first_seen_ip": str(ip),
                    "last_seen_ip": str(ip),
                    "created_at": now,
                    "updated_at": now,
                }
            )
        save_data(data)

    if WHITELIST_MODE != "OFF":
        subprocess.run([FIREWALL_SCRIPT, "add", str(network)], check=True)


class Handler(BaseHTTPRequestHandler):
    server_version = "mtg-whitelist/0.1"

    def log_message(self, fmt, *args):
        print(f"{self.address_string()} - {fmt % args}", flush=True)

    def send_text(self, status, body):
        body_bytes = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body_bytes)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body_bytes)

    def send_html(self, status, body):
        body_bytes = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body_bytes)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body_bytes)

    def log_request(self, code="-", size="-"):
        path = urlparse(self.path).path
        if path.startswith("/add/"):
            path = "/add/<redacted>"
        print(
            f"{self.client_address[0]} - {self.command} {path} {code} {size}",
            flush=True,
        )

    def do_GET(self):
        parsed = urlparse(self.path)
        parts = [unquote(part) for part in parsed.path.split("/") if part]

        if parsed.path == "/healthz":
            self.send_text(200, "ok\n")
            return

        if len(parts) != 2 or parts[0] != "add":
            self.send_text(404, "未找到。请使用 /add/<token>\n")
            return

        if not ADD_TOKEN or not hmac.compare_digest(parts[1], ADD_TOKEN):
            self.send_text(403, "访问令牌错误。\n")
            return

        try:
            ip = client_ip(self)
            network = allowed_network(ip)
            persist_and_apply(ip, network)
        except Exception as exc:
            self.send_text(500, f"白名单更新失败：{exc}\n")
            return

        host = proxy_host(self.headers.get("Host", ""))
        proxy_query = urlencode(
            {"server": host, "port": str(PORT), "secret": SECRET}
        )

        self.send_html(
            200,
            render_add_page(ip, network, host, proxy_query),
        )


def main():
    DATA_FILE.parent.mkdir(parents=True, exist_ok=True)
    if not DATA_FILE.exists():
        save_data({"entries": []})
    server = DualStackServer(("::", ADD_PORT), Handler)
    print(f"白名单服务监听地址：[::]:{ADD_PORT}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
