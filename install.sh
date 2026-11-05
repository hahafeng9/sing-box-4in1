#!/usr/bin/env bash
# =============================================================================
# sing-box 四合一部署脚本
#   VLESS + REALITY (TCP) / VMess + WS (走 Cloudflare 隧道) /
#   Hysteria2 (UDP) / TUIC v5 (UDP)
#
# 特点：
#   - 单文件、全部逻辑可见，可审计；没有任何上报、统计、回连行为。
#   - 只从两个官方源下载二进制：
#       sing-box    -> github.com/SagerNet/sing-box/releases
#       cloudflared -> github.com/cloudflare/cloudflared/releases
#   - 支持 Cloudflare 固定隧道（填 token + 域名即可），也可不配隧道直连。
#   - 生成的 UUID / 密码 / Reality 密钥对全部在本机随机生成，只存在服务器上。
#
# 用法：
#   bash install.sh                 # 交互菜单（1 是一键安装，只问隧道）
#   bash install.sh install         # 非交互安装（默认端口，可用环境变量改）
#   bash install.sh show            # 查看节点信息
#   bash install.sh check           # 自检：服务、配置、端口、探针、隧道
#   bash install.sh update          # 更新 sing-box 内核
#   bash install.sh restart         # 重启服务
#   bash install.sh uninstall       # 卸载（加 -y 跳过确认）
#   bash install.sh tunnel          # 添加 / 更换固定隧道（交互输入 token 与域名）
#
# 环境变量（安装时可用）：
#   SB_REALITY_PORT  VLESS+REALITY 端口，默认 443
#   SB_VMESS_PORT    VMess+WS 端口，默认 10086（配隧道时只监听本机）
#   SB_HY2_PORT      Hysteria2 端口，默认 8443
#   SB_TUIC_PORT     TUIC 端口，默认 8444
#   SB_BASE_PORT     NAT 机可用：以该端口为起点，四个协议依次占用连续 4 个端口
#   SB_SNI           Reality/TLS 伪装域名，默认 www.microsoft.com
#   SB_TUNNEL_TOKEN  固定隧道 token（配了它就同时要配 SB_TUNNEL_DOMAIN）
#   SB_TUNNEL_DOMAIN 固定隧道域名，如 node.example.com
#   SB_NODE_NAME          节点名前缀，默认 sb4
#   SB_VERSION       指定 sing-box 版本，如 1.14.4（默认取最新稳定版）
#
# 要求：Debian / Ubuntu，systemd，root 权限，服务器能访问 GitHub。
# =============================================================================
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/hahafeng9/sing-box-4in1/main/install.sh"
SB_HOME="${SB_HOME:-/etc/sing-box}"
SB_BIN_DIR="${SB_BIN_DIR:-/usr/local/bin}"
SB_CF_DIR="${SB_CF_DIR:-/etc/cloudflared}"
SB_SVC_DIR="${SB_SVC_DIR:-/etc/systemd/system}"
PARAMS_FILE="$SB_HOME/params.env"
LINKS_FILE="$SB_HOME/links.txt"
SUB_FILE="$SB_HOME/sub.txt"
NODE_NAME="${SB_NODE_NAME:-sb4}"
SNI="${SB_SNI:-www.microsoft.com}"
FALLBACK_VERSION="1.14.4"

# ---------- 输出 ----------
red()   { echo -e "\e[31m$*\e[0m"; }
green() { echo -e "\e[32m$*\e[0m"; }
yellow(){ echo -e "\e[33m$*\e[0m"; }
blue()  { echo -e "\e[36m$*\e[0m"; }
die()   { red "错误：$*"; exit 1; }

# ---------- 前置检查 ----------
check_root() {
    [[ $EUID -eq 0 ]] || die "请用 root 运行（sudo -i 后再跑）"
}
check_systemd() {
    command -v systemctl >/dev/null 2>&1 || die "需要 systemd，本机没有 systemctl"
    [[ -d /run/systemd/system ]] || die "systemd 未作为 PID 1 运行（容器里请用宿主机方式部署）"
}
detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64) ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        *) die "不支持的架构：$(uname -m)，只支持 x86_64 / aarch64" ;;
    esac
}
detect_os() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        case "$ID" in
            debian|ubuntu) ;;
            *) die "只支持 Debian / Ubuntu，当前是 $ID" ;;
        esac
    else
        die "读不到 /etc/os-release，无法确认系统"
    fi
}

