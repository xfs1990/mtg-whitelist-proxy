# mtg-whitelist-proxy

MTG-based MTProto proxy image with a small dynamic whitelist service. Images are
published for `linux/amd64` and `linux/arm64` at
`ghcr.io/xfs1990/mtg-whitelist-proxy`.

This MVP does four things:

- runs MTG on a dual-stack listener, `[::]:PORT`
- chooses MTG outbound IP preference once at container startup
- exposes `GET /add/<token>` to add the caller's IPv4 or IPv6 address to an nftables allowlist
- persists allowlist entries in `/data/whitelist.json`

It only manages its own nftables table, `inet mtproxy_guard`. It never flushes the host ruleset and only drops traffic to the configured MTG port when whitelist mode is enabled.

## Requirements

- Linux host with nftables
- host network mode
- `NET_ADMIN` capability

The one-command installer can install Docker Engine automatically on Debian and
Ubuntu. Other distributions need Docker installed first.

The container modifies the host network namespace, so review the ports before running it on a shared machine.

## Configuration

Copy the example file and edit it:

```bash
cp .env.example .env
```

Generate a secret:

```bash
docker run --rm nineseconds/mtg:2.2.8 generate-secret cloudflare.com
```

Set at least:

```env
SECRET=...
ADD_TOKEN=...
DOMAIN=cloudflare.com
# Optional: force the public domain or IP in generated Telegram links.
PUBLIC_HOST=
```

Available options:

```env
PORT=18188
ADD_PORT=8080

SECRET=
DOMAIN=cloudflare.com
PUBLIC_HOST=

IP_MODE=auto
# auto, prefer-ipv4, prefer-ipv6, only-ipv4, only-ipv6

WHITELIST_MODE=SUBNET
# OFF, IP, SUBNET

IPV4_SUBNET=32
IPV6_SUBNET=64

ADD_TOKEN=
LOG_LEVEL=info
```

Whitelist modes:

- `OFF`: do not restrict MTG traffic
- `IP`: allow exactly the detected IP, IPv4 `/32` or IPv6 `/128`
- `SUBNET`: allow IPv4 `/32` and IPv6 `/64` by default

For mobile networks, `SUBNET` is usually more practical because IPv6 privacy addresses often rotate inside the same `/64`.

## Start

### One-command VPS install

On a Debian or Ubuntu VPS:

```bash
curl -fsSL https://raw.githubusercontent.com/xfs1990/mtg-whitelist-proxy/main/install.sh | sudo bash
```

The installer installs Docker Engine when it is missing, pulls the published
image, generates both `SECRET` and a random `ADD_TOKEN`, writes the deployment to
`/opt/mtg-whitelist-proxy`, and starts the container. Existing configuration is
preserved when the installer is run again.

If the VPS has broken IPv6 routing to package mirrors, force IPv4 for the Docker
installation:

```bash
curl -4 -fsSL https://raw.githubusercontent.com/xfs1990/mtg-whitelist-proxy/main/install.sh \
  | sudo FORCE_IPV4=1 bash
```

To choose a domain or ports:

```bash
curl -fsSL https://raw.githubusercontent.com/xfs1990/mtg-whitelist-proxy/main/install.sh \
  | sudo DOMAIN=example.com PORT=18188 ADD_PORT=8080 bash
```

Review `install.sh` before piping it to a privileged shell on production systems.

### Compose

Copy the repository files to the VPS, then:

```bash
cp .env.example .env
# Edit SECRET and ADD_TOKEN in .env first.
docker compose pull
docker compose up -d
```

### Plain Docker

```bash
docker run -d \
  --name mtg-whitelist-proxy \
  --restart unless-stopped \
  --network host \
  --cap-add NET_ADMIN \
  --env-file .env \
  -v /opt/mtproxy/data:/data \
  ghcr.io/xfs1990/mtg-whitelist-proxy:latest
```

For local development, build with `docker build -t mtg-whitelist-proxy .`.

## Add A Client

From the device that should be allowed:

```text
http://SERVER_IP:8080/add/YOUR_ADD_TOKEN
```

For IPv6:

```text
http://[SERVER_IPV6]:8080/add/YOUR_ADD_TOKEN
```

Example response:

```text
Detected: 2409:8a62:1ea:11d0::1234
Allowed: 2409:8a62:1ea:11d0::/64
Mode: SUBNET
Proxy: [SERVER_IPV6]:18188
Telegram: tg://proxy?server=SERVER_IPV6&port=18188&secret=...
Web: https://t.me/proxy?server=SERVER_IPV6&port=18188&secret=...
```

Open either generated link to import the proxy into Telegram. When `PUBLIC_HOST`
is empty, the service uses the host from the `/add/` request; set it explicitly
when the add endpoint is accessed through a reverse proxy or private hostname.

## Network Mode

`IP_MODE=auto` checks known Telegram DC addresses over IPv4 and IPv6 during container startup only:

- both reachable: `prefer-ipv6`
- only IPv4 reachable: `only-ipv4`
- only IPv6 reachable: `only-ipv6`
- neither reachable: startup fails

No runtime auto-switching is performed in this MVP.

Manual modes are passed through directly to MTG:

- `prefer-ipv4`
- `prefer-ipv6`
- `only-ipv4`
- `only-ipv6`

## Inspect

Check logs:

```bash
docker logs -f mtg-whitelist-proxy
```

Check health:

```bash
curl http://127.0.0.1:8080/healthz
```

Inspect persisted whitelist:

```bash
cat ./data/whitelist.json
```

Inspect nftables table:

```bash
sudo nft list table inet mtproxy_guard
```

## Stop And Clean Up

Stop the container:

```bash
docker compose down
```

Graceful container shutdown removes the project's nftables table. If the process
was force-killed, remove only this project's table with:

```bash
sudo nft delete table inet mtproxy_guard
```

## Image Publishing

Every push to `main` builds and publishes `linux/amd64` and `linux/arm64` images
to GHCR using GitHub Actions and the repository-provided `GITHUB_TOKEN`. No PAT is
stored in the repository.

After the first successful build, set the GHCR package visibility to **Public**
in GitHub package settings so arbitrary VPS hosts can pull it without logging in.
