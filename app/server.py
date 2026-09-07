#!/usr/bin/env python3
import ipaddress
import hmac
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
WHITELIST_MODE = os.getenv("WHITELIST_MODE", "SUBNET").upper()
IPV4_SUBNET = int(os.getenv("IPV4_SUBNET", "32"))
IPV6_SUBNET = int(os.getenv("IPV6_SUBNET", "64"))
DATA_FILE = Path(os.getenv("WHITELIST_FILE", "/data/whitelist.json"))
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
        subprocess.run(["/usr/local/bin/firewall.sh", "add", str(network)], check=True)


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
            self.send_text(404, "Not found. Use /add/<token>\n")
            return

        if not ADD_TOKEN or not hmac.compare_digest(parts[1], ADD_TOKEN):
            self.send_text(403, "Forbidden\n")
            return

        try:
            ip = client_ip(self)
            network = allowed_network(ip)
            persist_and_apply(ip, network)
        except Exception as exc:
            self.send_text(500, f"Failed to update whitelist: {exc}\n")
            return

        host = proxy_host(self.headers.get("Host", ""))
        display_host = f"[{host}]" if ":" in host else host
        proxy_query = urlencode(
            {"server": host, "port": str(PORT), "secret": SECRET}
        )

        self.send_text(
            200,
            "\n".join(
                [
                    f"Detected: {ip}",
                    f"Allowed: {network}",
                    f"Mode: {WHITELIST_MODE}",
                    f"Proxy: {display_host}:{PORT}",
                    f"Telegram: tg://proxy?{proxy_query}",
                    f"Web: https://t.me/proxy?{proxy_query}",
                    "",
                ]
            ),
        )


def main():
    DATA_FILE.parent.mkdir(parents=True, exist_ok=True)
    if not DATA_FILE.exists():
        save_data({"entries": []})
    server = DualStackServer(("::", ADD_PORT), Handler)
    print(f"Whitelist server listening on [::]:{ADD_PORT}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
