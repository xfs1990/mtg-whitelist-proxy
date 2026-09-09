# mtg-whitelist-proxy

基于 MTG 的 Telegram MTProto Proxy，带动态白名单页面。

手机打开安装输出里的 `IPv4-URL` 或 `IPv6-URL` 后，会自动放行当前 IP，并显示可点击的 Telegram 导入链接。

项目只维护自己的 nftables 表 `inet mtproxy_guard`，不会清空系统防火墙。

## 选择用法

| 场景 | 推荐方式 |
| --- | --- |
| 正常 VPS，已经有 Docker | Docker 标准命令 |
| 自己用，想一行启动并直接看到地址 | Docker 懒人脚本 |
| 低配小鸡、内存很小、Docker 太重 | tiny 版 |
| NAT 小鸡、只有面板端口转发 | tiny 版并手动指定端口 |

默认会自动生成：

- MTG 代理端口
- 白名单页面端口
- `/add/<token>` 密码
- MTG secret
- IPv4 / IPv6 出站模式

只有 NAT 或端口受限机器需要手动指定端口。

## Docker 标准命令

适合正常 VPS。机器上需要已经安装 Docker。

```bash
docker pull ghcr.io/xfs1990/mtg-whitelist-proxy:latest

docker run -d \
  --name mtg-whitelist-proxy \
  --restart unless-stopped \
  --network host \
  --cap-add NET_ADMIN \
  -v /opt/mtg-whitelist-proxy/data:/data \
  ghcr.io/xfs1990/mtg-whitelist-proxy:latest
```

Docker 会返回容器 ID。查看白名单地址：

```bash
docker logs mtg-whitelist-proxy --tail=100
```

日志里会显示：

```text
IPv4-URL: http://IPv4:端口/add/密码
IPv6-URL: http://[IPv6]:端口/add/密码
```

然后用手机打开其中一个地址。

## Docker 懒人脚本

适合自己用：一行启动 Docker 容器，并直接打印白名单地址。

```bash
curl -fsSL https://raw.githubusercontent.com/xfs1990/mtg-whitelist-proxy/main/run-docker.sh | bash
```

重建已有容器：

```bash
curl -fsSL https://raw.githubusercontent.com/xfs1990/mtg-whitelist-proxy/main/run-docker.sh | RECREATE=1 bash
```

## tiny 版

适合低配机器，不需要 Docker。IPv4-only、IPv6-only、双栈机器都会自动检测。

```bash
curl -fsSL https://raw.githubusercontent.com/xfs1990/mtg-whitelist-proxy/main/install-tiny.sh | bash
```

脚本会下载 MTG 单文件，并用 systemd 或 OpenRC 启动：

```text
mtg-whitelist-proxy
mtg-whitelist-server
```

Alpine 极简系统如果没有 `curl` / `bash`，用：

```sh
wget -qO- https://raw.githubusercontent.com/xfs1990/mtg-whitelist-proxy/main/bootstrap-tiny.sh | sh
```

## NAT 小鸡

NAT 机器通常只有一段外部端口，服务无法自己猜到公网端口，所以必须手动指定。

从服务商面板分配的端口里挑两个：

```text
PROXY_PORT = MTG 代理端口
ADD_PORT   = 白名单页面端口
```

面板端口转发：

```text
YOUR_PUBLIC_IP:PROXY_PORT -> YOUR_PRIVATE_IP:PROXY_PORT
YOUR_PUBLIC_IP:ADD_PORT   -> YOUR_PRIVATE_IP:ADD_PORT
```

安装：

```bash
curl -fsSL https://raw.githubusercontent.com/xfs1990/mtg-whitelist-proxy/main/install-tiny.sh | PUBLIC_IPV4=YOUR_PUBLIC_IP PORT=PROXY_PORT ADD_PORT=ADD_PORT bash
```

Alpine 极简系统：

