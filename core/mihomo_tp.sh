#!/bin/bash

# =========================================================
# Mihomo 终极融合版 (TProxy模式 + 本机代理 + 稳定性优化)
# 适配配置: config_tp.yaml (Port: 7894, DNS: 1053)
# 更新内容: 新增 OUTPUT 链接管，实现本机(Docker Pull)科学上网
# =========================================================

# 定义颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

function module_mihomo_tp() {
    # 定义路径
    AUTO_DIR="/tmp/mihomo"          # 自动下载缓存路径
    MANUAL_DIR="/root/mihomo"       # 手动上传路径
    CONF_DIR="/etc/mihomo"          # 配置文件路径
    BIN_PATH="/usr/local/bin/mihomo" # 二进制文件路径
    RULE_SCRIPT="/usr/local/bin/mihomo-rules.sh" # 网络规则脚本路径

    # ==================== 0. 内核优化 ====================
    optimize_sysctl() {
        echo -e "${BLUE}>>> 正在应用系统内核优化 (TProxy + 本机代理支持)...${NC}"
        cat > /etc/sysctl.d/99-mihomo-fusion.conf <<EOF
# --- 基础转发 ---
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1

# --- TProxy 关键参数 ---
# 允许非本地绑定 (TProxy必须)
net.ipv4.ip_nonlocal_bind=1
# 放宽反向路径过滤 (防止TProxy丢包)
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
net.ipv4.conf.eth0.rp_filter=0

# --- 性能优化 ---
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
fs.inotify.max_user_watches=524288
net.netfilter.nf_conntrack_max=65535
EOF
        sysctl --system >/dev/null 2>&1
        
        echo -e "${GREEN}>>> 内核参数验证:${NC}"
        echo -n "IP转发: "; sysctl net.ipv4.ip_forward
        echo -n "TProxy绑定: "; sysctl net.ipv4.ip_nonlocal_bind
        echo -e "${GREEN}✅ 内核优化完成${NC}"
    }

    # ==================== 辅助：网络保障脚本 (新增本机代理) ====================
    generate_network_script() {
        echo -e "${BLUE}>>> 生成 TProxy 网络接管脚本 (含本机代理)...${NC}"
        
        cat > "$RULE_SCRIPT" <<'EOF'
#!/bin/bash
# Mihomo TProxy 网络管理器 (全流量版)

# 配置参数 (必须与 config_tp.yaml 一致)
TPROXY_PORT=7894
DNS_PORT=1053
FWMARK=1
TABLE=100

# 获取本机 IP (用于 OUTPUT 链排除)
LAN_IP=$(ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n 1)

IFACE=$(ip route show default | awk '/default/ {print $5}' | head -n1)

enable_rules() {
    echo "  - [Network] 正在初始化 TProxy 规则..."
    
    # 1. 基础设置
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null
    ip rule add fwmark $FWMARK lookup $TABLE 2>/dev/null
    ip route add local 0.0.0.0/0 dev lo table $TABLE 2>/dev/null

    # 2. 新建自定义链 MIHOMO
    iptables -t mangle -N MIHOMO 2>/dev/null
    iptables -t mangle -F MIHOMO

    # --- 规则排除区 (直连网段) ---
    # 排除局域网
    iptables -t mangle -A MIHOMO -d 0.0.0.0/8 -j RETURN
    iptables -t mangle -A MIHOMO -d 10.0.0.0/8 -j RETURN
    iptables -t mangle -A MIHOMO -d 127.0.0.0/8 -j RETURN
    iptables -t mangle -A MIHOMO -d 169.254.0.0/16 -j RETURN
    iptables -t mangle -A MIHOMO -d 172.16.0.0/12 -j RETURN
    iptables -t mangle -A MIHOMO -d 192.168.0.0/16 -j RETURN
    iptables -t mangle -A MIHOMO -d 224.0.0.0/4 -j RETURN
    iptables -t mangle -A MIHOMO -d 240.0.0.0/4 -j RETURN
    
    # 【重要】排除本机发往 Mihomo 端口的流量，防止死循环
    # 假设你的机场 IP 很多，这里无法一一排除，所以依靠 "mark" 机制防止循环
    # 但必须排除发往 TProxy 端口本身的流量
    iptables -t mangle -A MIHOMO -p tcp --dport $TPROXY_PORT -j RETURN
    iptables -t mangle -A MIHOMO -p udp --dport $TPROXY_PORT -j RETURN

    # --- 流量打标 ---
    # 关键：给流量打上标记 $FWMARK，配合 ip rule 走 table 100
    iptables -t mangle -A MIHOMO -p tcp -j TPROXY --on-port $TPROXY_PORT --tproxy-mark $FWMARK
    iptables -t mangle -A MIHOMO -p udp -j TPROXY --on-port $TPROXY_PORT --tproxy-mark $FWMARK

    # 3. 应用规则到 PREROUTING (局域网 + Docker Bridge)
    iptables -t mangle -C PREROUTING -j MIHOMO 2>/dev/null || \
    iptables -t mangle -A PREROUTING -j MIHOMO

    # 4. 【新增】应用规则到 OUTPUT (本机 + Docker Host)
    # 这一步让 N1 自己发出的流量也走 TProxy
    echo "    [Proxy] 正在配置本机代理 (OUTPUT链)..."
    
    # 新建 MIHOMO_OUT 链专门处理本机流量
    iptables -t mangle -N MIHOMO_OUT 2>/dev/null
    iptables -t mangle -F MIHOMO_OUT
    
    # 排除部分不需要代理的流量
    iptables -t mangle -A MIHOMO_OUT -d 0.0.0.0/8 -j RETURN
    iptables -t mangle -A MIHOMO_OUT -d 10.0.0.0/8 -j RETURN
    iptables -t mangle -A MIHOMO_OUT -d 127.0.0.0/8 -j RETURN
    iptables -t mangle -A MIHOMO_OUT -d 172.16.0.0/12 -j RETURN
    iptables -t mangle -A MIHOMO_OUT -d 192.168.0.0/16 -j RETURN
    # 排除 Mihomo 运行用户发出的流量 (防止无限循环) - 这里假设是 root 运行，比较难排除
    # 更通用的方法是排除 fwmark (如果应用层已经打标)
    
    # 给本机流量打标 (注意：OUTPUT 链不能用 TPROXY target，只能用 MARK)
    iptables -t mangle -A MIHOMO_OUT -p tcp -j MARK --set-mark $FWMARK
    iptables -t mangle -A MIHOMO_OUT -p udp -j MARK --set-mark $FWMARK
    
    # 将 MIHOMO_OUT 挂载到 OUTPUT 链
    iptables -t mangle -C OUTPUT -j MIHOMO_OUT 2>/dev/null || \
    iptables -t mangle -A OUTPUT -j MIHOMO_OUT

    # 5. DNS 劫持 (53 -> 1053)
    iptables -t nat -N MIHOMO_DNS 2>/dev/null
    iptables -t nat -F MIHOMO_DNS
    iptables -t nat -A MIHOMO_DNS -p udp --dport 53 -j REDIRECT --to-ports $DNS_PORT
    iptables -t nat -A MIHOMO_DNS -p tcp --dport 53 -j REDIRECT --to-ports $DNS_PORT
    
    # 局域网 DNS 劫持
    iptables -t nat -C PREROUTING -j MIHOMO_DNS 2>/dev/null || \
    iptables -t nat -A PREROUTING -j MIHOMO_DNS
    
    # 本机 DNS 劫持 (OUTPUT)
    iptables -t nat -C OUTPUT -j MIHOMO_DNS 2>/dev/null || \
    iptables -t nat -A OUTPUT -j MIHOMO_DNS

    # 6. 开启 NAT (保证回程)
    if [ -n "$IFACE" ]; then
        iptables -t nat -C POSTROUTING -o "$IFACE" -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING -o "$IFACE" -j MASQUERADE
    fi

    echo "    [TProxy] 全局代理已生效 (含本机)"
}

disable_rules() {
    echo "  - [Network] 清理 TProxy 规则..."
    
    # 清理 OUTPUT (本机)
    iptables -t mangle -D OUTPUT -j MIHOMO_OUT 2>/dev/null
    iptables -t mangle -F MIHOMO_OUT 2>/dev/null
    iptables -t mangle -X MIHOMO_OUT 2>/dev/null
    iptables -t nat -D OUTPUT -j MIHOMO_DNS 2>/dev/null

    # 清理 PREROUTING (局域网)
    iptables -t mangle -D PREROUTING -j MIHOMO 2>/dev/null
    iptables -t mangle -F MIHOMO 2>/dev/null
    iptables -t mangle -X MIHOMO 2>/dev/null
    iptables -t nat -D PREROUTING -j MIHOMO_DNS 2>/dev/null

    # 清理公共链
    iptables -t nat -F MIHOMO_DNS 2>/dev/null
    iptables -t nat -X MIHOMO_DNS 2>/dev/null

    # 清理策略路由
    ip rule del fwmark $FWMARK lookup $TABLE 2>/dev/null
    ip route del local 0.0.0.0/0 dev lo table $TABLE 2>/dev/null
}

case "$1" in
    start) enable_rules ;;
    stop) disable_rules ;;
    restart) disable_rules; sleep 1; enable_rules ;;
    uninstall) disable_rules ;;
    *) echo "Usage: $0 {start|stop|restart|uninstall}"; exit 1 ;;
