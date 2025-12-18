#!/bin/bash

# =========================================================
# Mihomo 一键安装脚本 (TUN 模式专用版)
# 说明: 仅保留系统转发与NAT，流量接管由 Mihomo TUN 负责
# =========================================================

# 定义颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

function module_mihomo() {
    # 定义路径
    AUTO_DIR="/tmp/mihomo"
    MANUAL_DIR="/root/mihomo"
    CONF_DIR="/etc/mihomo"
    BIN_PATH="/usr/local/bin/mihomo"
    RULE_SCRIPT="/usr/local/bin/mihomo-rules.sh"

    # ==================== 0. 内核优化 (严格满足 TUN 需求) ====================
    optimize_sysctl() {
        echo -e "${BLUE}>>> 正在配置 TUN 模式所需的内核参数...${NC}"
        
        # 写入配置文件，确保重启后依然生效
        cat > /etc/sysctl.d/99-mihomo-tun.conf <<EOF
# 开启 IPv4 转发
net.ipv4.ip_forward = 1
# 开启 IPv6 转发
net.ipv6.conf.all.forwarding = 1
# 开启 Source Valid Mark (TUN模式防止环路的关键)
net.ipv4.conf.all.src_valid_mark = 1
EOF
        
        # 立即应用
        sysctl --system >/dev/null 2>&1
        
        # 二次验证并输出状态
        echo -e "${GREEN}>>> 内核参数验证:${NC}"
        sysctl net.ipv4.ip_forward
        sysctl net.ipv6.conf.all.forwarding
        sysctl net.ipv4.conf.all.src_valid_mark
        echo -e "${GREEN}✅ 内核优化完成${NC}"
    }

    # ==================== 新增：基础网络保障脚本 (仅 NAT) ====================
    generate_network_script() {
        echo -e "${BLUE}>>> 生成基础网络脚本 (${RULE_SCRIPT})...${NC}"
        cat > "$RULE_SCRIPT" <<'EOF'
#!/bin/bash
# Mihomo 基础网络管理器 (TUN 模式版)
# 作用: 仅负责开启 NAT，确保局域网设备能上网。
#       具体的流量劫持由 Mihomo Config 中的 tun.auto-route: true 处理。

# 获取默认出网网卡
IFACE=$(ip route show default | awk '/default/ {print $5}' | head -n1)

enable_nat() {
    echo "  - [Network] 检查基础 NAT 转发规则..."
    
    # 再次强制刷新内核参数 (防止被其他程序覆盖)
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null
    sysctl -w net.ipv4.conf.all.src_valid_mark=1 >/dev/null

    if [ -n "$IFACE" ]; then
        # 如果没有 masquerade 规则则添加，保证局域网设备能上网
        if ! iptables -t nat -C POSTROUTING -o "$IFACE" -j MASQUERADE 2>/dev/null; then
            iptables -t nat -A POSTROUTING -o "$IFACE" -j MASQUERADE
            echo "    [NAT] 已开启 ($IFACE) - 允许局域网共享上网"
        else
            echo "    [NAT] 规则已存在，跳过"
        fi
    else
        echo "    [警告] 未检测到默认网卡，跳过 NAT 设置"
    fi
}

disable_nat() {
    # 停止时通常不需要删除 NAT，以免造成瞬间断网。
    # 如果一定要彻底还原，可以取消下面注释，但建议保留以维持网络连通性。
    # iptables -t nat -D POSTROUTING -o "$IFACE" -j MASQUERADE 2>/dev/null
    echo "  - [Network] 服务停止 (NAT 规则保持不变)"
}

case "$1" in
    start)
        enable_nat
        ;;
    stop)
        disable_nat
        ;;
    restart)
        disable_nat
        sleep 1
        enable_nat
        ;;
    uninstall)
        # 卸载时可选择清理 NAT，此处保留以防失联
        echo "保留 NAT 规则以维持网络连接。"
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|uninstall}"
        exit 1
