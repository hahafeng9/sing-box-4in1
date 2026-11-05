# sing-box 四合一部署脚本

一键在自己的 VPS 上部署 sing-box，四个协议一次装好：

| 协议 | 传输 | 默认端口 |
|---|---|---|
| VLESS + REALITY | TCP + Vision | 443 |
| VMess + WS | 走 Cloudflare 隧道 | 10086（本机） |
| Hysteria2 | UDP | 8443 |
| TUIC v5 | UDP | 8444 |

支持 **Cloudflare 固定隧道**：填 token + 域名，VMess 自动走隧道进来，不用在服务器上开 80/443、不用申请证书。token 除了贴 Cloudflare 给的那串，也可以直接给 JSON 形式的 credentials（`{"AccountTag":"...","TunnelSecret":"...","TunnelID":"..."}`）。

没有域名也可以用 **临时隧道**：安装时选“用临时隧道”，cloudflared 自动分配 `xxx.trycloudflare.com` 域名，VMess 照样走隧道。临时隧道域名每次重启会变，以 `sb show` 显示的为准；想固定下来就改用固定隧道。

## 一键安装

```bash
bash <(curl -Ls https://raw.githubusercontent.com/hahafeng9/sing-box-4in1/main/install.sh)
```

装完输入 `sb` 随时打开管理菜单。

非交互安装（写脚本批量装时用）：

```bash
bash install.sh install
```

## 固定隧道怎么配

1. Cloudflare Zero Trust → Networks → Tunnels → Create → 选 Cloudflared → 复制 token。
2. 在隧道里加一条 Public Hostname：域名填你的，Service 填 `http://localhost:10086`（端口按你装的 VMess 端口改）。
3. 跑 `sb` → 选 5，粘贴 token 和域名；或安装时直接传环境变量：

```bash
SB_TUNNEL_TOKEN=你的token SB_TUNNEL_DOMAIN=node.example.com bash install.sh install
```

不配隧道也能用：VMess 直接监听公网端口，走 `ws` 明文（建议只在内网或自有反代后用）。

## 环境变量

| 变量 | 说明 | 默认 |
|---|---|---|
| `SB_REALITY_PORT` | VLESS+REALITY 端口 | 443 |
| `SB_VMESS_PORT` | VMess+WS 端口 | 10086 |
| `SB_HY2_PORT` | Hysteria2 端口 | 8443 |
| `SB_TUIC_PORT` | TUIC 端口 | 8444 |
| `SB_BASE_PORT` | NAT 机：以该端口为起点，四个协议依次占连续 4 个端口 | — |
| `SB_SNI` | Reality / TLS 伪装域名 | www.microsoft.com |
| `SB_TUNNEL_TOKEN` / `SB_TUNNEL_DOMAIN` | 固定隧道 token（或 JSON credentials）与域名 | — |
| `SB_ARGO` | 设为 `1` 启用临时隧道（无需域名；与固定隧道二选一） | — |
| `SB_NODE_NAME` | 节点名前缀 | sb4 |
| `SB_VERSION` | 指定 sing-box 版本 | 最新稳定版 |

NAT 机示例（只有 30000–30003 四个端口可用）：

```bash
SB_BASE_PORT=30000 bash install.sh install
```

## 管理命令

```bash
sb              # 打开菜单（1 是一键安装，只问隧道；其他全默认）
sb show         # 查看节点信息与链接
sb check        # 自检：服务、配置、端口、探针、隧道，逐项打勾
sb check --fix  # 自检，失败时自动重启服务后复检一次
sb restart      # 重启 sing-box / cloudflared
sb update       # 更新 sing-box 与 cloudflared 到最新版
sb tunnel       # 添加 / 更换固定隧道
sb argo         # 启用临时隧道（无需域名）
sb uninstall    # 卸载（加 -y 跳过确认）
```

装完脚本会自动跑一次自检；平时随时 `sb check`，哪项红了就看哪项。

节点链接存在服务器 `/etc/sing-box/links.txt`，base64 订阅在 `/etc/sing-box/sub.txt`。

## 和老王（eooce）四合一脚本的对比

本脚本参考了老王 sing-box 四合一的公开说明（eooce/Sing-box README），代码是自己写的，不是照抄。用户给的另一条参考视频（nqxA7kFVJi0）看过之后确认讲的不是 sing-box 部署，而是 Lucky STUN + GOST 反向 CDN 回源做线路优化，和部署脚本无关，所以没从里面取东西。对比如下：

| 能力 | 老王 | 本脚本 |
|---|---|---|
| 四协议 VLESS+REALITY / VMess+WS / HY2 / TUIC | 有 | 有 |
| 固定隧道（token 或 JSON credentials） | 有 | 有 |
| 临时隧道（无域名） | 默认行为 | 可选（`SB_ARGO=1` / 菜单 10） |
| 哪吒探针集成 | 有（v0/v1） | 没有（见下） |
| TG 推送节点信息 | 有 | 没有 |
| 健康巡检自愈 | 常驻巡检 + 自动重启 | `sb check --fix` 手动触发 + 服务 `Restart=on-failure` |
| 订阅 | nginx + 第三方转换站 | 本地 `sub.txt`（base64），不经过第三方 |
| NAT 机连续端口 | `PORT` | `SB_BASE_PORT` |
| 多发行版（Fedora / Alpine / RHEL） | 有 | 只有 Debian / Ubuntu |
| 纯 IPv6 机器 | 支持 | 支持（链接里 IPv6 自动加方括号） |
| 安装前端口占用预检 | — | 有，占用的端口直接报出占用进程 |

没做的三项是有意的：哪吒探针用户一般已有独立部署流程，塞进部署脚本会多一个故障面；TG 推送要往脚本里填 bot token，等于多存一份凭据；WARP 解锁分流（GPT/奈飞）超出“部署节点”这个目标。需要哪吒或 WARP 的话，装完再单独配。

## 安全说明

- 单文件脚本，全部逻辑可见，没有任何上报、统计、回连、后门。
- 二进制只从两个官方源下载：`github.com/SagerNet/sing-box/releases`、`github.com/cloudflare/cloudflared/releases`；有 sha256 文件就校验。
- UUID、密码、Reality 密钥对全部在本机随机生成，只存在 `/etc/sing-box/params.env`（600 权限）；隧道 token 只存在 `/etc/cloudflared/config.yml`（600 权限），不会出现在进程列表里。
- 旧配置重装前自动备份到 `config.json.bak.时间戳`。
- 要求 Debian / Ubuntu + systemd + root。

## 卸载

```bash
sb uninstall
```

删掉服务、二进制、配置与快捷命令，不动系统其他东西。