esac
EOF
        chmod +x "$RULE_SCRIPT"
        echo -e "${GREEN}✅ TProxy 网络辅助脚本生成完毕${NC}"
    }

    # ==================== 1. 服务配置函数 ====================
    setup_service() {
        echo -e "${BLUE}>>> 配置 Systemd 服务...${NC}"
        mkdir -p "$CONF_DIR"
        generate_network_script

        if [ ! -f "$CONF_DIR/config.yaml" ]; then
             if [ -f "$AUTO_DIR/config_tp.yaml" ]; then
                 cp "$AUTO_DIR/config_tp.yaml" "$CONF_DIR/config.yaml"
                 echo -e "${GREEN}✅ 已应用仓库文件: config_tp.yaml${NC}"
             elif [ -f "$MANUAL_DIR/config_tp.yaml" ]; then
                 cp "$MANUAL_DIR/config_tp.yaml" "$CONF_DIR/config.yaml"
                 echo -e "${GREEN}✅ 已应用本地文件: config_tp.yaml${NC}"
             elif [ -f "$AUTO_DIR/config.yaml" ]; then
                 cp "$AUTO_DIR/config.yaml" "$CONF_DIR/config.yaml"
             elif [ -f "$MANUAL_DIR/config.yaml" ]; then
                 cp "$MANUAL_DIR/config.yaml" "$CONF_DIR/config.yaml"
             else
                 touch "$CONF_DIR/config.yaml"
                 echo -e "${RED}⚠️ 请注意：你需要自行编辑 $CONF_DIR/config.yaml${NC}"
             fi
        fi

        cat > /etc/systemd/system/mihomo.service <<EOF
[Unit]
Description=mihomo Daemon (TProxy & Optimized)
After=network-online.target time-sync.target
Wants=network-online.target time-sync.target

[Service]
Type=simple
LimitNPROC=500
LimitNOFILE=1000000
Environment="GOGC=20"
# TProxy 需要完整权限
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE CAP_SYS_TIME CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE CAP_SYS_TIME CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
Restart=always
RestartSec=5

# 启动前检测网络
ExecStartPre=/bin/bash -c 'for i in {1..20}; do if ip route show default | grep -q "default"; then echo "Network ready"; exit 0; fi; sleep 1; done; echo "Network not ready"; exit 1'

# 启动规则
ExecStartPre=$RULE_SCRIPT start

ExecStart=$BIN_PATH -d $CONF_DIR

# 停止清理
ExecStopPost=$RULE_SCRIPT stop

ExecReload=/bin/kill -HUP \$MAINPID
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable mihomo
        echo -e "${GREEN}✅ 服务已配置 (开机自启)${NC}"
    }

    # ==================== 安装逻辑 (保持不变) ====================
    install_online() {
        echo -e "${BLUE}>>> 正在获取 Mihomo 版本...${NC}"
        local ARCH=$(uname -m)
        local MIHOMO_ARCH=""
        case "$ARCH" in
            x86_64) MIHOMO_ARCH="amd64" ;;
            aarch64) MIHOMO_ARCH="arm64" ;;
            armv7l) MIHOMO_ARCH="armv7" ;;
            *) echo -e "${RED}不支持的架构${NC}"; return 1 ;;
        esac

        LATEST_VER=$(curl -s -m 5 https://api.github.com/repos/MetaCubeX/mihomo/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        if [ -z "$LATEST_VER" ]; then
            read -p "获取失败，输入版本号 (如 v1.18.5): " LATEST_VER < /dev/tty
        fi
        
        local proxy_prefix="${PROXY_PREFIX:-https://ghproxy.net/}"
        TARGET_URL="https://github.com/MetaCubeX/mihomo/releases/download/${LATEST_VER}/mihomo-linux-${MIHOMO_ARCH}-${LATEST_VER}.gz"
        
        echo -e "正在下载: ${GREEN}${proxy_prefix}${TARGET_URL}${NC}"
        rm -f /tmp/mihomo.gz
        curl -L -o /tmp/mihomo.gz "${proxy_prefix}${TARGET_URL}" --progress-bar

        gzip -d /tmp/mihomo.gz
        mv /tmp/mihomo "$BIN_PATH"
        chmod 755 "$BIN_PATH"
        
        optimize_sysctl
        setup_service
    }

    install_local() {
        echo -e "${GREEN}=== 仓库/本地 部署模式 ===${NC}"
        local SOURCE_FILE=""
        if [ -f "$AUTO_DIR/mihomo" ]; then SOURCE_FILE="$AUTO_DIR/mihomo";
        elif [ -f "$MANUAL_DIR/mihomo" ]; then SOURCE_FILE="$MANUAL_DIR/mihomo";
        else
            echo -e "${RED}❌ 未检测到文件${NC}"
            return 1
        fi
        cp "$SOURCE_FILE" "$BIN_PATH"
        chmod 755 "$BIN_PATH"
        optimize_sysctl
        setup_service
    }

    uninstall_mihomo() {
        systemctl stop mihomo 2>/dev/null
        if [ -f "$RULE_SCRIPT" ]; then bash "$RULE_SCRIPT" stop; rm -f "$RULE_SCRIPT"; fi
        rm -f "$BIN_PATH" /etc/systemd/system/mihomo.service
        systemctl daemon-reload
        rm -rf "$CONF_DIR"
        echo -e "${GREEN}✅ 卸载完成${NC}"
    }

    # ==================== 菜单 ====================
    echo -e "${GREEN}=== Mihomo TProxy (本机代理版) ===${NC}"
    echo "1. 刷新内核与网络规则"
    echo "2. 在线安装"
    echo "3. 本地/仓库安装"
    echo "4. 服务管理"
    echo "5. 卸载"
    echo "0. 返回"
    read -p "选择: " OPT < /dev/tty

    case "$OPT" in
        1) optimize_sysctl; setup_service ;;
        2) install_online ;;
        3) install_local ;;
        4) systemctl restart mihomo; echo "已重启" ;;
        5) uninstall_mihomo ;;
        0) return ;;
        *) echo "无效选择" ;;
    esac
}