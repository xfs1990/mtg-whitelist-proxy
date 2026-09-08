# mtg-whitelist-proxy

基于 MTG 的 Telegram MTProto Proxy，一键启动，带动态白名单页面。

手机打开安装脚本返回的 `IPv4-URL` 或 `IPv6-URL` 后，会自动放行当前 IP，并显示可点击的 Telegram 导入链接。

项目只维护自己的 nftables 表 `inet mtproxy_guard`，不会清空系统防火墙。

## 两种安装方式

| 机器类型 | 用法 |
| --- | --- |
| 正常 VPS，已经有 Docker | Docker 版 |
| 低配小鸡、NAT 小鸡、Docker 太重 | tiny 版 |

## 方式一：Docker 版

适合正常 VPS。机器上需要已经安装 Docker。

```bash
curl -fsSL https://raw.githubusercontent.com/xfs1990/mtg-whitelist-proxy/main/run-docker.sh | bash
```

脚本会启动 Docker 容器，并直接返回：

```text
MTG Docker 版已启动。
代理端口：xxxxx
IPv4-URL: http://IPv4:端口/add/密码
IPv6-URL: http://[IPv6]:端口/add/密码
```

然后用手机打开 `IPv4-URL` 或 `IPv6-URL`。

### Docker 固定参数

默认会自动生成密码和端口。你也可以自己指定：

```bash
curl -fsSL https://raw.githubusercontent.com/xfs1990/mtg-whitelist-proxy/main/run-docker.sh | ADD_TOKEN='Pass' PORT=18188 ADD_PORT=8080 bash
```

强制 IPv6 出站：

```bash
curl -fsSL https://raw.githubusercontent.com/xfs1990/mtg-whitelist-proxy/main/run-docker.sh | IP_MODE=only-ipv6 bash
```

重建已有容器：

```bash
curl -fsSL https://raw.githubusercontent.com/xfs1990/mtg-whitelist-proxy/main/run-docker.sh | RECREATE=1 bash
```

原始 Docker 命令也可以用，但它只会返回容器 ID：

```bash
docker run -d --name mtg-whitelist-proxy --restart unless-stopped --network host --cap-add NET_ADMIN -v /opt/mtg-whitelist-proxy/data:/data ghcr.io/xfs1990/mtg-whitelist-proxy:latest
```

查看 Docker 版状态：

```bash
docker ps
docker logs mtg-whitelist-proxy --tail=100
```

## 方式二：tiny 版

适合低配机器，不需要 Docker。

```bash
curl -fsSL https://raw.githubusercontent.com/xfs1990/mtg-whitelist-proxy/main/install-tiny.sh | bash
```

脚本会下载 MTG 单文件，并用 systemd 或 OpenRC 启动两个服务：

```text
mtg-whitelist-proxy
mtg-whitelist-server
```

Alpine 极简系统如果没有 `curl` / `bash`，用：

```sh
wget -qO- https://raw.githubusercontent.com/xfs1990/mtg-whitelist-proxy/main/bootstrap-tiny.sh | sh
```

### NAT 小鸡

如果服务商只给一段公网端口，比如 `10380 - 10399`，就从里面挑两个端口：

```text
PROXY_PORT = MTG 代理端口
ADD_PORT   = 白名单页面端口
```

面板端口转发：

```text
YOUR_PUBLIC_IP:PROXY_PORT -> YOUR_PRIVATE_IP:PROXY_PORT
YOUR_PUBLIC_IP:ADD_PORT   -> YOUR_PRIVATE_IP:ADD_PORT
```

安装时显式传公网 IP 和端口：

```bash
curl -fsSL https://raw.githubusercontent.com/xfs1990/mtg-whitelist-proxy/main/install-tiny.sh | PUBLIC_IPV4=YOUR_PUBLIC_IP PORT=PROXY_PORT ADD_PORT=ADD_PORT bash
```

Alpine 极简系统：

```sh
wget -qO- https://raw.githubusercontent.com/xfs1990/mtg-whitelist-proxy/main/bootstrap-tiny.sh | PUBLIC_IPV4=YOUR_PUBLIC_IP PORT=PROXY_PORT ADD_PORT=ADD_PORT sh
```

输出会类似：

```text
IPv4-URL: http://YOUR_PUBLIC_IP:ADD_PORT/add/随机密码
```

手机打开这个地址，页面里的 Telegram 代理端口会是 `PROXY_PORT`。

把 `YOUR_PUBLIC_IP`、`YOUR_PRIVATE_IP`、`PROXY_PORT`、`ADD_PORT` 换成你自己面板分配的值。

查看 tiny 状态：

```bash
systemctl status mtg-whitelist-proxy mtg-whitelist-server
journalctl -u mtg-whitelist-proxy -u mtg-whitelist-server -f
```

Alpine / OpenRC：

```sh
rc-service mtg-whitelist-proxy status
rc-service mtg-whitelist-server status
tail -f /var/log/mtg-whitelist-proxy.log /var/log/mtg-whitelist-server.log
```

## 常用参数

所有方式都支持这些环境变量：

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `PORT` | Docker 随机，tiny 默认 `18188` | MTG 代理端口 |
| `ADD_PORT` | Docker 随机，tiny 默认 `8080` | 白名单页面端口 |
| `ADD_TOKEN` | 自动生成 | `/add/<token>` 密码 |
| `SECRET` | 自动生成 | MTG secret |
| `DOMAIN` | `cloudflare.com` | 生成 secret 的伪装域名 |
| `IP_MODE` | `auto` | 出站 IP 策略 |
| `WHITELIST_MODE` | `SUBNET` | 白名单模式 |
| `PUBLIC_IPV4` | 自动识别 | 手动指定公网 IPv4 |
| `PUBLIC_IPV6` | 自动识别 | 手动指定公网 IPv6 |
| `PUBLIC_HOST` | 空 | 强制 Telegram 链接使用指定域名或 IP |

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

## 页面效果

访问：

```text
http://服务器IP:ADD_PORT/add/ADD_TOKEN
```

页面会显示：

- 识别到的 IP
- 已放行范围
- 代理地址
- `打开 Telegram`
- `打开 t.me 链接`
- 可复制的 `tg://proxy?...`
- 可复制的 `https://t.me/proxy?...`

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
