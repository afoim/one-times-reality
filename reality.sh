#!/bin/bash
set -e

SERVICE_NAME="sing-box"
CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="${CONFIG_DIR}/config.json"
BIN_FILE="/usr/local/bin/sing-box"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# 强制启用并永久生效 BBR
function enable_bbr() {
    echo "启用 BBR 拥塞控制..."
    # 尝试加载内核模块（若已内置或不存在则忽略错误）
    modprobe tcp_bbr 2>/dev/null || true
    # 开机自动加载模块
    echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
    # 持久化 sysctl
    cat > /etc/sysctl.d/99-bbr.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    # 立即生效
    sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true
    sysctl -p /etc/sysctl.d/99-bbr.conf >/dev/null 2>&1 || sysctl --system >/dev/null 2>&1 || true
    # 校验
    CUR_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
    AVAIL_CC=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "")
    if [ "$CUR_CC" = "bbr" ] || echo "$AVAIL_CC" | grep -qw bbr; then
        echo "BBR 已启用（当前拥塞控制: ${CUR_CC:-unknown}）"
    else
        echo "警告：未检测到 BBR，可用拥塞控制: ${AVAIL_CC}"
    fi
}

function install_singbox() {
    if [ "$(id -u)" -ne 0 ]; then
      echo "请用 root 权限运行此脚本"
      exit 1
    fi

    # 在安装流程最开始启用并持久化 BBR
    enable_bbr

    apt-get update -y
    apt-get install -y curl unzip jq openssl tar

    # 获取最新版本
    LATEST_VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r '.tag_name')
    VERSION=${LATEST_VERSION#v}
    ARCH=$(uname -m)

    case "$ARCH" in
      x86_64)   SB_ARCH="amd64" ;;
      aarch64)  SB_ARCH="arm64" ;;
      armv7l)   SB_ARCH="armv7" ;;
      *) echo "不支持的架构: $ARCH"; exit 1 ;;
    esac

    URL="https://github.com/SagerNet/sing-box/releases/download/${LATEST_VERSION}/sing-box-${VERSION}-linux-${SB_ARCH}.tar.gz"

    echo "下载 sing-box: $URL"
    curl -L -o /tmp/singbox.tar.gz "$URL"
    mkdir -p /tmp/singbox
    tar -xzf /tmp/singbox.tar.gz -C /tmp/singbox
    
    # 兼容不同解压目录结构，定位二进制文件
    if [ -f "/tmp/singbox/sing-box" ]; then
      SRC="/tmp/singbox/sing-box"
    elif [ -f "/tmp/singbox/sing-box-${VERSION}-linux-${SB_ARCH}/sing-box" ]; then
      SRC="/tmp/singbox/sing-box-${VERSION}-linux-${SB_ARCH}/sing-box"
    else
      SRC="$(find /tmp/singbox -type f -name 'sing-box' | head -n1)"
    fi
    
    if [ -z "$SRC" ]; then
      echo "解压后未找到 sing-box 可执行文件"
      exit 1
    fi
    
    mv "$SRC" "$BIN_FILE"
    chmod +x "$BIN_FILE"

    # 生成配置
    UUID=$(cat /proc/sys/kernel/random/uuid)
    KEYPAIR=$($BIN_FILE generate reality-keypair)
    PRIVATE_KEY=$(echo "$KEYPAIR" | grep "PrivateKey" | awk '{print $2}')
    PUBLIC_KEY=$(echo "$KEYPAIR" | grep "PublicKey" | awk '{print $2}')
    PORT=$((RANDOM % 10000 + 10000))  # 10000-20000
    SNI="gateway.icloud.com"
    SHORT_ID=$(openssl rand -hex 4)

    mkdir -p "$CONFIG_DIR"

    # 修复后的配置文件 - 移除了不兼容的 transport 部分
    cat > "$CONFIG_FILE" <<EOF
{
  "log": {
    "level": "info"
  },
  "inbounds": [
    {
      "type": "vless",
      "listen": "::",
      "listen_port": ${PORT},
      "users": [
        {
          "uuid": "${UUID}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${SNI}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${SNI}",
            "server_port": 443
          },
          "private_key": "${PRIVATE_KEY}",
          "short_id": ["${SHORT_ID}"]
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "final": "direct"
  }
}
EOF

    # 验证配置文件
    echo "验证配置文件..."
    if ! $BIN_FILE check -c "$CONFIG_FILE"; then
        echo "配置文件验证失败！"
        exit 1
    fi

    # systemd 服务
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Sing-Box Service
After=network.target

[Service]
ExecStart=$BIN_FILE run -c $CONFIG_FILE
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    systemctl restart "$SERVICE_NAME"
    
    # 等待服务启动
    sleep 3
    
    # 检查服务状态
    if ! systemctl is-active --quiet "$SERVICE_NAME"; then
        echo "服务启动失败！查看日志："
        journalctl -u "$SERVICE_NAME" --no-pager -n 20
        exit 1
    fi

    # 生成 vless:// 链接
    SERVER_IP=$(curl -s ipv4.icanhazip.com)
    VLESS_URL="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=ios&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#Reality"

    echo -e "\n======================"
    echo "Sing-Box Reality 安装完成 ✅"
    echo "服务状态: $(systemctl is-active $SERVICE_NAME)"
    echo "监听端口: $PORT"
    echo "配置文件: $CONFIG_FILE"
    echo -e "\n复制下面的链接使用："
    echo "${VLESS_URL}"
    echo -e "\n管理命令："
    echo "启动服务: systemctl start $SERVICE_NAME"
    echo "停止服务: systemctl stop $SERVICE_NAME"
    echo "查看状态: systemctl status $SERVICE_NAME"
    echo "查看日志: journalctl -u $SERVICE_NAME -f"
    echo "======================"
    
    # 清理临时文件
    rm -rf /tmp/singbox*
}

function uninstall_singbox() {
    echo "正在停止 sing-box 服务..."
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true

    echo "正在删除 systemd 服务文件..."
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload

    echo "正在删除配置文件..."
    rm -rf "$CONFIG_DIR"

    echo "正在删除二进制文件..."
    rm -f "$BIN_FILE"

    echo "卸载完成 ✅"
}

function restart_singbox() {
    echo "重启 sing-box 服务..."
    systemctl restart "$SERVICE_NAME"
    sleep 2
    systemctl status "$SERVICE_NAME" --no-pager -l
}

function status_singbox() {
    echo "=== 服务状态 ==="
    systemctl status "$SERVICE_NAME" --no-pager -l
    
    echo -e "\n=== 监听端口 ==="
    ss -tlnp | grep sing-box || echo "未找到监听端口"
    
    echo -e "\n=== 最近日志 ==="
    journalctl -u "$SERVICE_NAME" --no-pager -n 10
}

function show_config() {
    if [ -f "$CONFIG_FILE" ]; then
        echo "=== 当前配置 ==="
        cat "$CONFIG_FILE"
        
        if [ -f "$CONFIG_FILE" ]; then
            UUID=$(grep -o '"uuid": "[^"]*' "$CONFIG_FILE" | cut -d'"' -f4)
            PORT=$(grep -o '"listen_port": [0-9]*' "$CONFIG_FILE" | awk '{print $2}')
            PRIVATE_KEY=$(grep -o '"private_key": "[^"]*' "$CONFIG_FILE" | cut -d'"' -f4)
            SHORT_ID=$(grep -o '"short_id": \["[^"]*' "$CONFIG_FILE" | cut -d'"' -f3)
            SNI="gateway.icloud.com"
            
            # 从私钥生成公钥
            PUBLIC_KEY=$($BIN_FILE generate reality-keypair --private-key "$PRIVATE_KEY" 2>/dev/null | grep "PublicKey" | awk '{print $2}')
            
            if [ -n "$PUBLIC_KEY" ]; then
                SERVER_IP=$(curl -s ipv4.icanhazip.com 2>/dev/null || echo "YOUR_SERVER_IP")
                VLESS_URL="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#Reality"
                
                echo -e "\n=== 连接信息 ==="
                echo "VLESS URL: ${VLESS_URL}"
            fi
        fi
    else
        echo "配置文件不存在: $CONFIG_FILE"
    fi
}

case "$1" in
    install)
        install_singbox
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
    config)
        show_config
        ;;
    *)
        echo "用法: $0 {install|uninstall|restart|status|config}"
        echo ""
        echo "  install   - 安装 sing-box Reality"
        echo "  uninstall - 卸载 sing-box"
        echo "  restart   - 重启服务"
        echo "  status    - 查看服务状态"
        echo "  config    - 查看配置和连接信息"
        exit 1
        ;;
esac