```sh
wget -qO- https://raw.githubusercontent.com/xfs1990/mtg-whitelist-proxy/main/bootstrap-tiny.sh | PUBLIC_IPV4=YOUR_PUBLIC_IP PORT=PROXY_PORT ADD_PORT=ADD_PORT sh
```

手机打开输出的 `IPv4-URL`，页面里的 Telegram 代理端口会是 `PROXY_PORT`。

## 特殊网络

如果是 IPv6-only 机器，可以先强制安装过程走 IPv6：

```bash
curl -fsSL https://raw.githubusercontent.com/xfs1990/mtg-whitelist-proxy/main/install-tiny.sh | FORCE_IPV6=1 bash
```

如果安装脚本能下载，但 MTG 二进制下载失败，说明这台机器到 GitHub Release 不通。脚本会自动尝试从 `vendor-bin` 分支下载：

```text
https://raw.githubusercontent.com/xfs1990/mtg-whitelist-proxy/vendor-bin/vendor/mtg-版本-linux-架构.tar.gz
```

如果还不通，可以换一个可访问的下载地址：

```bash
curl -fsSL https://raw.githubusercontent.com/xfs1990/mtg-whitelist-proxy/main/install-tiny.sh | MTG_URL='https://example.com/mtg-linux.tar.gz' bash
```

也可以先把 MTG 压缩包传到机器上，再离线安装：

```bash
curl -fsSL https://raw.githubusercontent.com/xfs1990/mtg-whitelist-proxy/main/install-tiny.sh | MTG_FILE='/root/mtg-linux.tar.gz' bash
```

如果 Debian / Ubuntu 提示 apt 被其他进程占用，通常是系统后台更新还没结束。脚本默认会等待最多 120 秒，也可以自己调长：

```bash
curl -fsSL https://raw.githubusercontent.com/xfs1990/mtg-whitelist-proxy/main/install-tiny.sh | APT_LOCK_TIMEOUT=300 bash
```

如果页面能打开，但日志里反复出现 `cannot dial to the fronting domain`，通常是 MTG 默认 DoH `1.1.1.1` 不通。新版会自动尝试 Cloudflare / Google 的 DoH IP，也可以手动指定：

```bash
curl -fsSL https://raw.githubusercontent.com/xfs1990/mtg-whitelist-proxy/main/install-tiny.sh | MTG_DOH_IP=2001:4860:4860::8888 bash
```

如果这台 VPS 到伪装域名或 DoH 链路一直不稳定，可以切到普通 secret 模式：

```bash
curl -fsSL https://raw.githubusercontent.com/xfs1990/mtg-whitelist-proxy/main/install-tiny.sh | SECRET_MODE=simple bash
```

Docker 懒人脚本：

```bash
curl -fsSL https://raw.githubusercontent.com/xfs1990/mtg-whitelist-proxy/main/run-docker.sh | SECRET_MODE=simple RECREATE=1 bash
```

`simple` 模式会切到 MTG v1 direct 模式，不使用 `cloudflare.com` 和 DoH，只让 VPS 直接连接 Telegram。它适合作为特殊网络下的兜底方案；默认仍然推荐 `tls`。

## 常用参数

