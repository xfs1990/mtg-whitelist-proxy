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
- Docker
- host network mode
- `NET_ADMIN` capability

The container modifies the host network namespace, so review the ports before running it on a shared machine.

## Configuration

All runtime values are optional. When `PORT`, `ADD_PORT`, `SECRET`, or
`ADD_TOKEN` are empty, the container generates them once and stores them under
`/data/generated/`. Later restarts with the same volume keep the same values.

Available overrides:

```env
PORT=
ADD_PORT=

SECRET=
DOMAIN=cloudflare.com
PUBLIC_HOST=
PUBLIC_IPV4=
PUBLIC_IPV6=

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

### One-line Docker Start

On a VPS that already has Docker:

```bash
docker run -d --name mtg-whitelist-proxy --restart unless-stopped --network host --cap-add NET_ADMIN -v /opt/mtg-whitelist-proxy/data:/data ghcr.io/xfs1990/mtg-whitelist-proxy:latest
```

To pin values yourself, add only the overrides you need:

```bash
docker run -d --name mtg-whitelist-proxy --restart unless-stopped --network host --cap-add NET_ADMIN -v /opt/mtg-whitelist-proxy/data:/data -e ADD_TOKEN='Pass' -e PORT=18188 -e ADD_PORT=8080 -e DOMAIN='cloudflare.com' -e IP_MODE=only-ipv6 ghcr.io/xfs1990/mtg-whitelist-proxy:latest
```

Show the add URLs:

```bash
docker logs mtg-whitelist-proxy --tail=80
```

The logs include the reachable addresses detected on the VPS:

```text
IPv4-URL: http://IPv4:ADD_PORT/add/password
IPv6-URL: http://[IPv6]:ADD_PORT/add/password
```

Open one URL from your phone. The page updates the whitelist and shows clickable
Telegram links.

### Optional Installer

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

If Docker's official package repository is unreachable from the VPS, use the
distribution Docker packages instead:

```bash
curl -fsSL https://raw.githubusercontent.com/xfs1990/mtg-whitelist-proxy/main/install.sh \
  | sudo DOCKER_INSTALL_SOURCE=distro bash
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
http://SERVER_IP:ADD_PORT/add/YOUR_ADD_TOKEN
```

For IPv6:

```text
http://[SERVER_IPV6]:ADD_PORT/add/YOUR_ADD_TOKEN
```

The add page is HTML and mobile friendly. It shows the detected IP, allowed
network, clickable `tg://` and `https://t.me/proxy?...` links, plus IPv4 and IPv6
add URLs when the VPS has those addresses. When `PUBLIC_HOST` is empty, the
service uses the host from the `/add/` request; set it explicitly when the add
endpoint is accessed through a reverse proxy or private hostname.

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
port="$(cat /opt/mtg-whitelist-proxy/data/generated/add_port)"
curl "http://127.0.0.1:${port}/healthz"
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
