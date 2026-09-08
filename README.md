# mtg-whitelist-proxy

一个基于 MTG 的 MTProto Proxy 项目，带动态白名单页面。

核心目标：

- 普通 VPS：一行 `docker run` 启动
- 极低配 VPS：不用 Docker，使用 tiny 原生安装
- 手机打开 `/add/<token>` 后自动放行当前 IP
- 页面直接显示可点击的 Telegram 导入链接
- 支持 IPv4 / IPv6 dual-stack 入口
- 支持启动时自动检测 Telegram IPv4 / IPv6 出站可用性
- 只维护独立 nftables 表 `inet mtproxy_guard`，不 flush 全局防火墙

镜像地址：

```text
ghcr.io/xfs1990/mtg-whitelist-proxy:latest
```

## 选择用法

优先按机器类型选择：

| 场景 | 推荐方式 |
| --- | --- |
| 已经安装 Docker 的正常 VPS | `docker run` |
| Debian / Ubuntu，想自动安装 Docker | `install.sh` |
| 256M 内存 / 1G 磁盘 / NAT 小鸡 | `install-tiny.sh` |
| Alpine 极简系统，没有 curl/bash | `bootstrap-tiny.sh` |

## Docker 一行启动

适合已经有 Docker 的 VPS。

最短命令：

```bash
docker run -d --name mtg-whitelist-proxy --restart unless-stopped --network host --cap-add NET_ADMIN -v /opt/mtg-whitelist-proxy/data:/data ghcr.io/xfs1990/mtg-whitelist-proxy:latest
```

启动后查看白名单地址：

```bash
docker logs mtg-whitelist-proxy --tail=80
```

会看到类似：

```text
IPv4-URL: http://IPv4:随机ADD_PORT/add/随机token
IPv6-URL: http://[IPv6]:随机ADD_PORT/add/随机token
```

手机打开其中一个 URL，页面会自动放行当前 IP，并显示：

- `打开 Telegram`
- `打开 t.me 链接`
- 可复制的 `tg://proxy?...`
- 可复制的 `https://t.me/proxy?...`

## Docker 固定参数启动

如果你想固定密码、端口或 IPv4/IPv6 模式，可以只加需要的 `-e`。

固定密码和端口：

```bash
docker run -d --name mtg-whitelist-proxy --restart unless-stopped --network host --cap-add NET_ADMIN -v /opt/mtg-whitelist-proxy/data:/data -e ADD_TOKEN='Pass' -e PORT=18188 -e ADD_PORT=8080 ghcr.io/xfs1990/mtg-whitelist-proxy:latest
```

强制 IPv6 出站：

```bash
docker run -d --name mtg-whitelist-proxy --restart unless-stopped --network host --cap-add NET_ADMIN -v /opt/mtg-whitelist-proxy/data:/data -e IP_MODE=only-ipv6 ghcr.io/xfs1990/mtg-whitelist-proxy:latest
```

固定伪装域名：

```bash
docker run -d --name mtg-whitelist-proxy --restart unless-stopped --network host --cap-add NET_ADMIN -v /opt/mtg-whitelist-proxy/data:/data -e DOMAIN='cloudflare.com' ghcr.io/xfs1990/mtg-whitelist-proxy:latest
```

## Docker 自动生成规则

以下参数都可以不填：

| 参数 | 不填时行为 |
| --- | --- |
| `ADD_TOKEN` | 自动生成随机白名单 token |
| `SECRET` | 根据 `DOMAIN` 自动生成 MTG secret |
| `PORT` | 自动生成并保存一个代理端口 |
| `ADD_PORT` | 自动生成并保存一个白名单页面端口 |
| `DOMAIN` | 默认 `cloudflare.com` |

自动生成的值会保存到：

```text
/opt/mtg-whitelist-proxy/data/generated/
```

只要保留这个 volume，容器重启或升级后不会换 token、端口和 secret。

查看生成值：

```bash
ls -la /opt/mtg-whitelist-proxy/data/generated
cat /opt/mtg-whitelist-proxy/data/generated/add_token
cat /opt/mtg-whitelist-proxy/data/generated/add_port
cat /opt/mtg-whitelist-proxy/data/generated/port
```

## Debian / Ubuntu 自动安装 Docker

如果 VPS 还没有 Docker，并且是 Debian / Ubuntu，可以用：

```bash
curl -fsSL https://raw.githubusercontent.com/xfs1990/mtg-whitelist-proxy/main/install.sh | bash
```

这个脚本会：

- 自动安装 Docker Engine
- 拉取 GHCR 镜像
- 生成 `SECRET` 和 `ADD_TOKEN`
- 写入 `/opt/mtg-whitelist-proxy`
- 启动容器

如果 Docker 官方源不可达，改用系统源安装 Docker：

```bash
curl -fsSL https://raw.githubusercontent.com/xfs1990/mtg-whitelist-proxy/main/install.sh | DOCKER_INSTALL_SOURCE=distro bash
```