esac
EOF
        chmod +x "$RULE_SCRIPT"
        echo -e "${GREEN}✅ 网络辅助脚本生成完毕${NC}"
    }

    # ==================== 1. 服务配置函数 ====================
    setup_service() {
        echo -e "${BLUE}>>> 配置 Systemd 服务...${NC}"
        mkdir -p "$CONF_DIR"
        
        generate_network_script

        # 配置文件检查
        if [ ! -f "$CONF_DIR/config.yaml" ]; then
             if [ -f "$AUTO_DIR/config.yaml" ]; then
                 cp "$AUTO_DIR/config.yaml" "$CONF_DIR/config.yaml"
             elif [ -f "$MANUAL_DIR/config.yaml" ]; then
                 cp "$MANUAL_DIR/config.yaml" "$CONF_DIR/config.yaml"
             else
                 touch "$CONF_DIR/config.yaml"
                 echo -e "${RED}⚠️  注意: 请自行编辑 $CONF_DIR/config.yaml 并开启 TUN 模式!${NC}"
             fi
        fi

        # Service 文件
        cat > /etc/systemd/system/mihomo.service <<EOF
[Unit]
Description=mihomo Daemon (TUN Mode)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
LimitNPROC=500
LimitNOFILE=1000000
Environment="GOGC=20"
# TUN 模式需要完整的网络权限
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE
Restart=always
RestartSec=5

# 【启动前】确保内核参数正确，开启 NAT
ExecStartPre=$RULE_SCRIPT start

# 运行主程序
ExecStart=$BIN_PATH -d $CONF_DIR

# 【停止后】
ExecStopPost=$RULE_SCRIPT stop

StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
        
        systemctl daemon-reload
        systemctl enable mihomo
        echo -e "${GREEN}✅ 服务已安装 (TUN 模式准备就绪)${NC}"
    }

    # ==================== 2. 在线下载 ====================
    install_online() {
        echo -e "${BLUE}>>> 正在检测系统架构...${NC}"
        local ARCH=$(uname -m)
        local MIHOMO_ARCH=""
        case "$ARCH" in
            x86_64) MIHOMO_ARCH="amd64" ;;
            aarch64) MIHOMO_ARCH="arm64" ;;
            armv7l) MIHOMO_ARCH="armv7" ;;
            *) echo -e "${RED}不支持的架构: $ARCH${NC}"; return 1 ;;
        esac
        LATEST_VER=$(curl -s -m 5 https://api.github.com/repos/MetaCubeX/mihomo/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        if [ -z "$LATEST_VER" ]; then
            read -p "获取失败，请输入欲安装的版本号: " LATEST_VER < /dev/tty
        fi
        local proxy_prefix="${PROXY_PREFIX:-https://ghproxy.net/}"
        TARGET_URL="https://github.com/MetaCubeX/mihomo/releases/download/${LATEST_VER}/mihomo-linux-${MIHOMO_ARCH}-${LATEST_VER}.gz"
        PROXY_URL="${proxy_prefix}${TARGET_URL}"
        rm -f /tmp/mihomo.gz
        curl -L -o /tmp/mihomo.gz "$PROXY_URL" --progress-bar
        gzip -d /tmp/mihomo.gz
        mv /tmp/mihomo "$BIN_PATH"
        chmod 755 "$BIN_PATH"
        optimize_sysctl
        setup_service
    }

    # ==================== 3. 仓库/本地安装 ====================
    install_local() {
        echo -e "${GREEN}=== 仓库/本地 部署模式 ===${NC}"
        local SOURCE_FILE=""
        if [ -f "$AUTO_DIR/mihomo" ]; then
            SOURCE_FILE="$AUTO_DIR/mihomo"
        elif [ -f "$MANUAL_DIR/mihomo" ]; then
             SOURCE_FILE="$MANUAL_DIR/mihomo"
        else
            echo -e "${RED}未找到 mihomo 文件${NC}"
            return 1
        fi
        cp "$SOURCE_FILE" "$BIN_PATH"
        chmod 755 "$BIN_PATH"
        optimize_sysctl
        setup_service
    }

    # ==================== 4. 卸载函数 ====================
    uninstall_mihomo() {
        echo -e "${RED}⚠️  警告：准备卸载 Mihomo${NC}"
        read -p "确认要卸载吗？(y/N): " confirm < /dev/tty
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then echo "已取消"; return; fi

        echo -e "${BLUE}>>> 停止服务...${NC}"
        systemctl stop mihomo 2>/dev/null
        systemctl disable mihomo 2>/dev/null
        
        if [ -f "$RULE_SCRIPT" ]; then
            bash "$RULE_SCRIPT" uninstall
            rm -f "$RULE_SCRIPT"
        fi

        echo -e "${BLUE}>>> 清理文件...${NC}"
        rm -f "$BIN_PATH"
        rm -f /etc/systemd/system/mihomo.service
        # 不删除 sysctl 配置，保留优化参数
        systemctl daemon-reload

        if [ -d "$CONF_DIR" ]; then
            read -p "是否保留配置文件? [y/N]: " keep_conf < /dev/tty
            if [[ ! "$keep_conf" =~ ^[Yy]$ ]]; then
                rm -rf "$CONF_DIR"
            fi
        fi
        echo -e "${GREEN}✅ 卸载完成。${NC}"
    }

    # ==================== 菜单逻辑 ====================
    echo -e "${GREEN}=== Mihomo 安装向导 (纯 TUN 模式版) ===${NC}"
    echo "1. 手动应用内核优化 (ipv4/ipv6/src_valid_mark)"
    echo "2. 在线安装"
    echo "3. 部署仓库版本 (推荐)"
    echo "4. 服务管理"
    echo -e "${RED}5. 卸载 Mihomo${NC}"
    echo "0. 返回"
    
    read -p "请选择: " OPT < /dev/tty

    case "$OPT" in
        1) optimize_sysctl ;;
        2) install_online ;;
        3) install_local ;;
        4)
            echo "1) 启动  2) 停止  3) 重启  4) 日志"
            read -p "操作: " S_OPT < /dev/tty
            case $S_OPT in
                1) systemctl start mihomo; echo "已启动" ;;
                2) systemctl stop mihomo; echo "已停止" ;;
                3) systemctl restart mihomo; echo "已重启" ;;
                4) systemctl status mihomo --no-pager ;;
            esac
            ;;
        5) uninstall_mihomo ;;
        0) return ;;
        *) echo "无效选择" ;;
    esac
}
