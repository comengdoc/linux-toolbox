#!/bin/bash
# =========================================================
# Mihomo 纯净安装脚本 (R5C 专用)
# 功能：下载、安装、配置 Systemd 服务 (不含网络优化)
# =========================================================

# 路径定义
BIN_PATH="/usr/local/bin/mihomo"
CONF_DIR="/etc/mihomo"
SERVICE_FILE="/etc/systemd/system/mihomo.service"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}请使用 root 权限运行${NC}"
  exit 1
fi

function install_mihomo() {
    echo -e "${GREEN}>>> 开始安装 Mihomo...${NC}"
    
    # 1. 架构检测
    ARCH=$(uname -m)
    case "$ARCH" in
        aarch64) M_ARCH="arm64" ;;
        armv7l)  M_ARCH="armv7" ;;
        x86_64)  M_ARCH="amd64" ;;
        *) echo -e "${RED}不支持的架构: $ARCH${NC}"; exit 1 ;;
    esac

    # 2. 下载最新版
    echo "正在获取最新版本信息..."
    # 使用 gh-proxy 代理加速下载
    LATEST_VER=$(curl -s https://api.github.com/repos/MetaCubeX/mihomo/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [ -z "$LATEST_VER" ]; then
        echo -e "${RED}无法获取版本信息，请检查网络。${NC}"
        exit 1
    fi
    
    DOWNLOAD_URL="https://gh-proxy.com/https://github.com/MetaCubeX/mihomo/releases/download/${LATEST_VER}/mihomo-linux-${M_ARCH}-${LATEST_VER}.gz"
    
    echo "下载版本: $LATEST_VER ($M_ARCH)"
    curl -L -o /tmp/mihomo.gz "$DOWNLOAD_URL" --progress-bar
    
    # 3. 解压部署
    gzip -d -f /tmp/mihomo.gz
    mv /tmp/mihomo "$BIN_PATH"
    chmod 755 "$BIN_PATH"
    
    # 4. 配置目录准备
    mkdir -p "$CONF_DIR"
    if [ ! -f "$CONF_DIR/config.yaml" ]; then
        echo "创建基础配置文件..."
        cat > "$CONF_DIR/config.yaml" <<EOF
allow-lan: true
mode: rule
log-level: info
ipv6: true
external-controller: 0.0.0.0:9090
secret: ''
# 配合网络优化脚本的 DNS 劫持
dns:
  enable: true
  listen: 0.0.0.0:1053
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  nameserver:
    - https://dns.alidns.com/dns-query
    - https://doh.pub/dns-query
tun:
  enable: true
  stack: system
  auto-route: true
  auto-detect-interface: true
EOF
    fi

    # 5. 配置 Systemd 服务
    # 注意：这里不再包含 ExecStartPre 脚本，因为网络优化已独立
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Mihomo Daemon
Documentation=https://wiki.metacubex.one
After=network.target r5c-network.service

[Service]
Type=simple
User=root
# 提高文件描述符限制
LimitNPROC=500
LimitNOFILE=1000000
ExecStart=$BIN_PATH -d $CONF_DIR
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable mihomo
    echo -e "${GREEN}✅ 安装完成！服务已设置为开机自启。${NC}"
    echo "配置文件路径: $CONF_DIR/config.yaml"
}

function manage_menu() {
    clear
    echo "=== Mihomo 管理 (纯净版) ==="
    echo "1. 安装/更新 Mihomo"
    echo "2. 启动服务"
    echo "3. 停止服务"
    echo "4. 重启服务"
    echo "5. 查看日志"
    echo "6. 卸载"
    echo "0. 退出"
    
    read -p "请选择: " choice
    case "$choice" in
        1) install_mihomo ;;
        2) systemctl start mihomo && echo "已启动" ;;
        3) systemctl stop mihomo && echo "已停止" ;;
        4) systemctl restart mihomo && echo "已重启" ;;
        5) journalctl -u mihomo -f ;;
        6) 
           systemctl stop mihomo
           systemctl disable mihomo
           rm -f "$BIN_PATH" "$SERVICE_FILE"
           rm -rf "$CONF_DIR"
           systemctl daemon-reload
           echo "已卸载"
           ;;
        0) exit 0 ;;
        *) echo "无效选项" ;;
    esac
}

manage_menu