如果 VPS 访问包管理源时 IPv6 异常，强制 apt 走 IPv4：

```bash
curl -4 -fsSL https://raw.githubusercontent.com/xfs1990/mtg-whitelist-proxy/main/install.sh | FORCE_IPV4=1 bash
```

也可以组合：

```bash
curl -4 -fsSL https://raw.githubusercontent.com/xfs1990/mtg-whitelist-proxy/main/install.sh | DOCKER_INSTALL_SOURCE=distro FORCE_IPV4=1 bash
```

## Tiny 原生安装

适合这类机器：

- 256M 内存
- 1G 磁盘
- NAT IPv4
- Docker 太重或装不上

tiny 版不使用 Docker。它会下载 MTG 单文件，并用 systemd 或 OpenRC 启动：

- `mtg-whitelist-proxy`
- `mtg-whitelist-server`

Debian / Ubuntu / Alpine 已有 curl/bash 时：

```bash
curl -fsSL https://raw.githubusercontent.com/xfs1990/mtg-whitelist-proxy/main/install-tiny.sh | bash
```

Alpine 极简系统没有 curl/bash 时：

```sh
wget -qO- https://raw.githubusercontent.com/xfs1990/mtg-whitelist-proxy/main/bootstrap-tiny.sh | sh
```

## NAT 小鸡固定端口

如果面板只给你一段公网端口，例如：

```text
10380 - 10399
```

建议固定两个端口：

```text
10380 = MTG 代理端口
10381 = 白名单页面端口
```

面板端口转发：

```text
公网IP:10380 -> 内网IP:10380
公网IP:10381 -> 内网IP:10381
```

tiny 安装时显式传公网 IP 和端口：

```bash
curl -fsSL https://raw.githubusercontent.com/xfs1990/mtg-whitelist-proxy/main/install-tiny.sh | PUBLIC_IPV4=193.122.117.100 PORT=10380 ADD_PORT=10381 bash
```

Alpine 极简系统：

```sh
wget -qO- https://raw.githubusercontent.com/xfs1990/mtg-whitelist-proxy/main/bootstrap-tiny.sh | PUBLIC_IPV4=193.122.117.100 PORT=10380 ADD_PORT=10381 sh
```

安装完成会输出：

```text
IPv4-URL: http://193.122.117.100:10381/add/随机token
```

手机访问这个地址，页面里的 Telegram 代理端口会是 `10380`。

## 可选参数

所有部署方式都支持这些环境变量。

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `PORT` | Docker 随机，tiny 默认 `18188` | MTG 代理端口 |
| `ADD_PORT` | Docker 随机，tiny 默认 `8080` | 白名单页面端口 |
| `ADD_TOKEN` | 自动生成 | `/add/<token>` 的访问密码 |
| `SECRET` | 自动生成 | MTG secret |
| `DOMAIN` | `cloudflare.com` | 生成 MTG secret 时使用的伪装域名 |
| `IP_MODE` | `auto` | MTG 出站 IPv4/IPv6 策略 |
| `WHITELIST_MODE` | `SUBNET` | 白名单模式 |
| `IPV4_SUBNET` | `32` | IPv4 SUBNET 模式前缀 |
| `IPV6_SUBNET` | `64` | IPv6 SUBNET 模式前缀 |
| `PUBLIC_HOST` | 空 | 强制 Telegram 链接使用指定域名或 IP |
| `PUBLIC_IPV4` | 自动识别 | 页面和日志展示的 IPv4 地址 |
| `PUBLIC_IPV6` | 自动识别 | 页面和日志展示的 IPv6 地址 |
| `LOG_LEVEL` | `info` | `debug` 时启用 MTG debug 输出 |
| `NFT_TABLE` | `mtproxy_guard` | nftables 表名 |
| `WHITELIST_FILE` | `/data/whitelist.json` | 白名单持久化文件 |

`install.sh` 额外支持：

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `AUTO_INSTALL_DOCKER` | `1` | Docker 不存在时是否自动安装 |
| `DOCKER_INSTALL_SOURCE` | `auto` | `auto` / `official` / `distro` |
| `FORCE_IPV4` | `0` | apt 和 curl 是否强制 IPv4 |
| `INSTALL_DIR` | `/opt/mtg-whitelist-proxy` | Docker 安装目录 |

`install-tiny.sh` 额外支持：

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `INSTALL_DIR` | `/opt/mtg-whitelist-proxy-tiny` | tiny 安装目录 |
| `MTG_VERSION` | `2.2.8` | 下载的 MTG 版本 |
| `REPO_RAW` | 当前 GitHub raw 地址 | 脚本和服务文件下载来源 |
| `FORCE_IPV4` | `0` | 下载和包管理是否强制 IPv4 |

## IP_MODE 说明

`IP_MODE=auto` 只在启动时检测一次 Telegram DC 连通性，不做运行时频繁切换。

规则：