所有方式都支持这些环境变量。默认不用填，按需覆盖。

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `PORT` | 自动生成 | MTG 代理端口 |
| `ADD_PORT` | 自动生成 | 白名单页面端口 |
| `ADD_TOKEN` | 自动生成 | `/add/<token>` 密码 |
| `SECRET` | 自动生成 | MTG secret |
| `SECRET_MODE` | `tls` | `tls` 使用 MTG v2 伪装域名；`simple` 使用 MTG v1 direct 模式 |
| `DOMAIN` | `cloudflare.com` | 生成 secret 的伪装域名 |
| `MTG_DOH_IP` | 自动选择 | MTG 解析伪装域名时使用的 DoH IP |
| `IP_MODE` | `auto` | 出站 IP 策略 |
| `WHITELIST_MODE` | `SUBNET` | 白名单模式 |
| `PUBLIC_IPV4` | 自动识别 | 手动指定公网 IPv4 |
| `PUBLIC_IPV6` | 自动识别 | 手动指定公网 IPv6 |
| `PUBLIC_HOST` | 空 | 强制 Telegram 链接使用指定域名或 IP |
| `MTG_URL` | 官方 GitHub Release | tiny 版自定义 MTG 下载地址 |
| `MTG_VENDOR_URL` | `vendor-bin` raw 地址 | tiny 版自定义备用 MTG 下载地址 |
| `MTG_FILE` | 空 | tiny 版使用本地 MTG 压缩包 |
| `VENDOR_RAW` | 本仓库 `vendor-bin` 分支 | tiny 版备用 raw 分支地址 |
| `FORCE_IPV4` | `0` | tiny 版强制 apt/curl 走 IPv4 |
| `FORCE_IPV6` | `0` | tiny 版强制 apt/curl 走 IPv6 |
| `APT_LOCK_TIMEOUT` | `120` | tiny 版等待 apt 锁的秒数 |

固定密码和端口示例：

```bash
docker run -d \
  --name mtg-whitelist-proxy \
  --restart unless-stopped \
  --network host \
  --cap-add NET_ADMIN \
  -v /opt/mtg-whitelist-proxy/data:/data \
  -e ADD_TOKEN='your-password' \
  -e PORT=18188 \
  -e ADD_PORT=8080 \
  ghcr.io/xfs1990/mtg-whitelist-proxy:latest
```

## IP_MODE

```text
auto         启动时自动检测 IPv4/IPv6
prefer-ipv4 优先 IPv4
prefer-ipv6 优先 IPv6
only-ipv4   只走 IPv4
only-ipv6   只走 IPv6
```

`auto` 只在启动时检测一次，不会运行中频繁切换。

## 白名单模式

```text
OFF     不限制来源 IP
IP      IPv4 /32，IPv6 /128
SUBNET  IPv4 /32，IPv6 /64
```

手机网络建议用默认的 `SUBNET`，因为移动网络 IPv6 地址经常变化。

如果页面能打开，但 Telegram 连不上，常见原因是浏览器加白的 IP 和 Telegram 实际连接的 IP 不一致。先关闭手机上的 VPN、代理、iCloud Private Relay，再重新打开白名单地址。

## 查看状态

Docker：

```bash
docker ps
docker logs mtg-whitelist-proxy --tail=100
nft list table inet mtproxy_guard
```

tiny systemd：

```bash
systemctl status mtg-whitelist-proxy mtg-whitelist-server
journalctl -u mtg-whitelist-proxy -u mtg-whitelist-server -f
nft list table inet mtproxy_guard
```

tiny Alpine / OpenRC：

```sh
rc-service mtg-whitelist-proxy status
rc-service mtg-whitelist-server status
tail -f /var/log/mtg-whitelist-proxy.log /var/log/mtg-whitelist-server.log
nft list table inet mtproxy_guard
```

## 卸载

Docker：

```bash
docker rm -f mtg-whitelist-proxy
nft delete table inet mtproxy_guard
```

tiny systemd：

```bash
systemctl disable --now mtg-whitelist-proxy mtg-whitelist-server
nft delete table inet mtproxy_guard
```

tiny Alpine / OpenRC：

```sh
rc-service mtg-whitelist-proxy stop
rc-service mtg-whitelist-server stop
rc-update del mtg-whitelist-proxy default
rc-update del mtg-whitelist-server default
nft delete table inet mtproxy_guard
```

## 镜像发布

每次 push 到 `main`，GitHub Actions 会自动构建并发布：

```text
ghcr.io/xfs1990/mtg-whitelist-proxy:latest
```

如果要让任意 VPS 免登录拉取镜像，需要在 GitHub Packages 中把 package visibility 设为 `Public`。
