#!/bin/bash
set -e

SERVICE_NAME="sing-box"
CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="${CONFIG_DIR}/config.json"
BIN_FILE="/usr/local/bin/sing-box"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

#################################
# 强制启用并永久生效 BBR
#################################
enable_bbr() {
    echo "启用 BBR 拥塞控制..."

    modprobe tcp_bbr 2>/dev/null || true
    echo "tcp_bbr" > /etc/modules-load.d/bbr.conf

    cat > /etc/sysctl.d/99-bbr.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

    sysctl --system >/dev/null 2>&1 || true

    CUR_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
    if [ "$CUR_CC" = "bbr" ]; then
        echo "BBR 已启用 ✅"
    else
        echo "⚠️ BBR 启用失败（当前: $CUR_CC）"
    fi
}

#################################
# 安装 sing-box
#################################
install_singbox() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "请使用 root 运行"
        exit 1
    fi

    enable_bbr

    apt update -y
    apt install -y curl unzip jq openssl tar

    # 获取最新版本
    LATEST_VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r '.tag_name')
    VERSION=${LATEST_VERSION#v}

    # 架构判断
    case "$(uname -m)" in
        x86_64) SB_ARCH="amd64" ;;
        aarch64) SB_ARCH="arm64" ;;
        armv7l) SB_ARCH="armv7" ;;
        *) echo "不支持的架构"; exit 1 ;;
    esac

    URL="https://github.com/SagerNet/sing-box/releases/download/${LATEST_VERSION}/sing-box-${VERSION}-linux-${SB_ARCH}.tar.gz"
    echo "下载 sing-box: $URL"

    curl -L -o /tmp/singbox.tar.gz "$URL"
    mkdir -p /tmp/singbox
    tar -xzf /tmp/singbox.tar.gz -C /tmp/singbox

    SRC=$(find /tmp/singbox -type f -name sing-box | head -n1)
    mv "$SRC" "$BIN_FILE"
    chmod +x "$BIN_FILE"

    #################################
    # 端口设置（支持手动指定）
    #################################
    if [ -n "$1" ] && [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; then
        PORT="$1"
        echo "使用指定端口: $PORT"
    else
        PORT=$((RANDOM % 10000 + 10000))
        echo "使用随机端口: $PORT"
    fi

    #################################
    # 生成 Reality 配置
    #################################
    UUID=$(cat /proc/sys/kernel/random/uuid)
    KEYPAIR=$($BIN_FILE generate reality-keypair)
    PRIVATE_KEY=$(echo "$KEYPAIR" | awk '/PrivateKey/ {print $2}')
    PUBLIC_KEY=$(echo "$KEYPAIR" | awk '/PublicKey/ {print $2}')
    SHORT_ID=$(openssl rand -hex 4)
    SNI="gateway.icloud.com"

    mkdir -p "$CONFIG_DIR"

    cat > "$CONFIG_FILE" <<EOF
{
  "log": {
    "level": "info"
  },
  "inbounds": [
    {
      "type": "vless",
      "listen": "::",
      "listen_port": $PORT,
      "users": [
        {
          "uuid": "$UUID",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$SNI",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "$SNI",
            "server_port": 443
          },
          "private_key": "$PRIVATE_KEY",
          "short_id": ["$SHORT_ID"]
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct"
    }
  ]
}
EOF

    echo "验证配置文件..."
    $BIN_FILE check -c "$CONFIG_FILE"

    #################################
    # systemd 服务
    #################################
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Sing-Box Service
After=network.target

[Service]
ExecStart=$BIN_FILE run -c $CONFIG_FILE
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable sing-box
    systemctl restart sing-box

    sleep 2
    systemctl is-active --quiet sing-box || {
        journalctl -u sing-box -n 20
        exit 1
    }

    #################################
    # 输出连接信息
    #################################
    SERVER_IP=$(curl -s ipv4.icanhazip.com)
    VLESS_URL="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=ios&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#Reality"

    echo ""
    echo "=============================="
    echo "✅ Sing-box Reality 安装完成"
    echo "端口: $PORT"
    echo ""
    echo "VLESS 链接："
    echo "$VLESS_URL"
    echo "=============================="

    rm -rf /tmp/singbox*
}

#################################
# 其他命令
#################################
uninstall_singbox() {
    systemctl stop sing-box 2>/dev/null || true
    systemctl disable sing-box 2>/dev/null || true
    rm -f "$SERVICE_FILE"
    rm -rf "$CONFIG_DIR"
    rm -f "$BIN_FILE"
    systemctl daemon-reload
    echo "卸载完成 ✅"
}

restart_singbox() {
    systemctl restart sing-box
    systemctl status sing-box --no-pager
}

status_singbox() {
    systemctl status sing-box --no-pager
    ss -tlnp | grep sing-box || true
}

#################################
# 命令分发
#################################
case "$1" in
    install)
        install_singbox "$2"
        ;;
    uninstall)
        uninstall_singbox
        ;;
    restart)
        restart_singbox
        ;;
    status)
        status_singbox
        ;;
    *)
        echo "用法:"
        echo "  $0 install [端口]"
        echo "  $0 uninstall"
        echo "  $0 restart"
        echo "  $0 status"
        ;;
esac