| 检测结果 | 自动选择 |
| --- | --- |
| IPv4 和 IPv6 都通 | `prefer-ipv6` |
| 只有 IPv4 通 | `only-ipv4` |
| 只有 IPv6 通 | `only-ipv6` |
| 都不通 | 启动失败 |

手动模式：

```text
prefer-ipv4
prefer-ipv6
only-ipv4
only-ipv6
```

## 白名单模式

| 模式 | 行为 |
| --- | --- |
| `OFF` | 不限制访问 MTG 端口 |
| `IP` | IPv4 放行 `/32`，IPv6 放行 `/128` |
| `SUBNET` | IPv4 默认 `/32`，IPv6 默认 `/64` |

手机网络建议使用默认的 `SUBNET`。很多移动网络 IPv6 隐私地址会变，放行 `/64` 更实用。

## 页面效果

访问：

```text
http://服务器IP:ADD_PORT/add/ADD_TOKEN
```

IPv6：

```text
http://[服务器IPv6]:ADD_PORT/add/ADD_TOKEN
```

页面会显示：

- 识别到的 IP
- 已放行范围
- 代理地址
- `打开 Telegram`
- `打开 t.me 链接`
- `tg://proxy?...`
- `https://t.me/proxy?...`
- 当前白名单链接
- IPv4/IPv6 白名单链接

页面是响应式布局，手机上可以直接点链接导入 Telegram。

## 查看状态

Docker：

```bash
docker ps
docker logs mtg-whitelist-proxy --tail=100
docker logs -f mtg-whitelist-proxy
```

Docker 健康检查：

```bash
port="$(cat /opt/mtg-whitelist-proxy/data/generated/add_port)"
curl "http://127.0.0.1:${port}/healthz"
```

tiny systemd：

```bash
systemctl status mtg-whitelist-proxy mtg-whitelist-server
journalctl -u mtg-whitelist-proxy -u mtg-whitelist-server -f
```

tiny Alpine / OpenRC：

```sh
rc-service mtg-whitelist-proxy status
rc-service mtg-whitelist-server status
tail -f /var/log/mtg-whitelist-proxy.log /var/log/mtg-whitelist-server.log
```

查看监听端口：

```bash
ss -lntp
```

查看白名单文件：

```bash
cat /opt/mtg-whitelist-proxy/data/whitelist.json
cat /opt/mtg-whitelist-proxy-tiny/data/whitelist.json
```

查看 nftables 表：

```bash
nft list table inet mtproxy_guard
```

## 升级

Docker：

```bash
docker rm -f mtg-whitelist-proxy
docker pull ghcr.io/xfs1990/mtg-whitelist-proxy:latest
docker run -d --name mtg-whitelist-proxy --restart unless-stopped --network host --cap-add NET_ADMIN -v /opt/mtg-whitelist-proxy/data:/data ghcr.io/xfs1990/mtg-whitelist-proxy:latest
```

tiny：

```bash
curl -fsSL https://raw.githubusercontent.com/xfs1990/mtg-whitelist-proxy/main/install-tiny.sh | bash
```

NAT tiny 记得继续传公网 IP 和固定端口：

```bash
curl -fsSL https://raw.githubusercontent.com/xfs1990/mtg-whitelist-proxy/main/install-tiny.sh | PUBLIC_IPV4=193.122.117.100 PORT=10380 ADD_PORT=10381 bash
```

## 停止和卸载

Docker 停止：

```bash
docker rm -f mtg-whitelist-proxy
```

Docker 清理白名单表：

```bash
nft delete table inet mtproxy_guard
```

tiny systemd 停止：

```bash
systemctl disable --now mtg-whitelist-proxy mtg-whitelist-server
nft delete table inet mtproxy_guard
```

tiny Alpine / OpenRC 停止：

```sh
rc-service mtg-whitelist-proxy stop
rc-service mtg-whitelist-server stop
rc-update del mtg-whitelist-proxy default
rc-update del mtg-whitelist-server default
nft delete table inet mtproxy_guard
```

## GitHub Actions 和镜像发布

每次 push 到 `main`，GitHub Actions 会自动构建并发布：

```text
linux/amd64
linux/arm64
```

发布地址：

```text
ghcr.io/xfs1990/mtg-whitelist-proxy:latest
```

仓库不需要保存 PAT。镜像由 GitHub Actions 使用仓库自带的 `GITHUB_TOKEN` 发布。

首次构建成功后，需要在 GitHub Packages 里把 GHCR package visibility 设置为 `Public`，这样任意 VPS 才能匿名拉取镜像。

## 注意事项

- Docker 模式需要 `--network host` 和 `--cap-add NET_ADMIN`
- tiny 模式需要 root 权限，因为要写 systemd/OpenRC 服务和 nftables
- NAT VPS 必须在面板里转发 `PORT` 和 `ADD_PORT`
- 开启白名单模式后，没访问 `/add/<token>` 的 IP 不能连接 MTG 端口
- 项目只操作 `inet mtproxy_guard`，不会清空系统全局 nftables ruleset