# ---------- 端口 ----------
resolve_ports() {
    if [[ -n "${SB_BASE_PORT:-}" ]]; then
        REALITY_PORT="$SB_BASE_PORT"
        VMESS_PORT=$((SB_BASE_PORT + 1))
        HY2_PORT=$((SB_BASE_PORT + 2))
        TUIC_PORT=$((SB_BASE_PORT + 3))
    else
        REALITY_PORT="${SB_REALITY_PORT:-443}"
        VMESS_PORT="${SB_VMESS_PORT:-10086}"
        HY2_PORT="${SB_HY2_PORT:-8443}"
        TUIC_PORT="${SB_TUIC_PORT:-8444}"
    fi
    for p in "$REALITY_PORT" "$VMESS_PORT" "$HY2_PORT" "$TUIC_PORT"; do
        [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 )) || die "端口不合法：$p"
    done
}

# ---------- 公网 IP ----------
get_ip() {
    local ip=""
    ip=$(curl -fsS -m 5 https://ipv4.ip.sb 2>/dev/null || true)
    [[ -z "$ip" ]] && ip=$(curl -fsS -m 5 https://ifconfig.me 2>/dev/null || true)
    if [[ -z "$ip" ]]; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    [[ -n "$ip" ]] || die "拿不到服务器 IP，请检查网络"
    echo "$ip"
}

# ---------- 依赖 ----------
install_deps() {
    export DEBIAN_FRONTEND=noninteractive
    local need=()
    for c in curl wget tar jq openssl unzip; do
        command -v "$c" >/dev/null 2>&1 || need+=("$c")
    done
    if (( ${#need[@]} == 0 )); then
        echo "依赖齐全（curl/wget/tar/jq/openssl/unzip），跳过 apt update"
        return 0
    fi
    echo "安装依赖：${need[*]}"
    # 只在缺依赖时才 update，且限时 180 秒，超时也不硬拦（用旧索引继续装）
    timeout 180 apt-get update -qq || yellow "apt update 超时或失败，继续用现有索引安装"
    apt-get install -y -qq "${need[@]}"
}

# ---------- 下载 ----------
# 用法：download URL 输出路径
download() {
    local url="$1" out="$2"
    echo "下载：$url"
    curl -fsSL --retry 2 --connect-timeout 15 -o "$out" "$url" \
        || die "下载失败：$url"
    [[ -s "$out" ]] || die "下载到空文件：$url"
}

latest_singbox_version() {
    local ver=""
    ver=$(curl -fsS -m 10 "https://api.github.com/repos/SagerNet/sing-box/releases/latest" 2>/dev/null \
        | jq -r '.tag_name // empty' 2>/dev/null | sed 's/^v//')
    if [[ -z "$ver" ]]; then
        yellow "GitHub API 取最新版失败，改用已知稳定版 $FALLBACK_VERSION"
        ver="$FALLBACK_VERSION"
    fi
    echo "$ver"
}

install_singbox() {
    local ver="${SB_VERSION:-$(latest_singbox_version)}"
    if [[ -x "$SB_BIN_DIR/sing-box" ]]; then
        local cur
        cur=$("$SB_BIN_DIR/sing-box" version 2>/dev/null | head -n1 | awk '{print $3}')
        if [[ "$cur" == "$ver" ]]; then
            green "sing-box 已是 $ver，跳过安装"
            return 0
        fi
        yellow "sing-box 将从 $cur 升到 $ver"
    fi
    echo "安装 sing-box $ver ..."
    local tmp; tmp=$(mktemp -d)
    local asset="sing-box-${ver}-linux-${ARCH}.tar.gz"
    download "https://github.com/SagerNet/sing-box/releases/download/v${ver}/${asset}" "$tmp/$asset"
    # 有校验文件就验，没有也不硬拦（只认官方 release 地址）
    if curl -fsSL -m 10 -o "$tmp/sha256.txt" \
        "https://github.com/SagerNet/sing-box/releases/download/v${ver}/sing-box-${ver}-linux-${ARCH}.tar.gz.sha256" 2>/dev/null; then
        (cd "$tmp" && sha256sum -c sha256.txt) || die "sing-box 校验和不匹配，停止安装"
        green "校验和通过"
    else
        yellow "官方未提供该版本的 sha256 文件，跳过校验（下载地址仍为官方 release）"
    fi
    tar -xzf "$tmp/$asset" -C "$tmp"
    install -m 755 "$tmp/sing-box-${ver}-linux-${ARCH}/sing-box" "$SB_BIN_DIR/sing-box"
    rm -rf "$tmp"
    "$SB_BIN_DIR/sing-box" version | head -n1
}

install_cloudflared() {
    if [[ -x "$SB_BIN_DIR/cloudflared" ]]; then
        green "cloudflared 已安装，跳过"
        return 0
    fi
    echo "安装 cloudflared ..."
    local tmp; tmp=$(mktemp -d)
    download "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}" "$tmp/cloudflared"
    install -m 755 "$tmp/cloudflared" "$SB_BIN_DIR/cloudflared"
    rm -rf "$tmp"
    "$SB_BIN_DIR/cloudflared" --version
}

# ---------- 随机凭据 ----------
rand_hex() { openssl rand -hex "$1"; }

gen_secrets() {
    UUID="${SB_UUID:-$(cat /proc/sys/kernel/random/uuid)}"
    HY2_PASS=$(rand_hex 12)
    TUIC_PASS=$(rand_hex 8)
    SHORT_ID=$(rand_hex 4)
    # Reality 密钥对
    local kp
    kp=$("$SB_BIN_DIR/sing-box" generate reality-keypair)
    # 1.14 输出是 "PrivateKey: xxx" / "PublicKey: xxx"，旧版是 "Private key: xxx"，两种都兼容
    REALITY_PRIV=$(echo "$kp" | awk -F': *' '/[Pp]rivate ?[Kk]ey/{print $2}')
    REALITY_PUB=$(echo "$kp" | awk -F': *' '/[Pp]ublic ?[Kk]ey/{print $2}')
    [[ -n "$REALITY_PRIV" && -n "$REALITY_PUB" ]] || die "生成 Reality 密钥对失败"
}

gen_cert() {
    mkdir -p "$SB_HOME"
    if [[ ! -f "$SB_HOME/cert.pem" || ! -f "$SB_HOME/key.pem" ]]; then
        echo "生成自签证书（Hysteria2 / TUIC 用，客户端需允许自签或跳过验证）"
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
            -keyout "$SB_HOME/key.pem" -out "$SB_HOME/cert.pem" \
            -days 3650 -nodes -subj "/CN=$SNI" \
            -addext "subjectAltName=DNS:$SNI" 2>/dev/null
        chmod 600 "$SB_HOME/key.pem" "$SB_HOME/cert.pem"
    fi
}

# ---------- 写配置 ----------
save_params() {
    mkdir -p "$SB_HOME"
    cat > "$PARAMS_FILE" <<EOF
# sing-box 四合一参数（本机生成，勿外传）
UUID="$UUID"
HY2_PASS="$HY2_PASS"
TUIC_PASS="$TUIC_PASS"
SHORT_ID="$SHORT_ID"
REALITY_PRIV="$REALITY_PRIV"
REALITY_PUB="$REALITY_PUB"
REALITY_PORT="$REALITY_PORT"
VMESS_PORT="$VMESS_PORT"
HY2_PORT="$HY2_PORT"
TUIC_PORT="$TUIC_PORT"
SNI="$SNI"
NODE_NAME="$NODE_NAME"
TUNNEL_TOKEN="${TUNNEL_TOKEN:-}"
TUNNEL_DOMAIN="${TUNNEL_DOMAIN:-}"
EOF
    chmod 600 "$PARAMS_FILE"
}
load_params() {
    [[ -f "$PARAMS_FILE" ]] || die "找不到参数文件 $PARAMS_FILE，请先安装"
    # shellcheck disable=SC1090
    . "$PARAMS_FILE"
}

write_config() {
    # 配了隧道：VMess 只监听本机，走隧道进来；没配：直接监听公网端口
    local vmess_listen="0.0.0.0"
    [[ -n "${TUNNEL_DOMAIN:-}" ]] && vmess_listen="127.0.0.1"
    mkdir -p "$SB_HOME"
    # 旧配置先备份，绝不直接覆盖丢掉
    if [[ -f "$SB_HOME/config.json" ]]; then
        cp "$SB_HOME/config.json" "$SB_HOME/config.json.bak.$(date +%Y%m%d%H%M%S)"
    fi
    cat > "$SB_HOME/config.json" <<EOF
{
  "log": { "level": "warn", "timestamp": true },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality",
      "listen": "0.0.0.0",
      "listen_port": $REALITY_PORT,
      "users": [{ "uuid": "$UUID", "flow": "xtls-rprx-vision" }],
      "tls": {
        "enabled": true,
        "server_name": "$SNI",
        "reality": {
          "enabled": true,
          "handshake": { "server": "$SNI", "server_port": 443 },
          "private_key": "$REALITY_PRIV",
          "short_id": ["$SHORT_ID"]
        }
      }
    },
    {
      "type": "vmess",
      "tag": "vmess-ws",
      "listen": "$vmess_listen",
      "listen_port": $VMESS_PORT,
      "users": [{ "uuid": "$UUID", "alterId": 0 }],
      "transport": { "type": "ws", "path": "/vmess" }
    },
    {
      "type": "hysteria2",
      "tag": "hy2",
      "listen": "0.0.0.0",
      "listen_port": $HY2_PORT,
      "users": [{ "password": "$HY2_PASS" }],
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "$SB_HOME/cert.pem",
        "key_path": "$SB_HOME/key.pem"
      },
      "masquerade": "https://$SNI"
    },
    {
      "type": "tuic",
      "tag": "tuic",
      "listen": "0.0.0.0",
      "listen_port": $TUIC_PORT,
      "users": [{ "uuid": "$UUID", "password": "$TUIC_PASS" }],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "$SB_HOME/cert.pem",
        "key_path": "$SB_HOME/key.pem"
      }
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" },
    { "type": "block", "tag": "block" }
  ],
  "route": { "final": "direct" }
}
EOF
    chmod 600 "$SB_HOME/config.json"
    "$SB_BIN_DIR/sing-box" check -c "$SB_HOME/config.json" \
        || die "配置文件校验失败，请检查 $SB_HOME/config.json"
    green "配置已写入并通过 sing-box check"
}

write_singbox_service() {
    cat > "$SB_SVC_DIR/sing-box.service" <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org/
After=network.target nss-lookup.target

[Service]
User=root
WorkingDirectory=$SB_HOME
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
ExecStart=$SB_BIN_DIR/sing-box run -c $SB_HOME/config.json
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable sing-box
    # 必须是 restart：重装时服务已在跑，start 对已运行的服务是空操作，旧配置会继续生效
    systemctl restart sing-box
}

# ---------- 固定隧道 ----------
write_tunnel() {
    # TUNNEL_TOKEN / TUNNEL_DOMAIN 由调用方保证非空
    install_cloudflared
    mkdir -p "$SB_CF_DIR"
    cat > "$SB_CF_DIR/config.yml" <<EOF
# Cloudflare 固定隧道（token 只存本机此文件，权限 600）
tunnel: $TUNNEL_TOKEN
no-autoupdate: true
ingress:
  - hostname: $TUNNEL_DOMAIN
    service: http://localhost:$VMESS_PORT
  - service: http_status:404
EOF
    chmod 600 "$SB_CF_DIR/config.yml"
    cat > "$SB_SVC_DIR/cloudflared.service" <<EOF
[Unit]
Description=Cloudflare Tunnel (sing-box VMess)
After=network.target sing-box.service
Wants=sing-box.service

[Service]
User=root
ExecStart=$SB_BIN_DIR/cloudflared tunnel --config $SB_CF_DIR/config.yml run
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now cloudflared
    sleep 3
    if systemctl is-active -q cloudflared; then
        green "cloudflared 已启动"
    else
        red "cloudflared 启动失败，看日志：journalctl -u cloudflared -n 50"
    fi
}

remove_tunnel() {
    check_root; check_systemd
    load_params
    systemctl disable --now cloudflared 2>/dev/null || true
    rm -f "$SB_SVC_DIR/cloudflared.service" "$SB_CF_DIR/config.yml"
    systemctl daemon-reload
    TUNNEL_TOKEN=""; TUNNEL_DOMAIN=""
    save_params
    write_config
    systemctl restart sing-box
    green "隧道已移除，VMess 改回直连"
}

# ---------- BBR ----------
enable_bbr() {
    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
        return 0
    fi
    if ! sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
        yellow "内核不支持 BBR，跳过（不影响安装）"
        return 0
    fi
    echo "开启 BBR（Hysteria2 / TUIC 受益）"
    cat > /etc/sysctl.d/99-sb4-bbr.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    sysctl -p /etc/sysctl.d/99-sb4-bbr.conf >/dev/null 2>&1 || true
}

# ---------- 链接与订阅 ----------
gen_links() {
    # IP 由调用方算一次传进来（避免同一脚本里两次查询拿到不同出口 IP）
    local ip="${1:-$(get_ip)}"
    local vmess_host="$ip" vmess_tls="none" vmess_sni=""
    if [[ -n "${TUNNEL_DOMAIN:-}" ]]; then
        vmess_host="$TUNNEL_DOMAIN"; vmess_tls="tls"; vmess_sni="$TUNNEL_DOMAIN"
    fi
    local vless="vless://${UUID}@${ip}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${SHORT_ID}&type=tcp#${NODE_NAME}-VLESS-REALITY"
    local vmess_json
    vmess_json=$(jq -n -c \
        --arg ps "${NODE_NAME}-VMess-WS" --arg add "$vmess_host" --argjson port "$VMESS_PORT" \
        --arg id "$UUID" --arg host "$vmess_host" --arg tls "$vmess_tls" --arg sni "$vmess_sni" \
        '{v:"2", ps:$ps, add:$add, port:$port, id:$id, aid:"0", scy:"auto", net:"ws", type:"none", host:$host, path:"/vmess", tls:$tls, sni:$sni}')
    local vmess="vmess://$(echo -n "$vmess_json" | base64 -w0)"
    local hy2="hysteria2://${HY2_PASS}@${ip}:${HY2_PORT}/?sni=${SNI}&insecure=1#${NODE_NAME}-HY2"
    local tuic="tuic://${UUID}:${TUIC_PASS}@${ip}:${TUIC_PORT}/?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=${SNI}&allow_insecure=1#${NODE_NAME}-TUIC"
    {
        echo "$vless"; echo "$vmess"; echo "$hy2"; echo "$tuic"
    } > "$LINKS_FILE"
    chmod 600 "$LINKS_FILE"
    base64 -w0 "$LINKS_FILE" > "$SUB_FILE"
}

# ---------- 自检 ----------
# 查服务、配置、端口监听、VMess 探针、隧道探针，逐项打勾/打叉。
# 安装完自动跑一次；平时随时 sb check。
do_check() {
    check_root
    load_params
    local ok=0 fail=0
    say() {
        if [[ "$1" == "ok" ]]; then green "  ✓ $2"; ok=$((ok + 1));
        else red "  ✗ $2"; fail=$((fail + 1)); fi
    }
    blue "=========== sing-box 自检 ==========="
    if systemctl is-active -q sing-box; then say ok "sing-box 服务运行中"; else say fail "sing-box 服务未运行"; fi
    if "$SB_BIN_DIR/sing-box" check -c "$SB_HOME/config.json" >/dev/null 2>&1; then
        say ok "配置文件通过校验"
    else
        say fail "配置文件校验失败"
    fi
    if ss -tln 2>/dev/null | grep -q ":$REALITY_PORT "; then say ok "VLESS+REALITY 端口 $REALITY_PORT 监听中"; else say fail "VLESS+REALITY 端口 $REALITY_PORT 未监听"; fi
    if ss -tln 2>/dev/null | grep -q ":$VMESS_PORT "; then say ok "VMess+WS 端口 $VMESS_PORT 监听中"; else say fail "VMess+WS 端口 $VMESS_PORT 未监听"; fi
    if ss -uln 2>/dev/null | grep -q ":$HY2_PORT "; then say ok "Hysteria2 端口 $HY2_PORT 监听中"; else say fail "Hysteria2 端口 $HY2_PORT 未监听"; fi
    if ss -uln 2>/dev/null | grep -q ":$TUIC_PORT "; then say ok "TUIC 端口 $TUIC_PORT 监听中"; else say fail "TUIC 端口 $TUIC_PORT 未监听"; fi
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' -m 5 "http://127.0.0.1:$VMESS_PORT/vmess" 2>/dev/null || echo 000)
    if [[ "$code" == "400" ]]; then say ok "VMess+WS 本地探针回 400"; else say fail "VMess+WS 本地探针回 $code（应为 400）"; fi
    if [[ -n "${TUNNEL_DOMAIN:-}" ]]; then
        if systemctl is-active -q cloudflared; then say ok "cloudflared 运行中"; else say fail "cloudflared 未运行"; fi
        code=$(curl -s -o /dev/null -w '%{http_code}' -m 10 "https://$TUNNEL_DOMAIN/vmess" 2>/dev/null || echo 000)
        if [[ "$code" == "400" ]]; then say ok "隧道域名探针回 400"; else say fail "隧道域名探针回 $code（应为 400）"; fi
    fi
    echo "------------------------------------------"
    if (( fail == 0 )); then
        green "自检全部通过（$ok 项）"
    else
        red "自检：$ok 通过，$fail 失败"
    fi
    return $(( fail > 0 ))
}

show_info() {
    load_params
    local ip; ip=$(get_ip)
    gen_links "$ip"
    echo
    blue "================ 节点信息 ================"
    echo "服务器 IP：$ip"
    echo "VLESS+REALITY 端口：$REALITY_PORT（TCP）"
    echo "VMess+WS 端口：$VMESS_PORT（TCP）$([[ -n "${TUNNEL_DOMAIN:-}" ]] && echo "，经隧道域名 $TUNNEL_DOMAIN")"
    echo "Hysteria2 端口：$HY2_PORT（UDP）"
    echo "TUIC 端口：$TUIC_PORT（UDP）"
    [[ -n "${TUNNEL_DOMAIN:-}" ]] && echo "固定隧道：$TUNNEL_DOMAIN"
    echo "------------------------------------------"
    cat "$LINKS_FILE"
    echo "------------------------------------------"
    echo "链接已保存：$LINKS_FILE"
    echo "订阅文件（base64）：$SUB_FILE"
    echo "sing-box 状态：$(systemctl is-active sing-box 2>/dev/null || echo 未运行)"
    if [[ -n "${TUNNEL_DOMAIN:-}" ]]; then
        echo "cloudflared 状态：$(systemctl is-active cloudflared 2>/dev/null || echo 未运行)"
    fi
    echo "管理命令：sb"
    blue "=========================================="
}

# ---------- 快捷命令 ----------
install_shortcut() {
    if curl -fsSL -m 15 -o "$SB_BIN_DIR/sb" "$REPO_RAW" 2>/dev/null; then
        chmod +x "$SB_BIN_DIR/sb"
    elif [[ -f "$0" ]]; then
        cp "$0" "$SB_BIN_DIR/sb" && chmod +x "$SB_BIN_DIR/sb"
    else
        yellow "快捷命令 sb 安装失败，以后用 bash install.sh 管理"
        return 0
    fi
    green "快捷命令已安装：以后直接输入 sb 打开菜单"
}

# ---------- 动作 ----------
do_install() {
    check_root; check_systemd; detect_os; detect_arch; resolve_ports
    SNI="${SB_SNI:-$SNI}"
    NODE_NAME="${SB_NODE_NAME:-$NODE_NAME}"
    TUNNEL_TOKEN="${SB_TUNNEL_TOKEN:-}"
    TUNNEL_DOMAIN="${SB_TUNNEL_DOMAIN:-}"
    if [[ -n "$TUNNEL_TOKEN" && -z "$TUNNEL_DOMAIN" ]] || [[ -z "$TUNNEL_TOKEN" && -n "$TUNNEL_DOMAIN" ]]; then
        die "SB_TUNNEL_TOKEN 与 SB_TUNNEL_DOMAIN 必须同时给"
    fi
    install_deps
    install_singbox
    if [[ -f "$PARAMS_FILE" ]]; then
        yellow "检测到已有安装，保留原 UUID / 密码；环境变量给的端口与隧道会覆盖旧值"
        load_params
        SNI="${SB_SNI:-$SNI}"
        NODE_NAME="${SB_NODE_NAME:-$NODE_NAME}"
        TUNNEL_TOKEN="${SB_TUNNEL_TOKEN:-${TUNNEL_TOKEN:-}}"
        TUNNEL_DOMAIN="${SB_TUNNEL_DOMAIN:-${TUNNEL_DOMAIN:-}}"
        if [[ -n "${SB_BASE_PORT:-}" || -n "${SB_REALITY_PORT:-}" || -n "${SB_VMESS_PORT:-}" || -n "${SB_HY2_PORT:-}" || -n "${SB_TUIC_PORT:-}" ]]; then
            resolve_ports
        fi
    else
        gen_secrets
    fi
    gen_cert
    save_params
    write_config
    write_singbox_service
    enable_bbr
    if [[ -n "$TUNNEL_TOKEN" ]]; then
        write_tunnel
    fi
    install_shortcut
    # ufw 开着就顺手放行
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "$REALITY_PORT"/tcp >/dev/null 2>&1 || true
        ufw allow "$VMESS_PORT"/tcp >/dev/null 2>&1 || true
        ufw allow "$HY2_PORT"/udp >/dev/null 2>&1 || true
        ufw allow "$TUIC_PORT"/udp >/dev/null 2>&1 || true
        green "ufw 已放行四个端口"
    else
        yellow "请在云厂商安全组 / 防火墙放行：TCP $REALITY_PORT、$VMESS_PORT，UDP $HY2_PORT、$TUIC_PORT"
    fi
    sleep 2
    systemctl is-active -q sing-box || die "sing-box 启动失败，看日志：journalctl -u sing-box -n 50"
    green "sing-box 安装完成并已启动"
    show_info
    do_check || yellow "自检有失败项，见上面红字"
}

do_tunnel() {
    check_root; check_systemd
    load_params
    local token domain
    if [[ -n "${SB_TUNNEL_TOKEN:-}" && -n "${SB_TUNNEL_DOMAIN:-}" ]]; then
        token="$SB_TUNNEL_TOKEN"; domain="$SB_TUNNEL_DOMAIN"
    else
        read -rp "固定隧道 token（Cloudflare Zero Trust → Networks → Tunnels 里复制）：" token
        read -rp "隧道域名（如 node.example.com，已在隧道里配好 Public Hostname）： " domain
    fi
    [[ -n "$token" && -n "$domain" ]] || die "token 与域名不能为空"
    TUNNEL_TOKEN="$token"; TUNNEL_DOMAIN="$domain"
    save_params
    write_config
    systemctl restart sing-box
    write_tunnel
    show_info
    echo
    echo "验证隧道：curl -s -o /dev/null -w '%{http_code}' https://$domain/vmess（回 400 即通）"
}

do_update() {
    check_root
    SB_VERSION="${SB_VERSION:-}"
    install_singbox
    systemctl restart sing-box
    green "更新完成，当前版本：$("$SB_BIN_DIR/sing-box" version | head -n1)"
}

do_restart() {
    check_root
    systemctl restart sing-box
    [[ -f "$SB_SVC_DIR/cloudflared.service" ]] && systemctl restart cloudflared || true
    systemctl is-active -q sing-box && green "sing-box 已重启，状态 active" || red "sing-box 重启后不是 active，看日志排查"
}

do_uninstall() {
    check_root
    if [[ "${1:-}" != "-y" ]]; then
        read -rp "确认卸载 sing-box 与 cloudflared 并删除配置？[y/N] " ans
        [[ "$ans" == "y" || "$ans" == "Y" ]] || { echo "已取消"; exit 0; }
    fi
    # 逐个停，cloudflared 可能根本没装过（没配隧道时），不能让一个不存在的单元拖垮另一个的停止
    systemctl stop sing-box 2>/dev/null || true
    systemctl stop cloudflared 2>/dev/null || true
    systemctl disable sing-box cloudflared 2>/dev/null || true
    # 兜底：单元文件删掉后残留进程不会自己死，按精确命令行清理（只认本脚本的两个服务，别处的不碰）
    pkill -f "^/usr/local/bin/sing-box run -c /etc/sing-box/config.json$" 2>/dev/null || true
    pkill -f "^/usr/local/bin/cloudflared tunnel --config /etc/cloudflared/config.yml run$" 2>/dev/null || true
    sleep 1
    rm -f "$SB_SVC_DIR/sing-box.service" "$SB_SVC_DIR/cloudflared.service" \
        "$SB_BIN_DIR/sing-box" "$SB_BIN_DIR/cloudflared" "$SB_BIN_DIR/sb" \
        /etc/sysctl.d/99-sb4-bbr.conf
    rm -rf "$SB_HOME" "$SB_CF_DIR"
    systemctl daemon-reload
    green "已卸载干净"
}

menu() {
    check_root
    while true; do
        clear 2>/dev/null || true  # TERM 未设置时也不中断
        blue "=========== sing-box 四合一管理 ==========="
        if [[ -x "$SB_BIN_DIR/sing-box" ]]; then
            echo "sing-box：$("$SB_BIN_DIR/sing-box" version 2>/dev/null | head -n1)"
            echo "运行状态：$(systemctl is-active sing-box 2>/dev/null || echo 未安装)"
        else
            echo "sing-box：未安装"
        fi
        echo "------------------------------------------"
        echo "1. 一键安装（默认端口 443 / 10086 / 8443 / 8444）"
        echo "2. 自定义安装（自填端口、伪装域名）"
        echo "3. 查看节点信息"
        echo "4. 自检（服务、端口、探针、隧道）"
        echo "5. 添加 / 更换固定隧道"
        echo "6. 移除隧道（改回直连）"
        echo "7. 更新 sing-box 内核"
        echo "8. 重启服务"
        echo "9. 卸载"
        echo "0. 退出"
        echo "------------------------------------------"
        read -rp "选一个 [0-9]： " n
        case "$n" in
            1)
                # 一键安装：只问隧道，其他全默认
                read -rp "固定隧道 token（没有直接回车跳过）：" p; SB_TUNNEL_TOKEN="$p"
                if [[ -n "$p" ]]; then
                    read -rp "固定隧道域名：" p; SB_TUNNEL_DOMAIN="$p"
                fi
                export SB_TUNNEL_TOKEN SB_TUNNEL_DOMAIN
                do_install
                ;;
            2)
                # 自定义安装：端口与伪装域名现问现装
                read -rp "VLESS+REALITY 端口 [默认 443]：" p; SB_REALITY_PORT="${p:-443}"
                read -rp "VMess+WS 端口 [默认 10086]：" p; SB_VMESS_PORT="${p:-10086}"
                read -rp "Hysteria2 端口 [默认 8443]：" p; SB_HY2_PORT="${p:-8443}"
                read -rp "TUIC 端口 [默认 8444]：" p; SB_TUIC_PORT="${p:-8444}"
                read -rp "伪装域名 SNI [默认 www.microsoft.com]：" p; SB_SNI="${p:-www.microsoft.com}"
                read -rp "固定隧道 token（没有直接回车跳过）：" p; SB_TUNNEL_TOKEN="$p"
                if [[ -n "$p" ]]; then
                    read -rp "固定隧道域名：" p; SB_TUNNEL_DOMAIN="$p"
                fi
                export SB_REALITY_PORT SB_VMESS_PORT SB_HY2_PORT SB_TUIC_PORT SB_SNI SB_TUNNEL_TOKEN SB_TUNNEL_DOMAIN
                do_install
                ;;
            3) show_info ;;
            4) do_check || true ;;
            5) do_tunnel ;;
            6) remove_tunnel ;;
            7) do_update ;;
            8) do_restart ;;
            9) do_uninstall ;;
            0) exit 0 ;;
            *) red "输 0-9" ;;
        esac
        echo
        read -rp "按回车返回菜单..." _
    done
}

# ---------- 入口 ----------
case "${1:-menu}" in
    install)   do_install ;;
    show)      show_info ;;
    check)     do_check ;;
    update)    do_update ;;
    restart)   do_restart ;;
    uninstall) do_uninstall "${2:-}" ;;
    tunnel)    do_tunnel ;;
    menu)      menu ;;
    *) echo "用法：bash install.sh [install|show|check|update|restart|uninstall|tunnel|menu]"; exit 1 ;;
esac
