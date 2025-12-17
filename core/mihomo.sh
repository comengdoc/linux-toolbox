#!/bin/bash

# =========================================================
# Mihomo 一键安装脚本 (最终修正版: 智能Docker保护 + 端口适配)
# 适配 Config TProxy端口: 7894 | DNS端口: 1053
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
    RULE_SCRIPT="/usr/local/bin/mihomo-rules.sh" # 独立规则管理脚本路径

    # ==================== 0. 内核优化 ====================
    optimize_sysctl() {
        echo -e "${BLUE}>>> 正在应用系统内核优化...${NC}"
        cat > /etc/sysctl.d/99-mihomo-optimized.conf <<EOF
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
fs.inotify.max_user_watches=524288
EOF
        sysctl --system >/dev/null 2>&1
        echo -e "${GREEN}✅ 内核参数优化完成${NC}"
    }

    # ==================== 新增：生成智能网络管理脚本 ====================
    generate_network_script() {
        echo -e "${BLUE}>>> 生成智能网络规则脚本 (${RULE_SCRIPT})...${NC}"
        cat > "$RULE_SCRIPT" <<'EOF'
#!/bin/bash
# Mihomo 智能网络管理器 - 保护 Docker 和 局域网连通性

# --- 配置区 (已根据你的config.yaml修正) ---
T_PORT=7894          # TProxy 端口 (config.yaml: tproxy-port: 7894)
DNS_PORT=1053        # DNS 监听端口 (config.yaml: listen: 0.0.0.0:1053)
T_MARK=1             # 路由标记
CHAIN_NAME="MIHOMO"  # 自定义链名称

# 获取默认网卡
IFACE=$(ip route show default | awk '/default/ {print $5}' | head -n1)

# 1. 基础 NAT 功能 (保证局域网设备能上网，哪怕 Mihomo 挂了)
enable_nat() {
    echo "  - 检查基础 NAT 规则..."
    if [ -n "$IFACE" ]; then
        if ! iptables -t nat -C POSTROUTING -o "$IFACE" -j MASQUERADE 2>/dev/null; then
            iptables -t nat -A POSTROUTING -o "$IFACE" -j MASQUERADE
            echo "    [NAT] 已开启 ($IFACE)"
        fi
    fi
    echo 1 > /proc/sys/net/ipv4/ip_forward
}

# 2. 启用代理规则 (流量劫持 + DNS劫持 + Docker保护)
enable_proxy() {
    echo "  - 正在设置 Mihomo 劫持规则..."
    
    # 2.1 准备自定义链 (Mangle表)
    iptables -t mangle -N $CHAIN_NAME 2>/dev/null || iptables -t mangle -F $CHAIN_NAME

    # --- 白名单 (直连) 区域 ---
    # 这里的关键是 RETURN，即“不处理，交还给系统”，这样 Docker 就能正常工作
    iptables -t mangle -A $CHAIN_NAME -d 0.0.0.0/8 -j RETURN
    iptables -t mangle -A $CHAIN_NAME -d 10.0.0.0/8 -j RETURN
    iptables -t mangle -A $CHAIN_NAME -d 127.0.0.0/8 -j RETURN
    iptables -t mangle -A $CHAIN_NAME -d 169.254.0.0/16 -j RETURN
    iptables -t mangle -A $CHAIN_NAME -d 172.16.0.0/12 -j RETURN  # Docker 默认段
    iptables -t mangle -A $CHAIN_NAME -d 192.168.0.0/16 -j RETURN # 常见局域网
    iptables -t mangle -A $CHAIN_NAME -d 224.0.0.0/4 -j RETURN
    iptables -t mangle -A $CHAIN_NAME -d 240.0.0.0/4 -j RETURN

    # --- 流量打标 (TProxy) ---
    iptables -t mangle -A $CHAIN_NAME -p tcp -j TPROXY --on-port $T_PORT --tproxy-mark $T_MARK
    iptables -t mangle -A $CHAIN_NAME -p udp -j TPROXY --on-port $T_PORT --tproxy-mark $T_MARK

    # --- 挂载到系统入口 (PREROUTING) ---
    if ! iptables -t mangle -C PREROUTING -j $CHAIN_NAME 2>/dev/null; then
        iptables -t mangle -I PREROUTING -j $CHAIN_NAME
    fi

    # --- 策略路由 ---
    ip rule add fwmark $T_MARK table 100 2>/dev/null
    ip route add local 0.0.0.0/0 dev lo table 100 2>/dev/null

    # 2.2 DNS 劫持 (Nat表)
    # 将局域网设备的 UDP 53 请求重定向到 Mihomo 的 1053 端口
    if ! iptables -t nat -C PREROUTING -p udp --dport 53 -j REDIRECT --to-ports $DNS_PORT 2>/dev/null; then
        iptables -t nat -I PREROUTING -p udp --dport 53 -j REDIRECT --to-ports $DNS_PORT
        echo "    [DNS] 劫持已开启 (UDP 53 -> $DNS_PORT)"
    fi
    
    echo "    [Proxy] 规则已生效 (Docker白名单 + DNS劫持)"
}

# 3. 停止代理规则 (保留 NAT，只停劫持)
disable_proxy() {
    echo "  - 正在移除 Mihomo 劫持规则..."
    
    # 清理策略路由
    ip route del local 0.0.0.0/0 dev lo table 100 2>/dev/null
    ip rule del fwmark $T_MARK table 100 2>/dev/null

    # 移除 Mangle 表的钩子
    iptables -t mangle -D PREROUTING -j $CHAIN_NAME 2>/dev/null
    
    # 清空并删除自定义链
    iptables -t mangle -F $CHAIN_NAME 2>/dev/null
    iptables -t mangle -X $CHAIN_NAME 2>/dev/null
    
    # 移除 DNS 劫持 (恢复直连 DNS)
    iptables -t nat -D PREROUTING -p udp --dport 53 -j REDIRECT --to-ports $DNS_PORT 2>/dev/null
    
    echo "    [Proxy] 规则已移除 (DNS已恢复直连，NAT 保持原样)"
}

# 4. 彻底清理 (卸载时用)
cleanup_all() {
    disable_proxy
    # 注意：为了防止全家断网，这里保留 NAT 规则 (iptables -t nat -A POSTROUTING ...)
    # 这样卸载 Mihomo 后，设备依然可以作为普通路由器使用
}

case "$1" in
    start)
        enable_nat
        enable_proxy
        ;;
    stop)
        disable_proxy
        ;;
    restart)
        disable_proxy
        sleep 1
        enable_nat
        enable_proxy
        ;;
    uninstall)
        cleanup_all
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|uninstall}"
        exit 1
