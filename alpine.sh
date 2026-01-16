#!/bin/bash
set -e

SERVICE_NAME="sing-box"
CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="${CONFIG_DIR}/config.json"
BIN_FILE="/usr/local/bin/sing-box"
INIT_FILE="/etc/init.d/${SERVICE_NAME}"

enable_bbr() {
    echo "启用 BBR..."
    modprobe tcp_bbr 2>/dev/null || true

    cat > /etc/sysctl.d/99-bbr.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

    sysctl -p /etc/sysctl.d/99-bbr.conf || true
}

install_singbox() {
    [ "$(id -u)" -eq 0 ] || { echo "请用 root"; exit 1; }

    enable_bbr

    apk add --no-cache curl unzip jq openssl tar iproute2

    LATEST_VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name)
    VERSION=${LATEST_VERSION#v}

    case "$(uname -m)" in
        x86_64) SB_ARCH=amd64 ;;
        aarch64) SB_ARCH=arm64 ;;
        armv7l) SB_ARCH=armv7 ;;
        *) echo "不支持架构"; exit 1 ;;
    esac

    URL="https://github.com/SagerNet/sing-box/releases/download/${LATEST_VERSION}/sing-box-${VERSION}-linux-${SB_ARCH}.tar.gz"
    curl -L -o /tmp/sb.tar.gz "$URL"
    tar -xzf /tmp/sb.tar.gz -C /tmp

    mv /tmp/sing-box*/sing-box "$BIN_FILE"
    chmod +x "$BIN_FILE"

    PORT=${1:-$((RANDOM%10000+10000))}
    UUID=$(cat /proc/sys/kernel/random/uuid)

    KEYPAIR=$($BIN_FILE generate reality-keypair)
    PRIVATE_KEY=$(awk '/PrivateKey/ {print $2}' <<< "$KEYPAIR")
    PUBLIC_KEY=$(awk '/PublicKey/ {print $2}' <<< "$KEYPAIR")
    SHORT_ID=$(openssl rand -hex 4)
    SNI="gateway.icloud.com"

    mkdir -p "$CONFIG_DIR"

    cat > "$CONFIG_FILE" <<EOF
{
  "inbounds":[{
    "type":"vless",
    "listen":"::",
    "listen_port":$PORT,
    "users":[{"uuid":"$UUID","flow":"xtls-rprx-vision"}],
    "tls":{
      "enabled":true,
      "server_name":"$SNI",
      "reality":{
        "enabled":true,
        "handshake":{"server":"$SNI","server_port":443},
        "private_key":"$PRIVATE_KEY",
        "short_id":["$SHORT_ID"]
      }
    }
  }],
  "outbounds":[{"type":"direct"}]
}
EOF

    $BIN_FILE check -c "$CONFIG_FILE"

    cat > "$INIT_FILE" <<EOF
#!/sbin/openrc-run
command="$BIN_FILE"
command_args="run -c $CONFIG_FILE"
command_background="yes"
pidfile="/run/sing-box.pid"
EOF

    chmod +x "$INIT_FILE"
    rc-update add sing-box default
    rc-service sing-box restart

    IP=$(curl -s ipv4.icanhazip.com)
    echo ""
    echo "VLESS:"
    echo "vless://${UUID}@${IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=ios&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}#Reality"
}

uninstall_singbox() {
    rc-service sing-box stop || true
    rc-update del sing-box default || true
    rm -f "$INIT_FILE" "$BIN_FILE"
    rm -rf "$CONFIG_DIR"
    echo "卸载完成"
}

case "$1" in
    install) install_singbox "$2" ;;
    uninstall) uninstall_singbox ;;
    restart) rc-service sing-box restart ;;
    status) rc-service sing-box status ;;
    *) echo "用法: $0 install [端口]" ;;
esac