esac
EOF
        chmod +x "$RULE_SCRIPT"
        echo -e "${GREEN}✅ 智能规则脚本生成完毕${NC}"
    }

    # ==================== 1. 服务配置函数 (修改版) ====================
    setup_service() {
        echo -e "${BLUE}>>> 配置 Systemd 服务...${NC}"
        mkdir -p "$CONF_DIR"
        
        # 1. 生成辅助脚本
        generate_network_script

        # 2. 配置文件处理
        if [ ! -f "$CONF_DIR/config.yaml" ]; then
             if [ -f "$AUTO_DIR/config.yaml" ]; then
                 cp "$AUTO_DIR/config.yaml" "$CONF_DIR/config.yaml"
             elif [ -f "$MANUAL_DIR/config.yaml" ]; then
                 cp "$MANUAL_DIR/config.yaml" "$CONF_DIR/config.yaml"
             else
                 touch "$CONF_DIR/config.yaml"
                 echo -e "${RED}⚠️ 请自行编辑 $CONF_DIR/config.yaml${NC}"
             fi
        fi

        # 3. Service 文件 (调用上面的脚本，不再写死iptables)
        cat > /etc/systemd/system/mihomo.service <<EOF
[Unit]
Description=mihomo Daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
LimitNPROC=500
LimitNOFILE=1000000
Environment="GOGC=20"
# 赋予必要权限，允许管理网络
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE
Restart=always
RestartSec=5

# 【启动前】调用脚本设置防火墙 (NAT + Proxy + DNS)
ExecStartPre=$RULE_SCRIPT start

# 运行主程序
ExecStart=$BIN_PATH -d $CONF_DIR

# 【停止后】调用脚本清理规则 (只清理Proxy/DNS，保留NAT)
ExecStopPost=$RULE_SCRIPT stop

StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
        
        systemctl daemon-reload
        systemctl enable mihomo
        echo -e "${GREEN}✅ 服务已安装 (已接管智能防火墙规则)${NC}"
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
            return 1
        fi
        cp "$SOURCE_FILE" "$BIN_PATH"
        chmod 755 "$BIN_PATH"
        optimize_sysctl
        setup_service
    }

    # ==================== 4. 卸载函数 (智能清理) ====================
    uninstall_mihomo() {
        echo -e "${RED}⚠️  警告：准备卸载 Mihomo${NC}"
        read -p "确认要卸载吗？(y/N): " confirm < /dev/tty
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then echo "已取消"; return; fi

        echo -e "${BLUE}>>> 停止服务...${NC}"
        
        # 1. 停止服务 (这会自动触发 ExecStopPost 里的脚本，清理掉代理规则)
        systemctl stop mihomo 2>/dev/null
        systemctl disable mihomo 2>/dev/null
        
        # 2. 二次确认清理 (如果 Stop 脚本因某种原因没跑完)
        if [ -f "$RULE_SCRIPT" ]; then
            bash "$RULE_SCRIPT" uninstall
            rm -f "$RULE_SCRIPT"
        fi

        echo -e "${BLUE}>>> 清理文件...${NC}"
        rm -f "$BIN_PATH"
        rm -f /etc/systemd/system/mihomo.service
        rm -f /etc/sysctl.d/99-mihomo-optimized.conf
        systemctl daemon-reload

        if [ -d "$CONF_DIR" ]; then
            read -p "是否保留配置文件? [y/N]: " keep_conf < /dev/tty
            if [[ ! "$keep_conf" =~ ^[Yy]$ ]]; then
                rm -rf "$CONF_DIR"
            fi
        fi
        echo -e "${GREEN}✅ 卸载完成。Docker和网络规则未受破坏。${NC}"
    }

    # ==================== 菜单逻辑 ====================
    echo -e "${GREEN}=== Mihomo 安装向导 (智能Docker保护 + 端口自动适配版) ===${NC}"
    echo "1. 手动应用内核优化"
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
            echo "1) 启动  2) 停止(保留NAT)  3) 重启  4) 日志"
            read -p "操作: " S_OPT < /dev/tty
            case $S_OPT in
                1) systemctl start mihomo; echo "已启动" ;;
                2) systemctl stop mihomo; echo "已停止 (局域网仍可直连)" ;;
                3) systemctl restart mihomo; echo "已重启" ;;
                4) systemctl status mihomo --no-pager ;;
            esac
            ;;
        5) uninstall_mihomo ;;
        0) return ;;
        *) echo "无效选择" ;;
    esac
}