#!/bin/bash

# =========================================================
# Mihomo TProxy 终极修正版 (R5C 专用)
# 适用设备: R5C / N1 / 树莓派 / x86物理机
# 核心修复:
# 1. 【致命修复】解决重启后 GRO/LRO 自动恢复导致的 TProxy 断流问题
# 2. 【性能修复】RPS 覆盖所有 rx-* 队列，突破单核网速瓶颈
# 3. 【稳定性】注入 rc.local 确保硬件参数开机强制生效
# =========================================================

# 定义颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

function module_mihomo_tp() {
    # 定义路径
    AUTO_DIR="/tmp/mihomo"          
    MANUAL_DIR="/root/mihomo"       
    CONF_DIR="/etc/mihomo"          
    BIN_PATH="/usr/local/bin/mihomo" 
    RULE_SCRIPT="/usr/local/bin/mihomo-rules.sh" 
    IFACE_FILE="$CONF_DIR/interface_name" 

    # ==================== 0. 内核与硬件优化 (深度持久化) ====================
    optimize_sysctl() {
        echo -e "${BLUE}>>> 正在应用系统内核优化 (持久化模式)...${NC}"
        
        # 1. 写入 sysctl 配置文件 (永久生效)
        cat > /etc/sysctl.d/99-mihomo-fusion.conf <<EOF
# --- 基础转发 ---
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1

# --- TProxy 关键参数 (必须) ---
net.ipv4.ip_nonlocal_bind=1
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0

# --- 性能优化 ---
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
fs.inotify.max_user_watches=524288
net.netfilter.nf_conntrack_max=262144
net.core.rmem_max=16777216
net.core.wmem_max=16777216
EOF
        sysctl --system >/dev/null 2>&1

        # 2. 生成包含硬件优化的运行时脚本
        generate_network_script
        
        # 3. 注入 rc.local 确保开机即生效 (双保险)
        if [ ! -f /etc/rc.local ]; then
            echo -e '#!/bin/sh -e\nexit 0' > /etc/rc.local
            chmod +x /etc/rc.local
        fi
        if ! grep -q "$RULE_SCRIPT start" /etc/rc.local; then
            sed -i "/^exit 0/i $RULE_SCRIPT start" /etc/rc.local
            echo -e "${GREEN}✅ 已注入 rc.local，硬件优化将在重启后自动保持${NC}"
        fi

        # 立即执行一次
        $RULE_SCRIPT start
        echo -e "${GREEN}✅ 硬件性能优化已刷新 (GRO/LRO已关闭，RPS已启用)${NC}"
    }

    # ==================== 辅助：网络保障脚本 (集成硬件优化) ====================
    generate_network_script() {
        echo -e "${BLUE}>>> 生成 TProxy 网络与硬件管理脚本...${NC}"
        local CPU_COUNT=$(nproc)
        local RPS_MASK=$(printf '%x' $(( (1 << CPU_COUNT) - 1 )))

        cat > "$RULE_SCRIPT" <<EOF
#!/bin/bash
# Mihomo TProxy 网络管理器 (含 R5C 硬件补丁)

# 配置参数
TPROXY_PORT=7894
DNS_PORT=1053
FWMARK=1
TABLE=100
CONF_IFACE="$IFACE_FILE"

# 1. 硬件优化函数 (每次启动强制执行)
apply_hardware_opt() {
    # 增加延时等待网卡就绪
    sleep 3
    echo "  - [Hardware] 正在应用硬件优化 (Mask: $RPS_MASK)..."
    
    # 遍历所有物理网卡
    for iface in \$(ls /sys/class/net | grep -vE "^(lo|tun|docker|veth|cali|flannel|cni|dummy|kube)"); do
        # 【关键修复】遍历所有接收队列 rx-0, rx-1...
        for rps_file in /sys/class/net/\$iface/queues/rx-*/rps_cpus; do
            [ -f "\$rps_file" ] && echo "$RPS_MASK" > "\$rps_file" 2>/dev/null
        done
        
        # 【关键修复】强制关闭 GRO/LRO (防止 TProxy 断流)
        if command -v ethtool >/dev/null 2>&1; then
             ethtool -K "\$iface" gro off lro off >/dev/null 2>&1
        fi
        
        # 确保 rp_filter 关闭
        sysctl -w net.ipv4.conf.\$iface.rp_filter=0 >/dev/null 2>&1
    done
}

# 2. 获取出口网卡
get_iface() {
    if [ -f "\$CONF_IFACE" ]; then
        IFACE=\$(cat "\$CONF_IFACE")
    else
        IFACE=\$(ip route show default | awk '/default/ {print \$5}' | head -n1)
    fi
}

enable_rules() {
    # 先执行硬件优化
    apply_hardware_opt
    get_iface
    
    echo "  - [Network] 初始化 TProxy 规则 (出口: \$IFACE)..."
    
    # 策略路由
    ip rule add fwmark \$FWMARK lookup \$TABLE 2>/dev/null
    ip route add local 0.0.0.0/0 dev lo table \$TABLE 2>/dev/null

    # Mangle 表规则
    iptables -t mangle -N MIHOMO 2>/dev/null
    iptables -t mangle -F MIHOMO
    
    # --- 排除直连网段 ---
    iptables -t mangle -A MIHOMO -d 0.0.0.0/8 -j RETURN
    iptables -t mangle -A MIHOMO -d 10.0.0.0/8 -j RETURN
    iptables -t mangle -A MIHOMO -d 127.0.0.0/8 -j RETURN
    iptables -t mangle -A MIHOMO -d 169.254.0.0/16 -j RETURN
    iptables -t mangle -A MIHOMO -d 172.16.0.0/12 -j RETURN
    iptables -t mangle -A MIHOMO -d 192.168.0.0/16 -j RETURN
    iptables -t mangle -A MIHOMO -d 224.0.0.0/4 -j RETURN
    iptables -t mangle -A MIHOMO -d 240.0.0.0/4 -j RETURN
    
    # 流量打标
    iptables -t mangle -A MIHOMO -p tcp -j TPROXY --on-port \$TPROXY_PORT --tproxy-mark \$FWMARK
    iptables -t mangle -A MIHOMO -p udp -j TPROXY --on-port \$TPROXY_PORT --tproxy-mark \$FWMARK
    
    # 应用到 PREROUTING
    iptables -t mangle -C PREROUTING -j MIHOMO 2>/dev/null || iptables -t mangle -A PREROUTING -j MIHOMO

    # DNS 劫持
    iptables -t nat -N MIHOMO_DNS 2>/dev/null
    iptables -t nat -F MIHOMO_DNS
    iptables -t nat -A MIHOMO_DNS -p udp --dport 53 -j REDIRECT --to-ports \$DNS_PORT
    iptables -t nat -A MIHOMO_DNS -p tcp --dport 53 -j REDIRECT --to-ports \$DNS_PORT
    iptables -t nat -C PREROUTING -j MIHOMO_DNS 2>/dev/null || iptables -t nat -A PREROUTING -j MIHOMO_DNS

    # NAT Masquerade (回程保障)
    if [ -n "\$IFACE" ]; then
        iptables -t nat -C POSTROUTING -o "\$IFACE" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o "\$IFACE" -j MASQUERADE
    fi
}

disable_rules() {
    echo "  - [Network] 清理规则..."
    iptables -t mangle -D PREROUTING -j MIHOMO 2>/dev/null
    iptables -t mangle -F MIHOMO 2>/dev/null
    iptables -t mangle -X MIHOMO 2>/dev/null
    iptables -t nat -D PREROUTING -j MIHOMO_DNS 2>/dev/null
    iptables -t nat -F MIHOMO_DNS 2>/dev/null
    iptables -t nat -X MIHOMO_DNS 2>/dev/null
    ip rule del fwmark \$FWMARK lookup \$TABLE 2>/dev/null
    ip route del local 0.0.0.0/0 dev lo table \$TABLE 2>/dev/null
}

case "\$1" in
    start) enable_rules ;;
    stop) disable_rules ;;
    restart) disable_rules; sleep 1; enable_rules ;;
    uninstall) disable_rules ;;
esac
EOF
        chmod +x "$RULE_SCRIPT"
    }

    # ==================== 网卡配置 ====================
    configure_interface() {
        echo -e "${BLUE}>>> 配置网卡 (TProxy 出口)...${NC}"
        INTERFACES=$(ls /sys/class/net | grep -vE "^(lo|tun|docker|veth|cali|flannel|cni|dummy)")
        [ -d "/sys/class/net/br-lan" ] && INTERFACES="br-lan $(echo "$INTERFACES" | sed 's/br-lan//g')"
        IFACE_LIST=($INTERFACES "自动检测(Auto)")
        
        select iface in "${IFACE_LIST[@]}"; do
            if [ "$iface" == "自动检测(Auto)" ]; then
                rm -f "$IFACE_FILE"
                break
            elif [ -n "$iface" ]; then
                echo "$iface" > "$IFACE_FILE"
                break
            fi
        done
    }

    # ==================== 服务部署 ====================
    setup_service() {
        echo -e "${BLUE}>>> 部署 Systemd 服务...${NC}"
        mkdir -p "$CONF_DIR"
        
        if [ ! -f "$CONF_DIR/config.yaml" ]; then
             if [ -f "$AUTO_DIR/config_tp.yaml" ]; then cp "$AUTO_DIR/config_tp.yaml" "$CONF_DIR/config.yaml";
             elif [ -f "$MANUAL_DIR/config_tp.yaml" ]; then cp "$MANUAL_DIR/config_tp.yaml" "$CONF_DIR/config.yaml"; fi
        fi

        configure_interface
        generate_network_script

        cat > /etc/systemd/system/mihomo.service <<EOF
[Unit]
Description=mihomo Daemon (Pure TProxy)
After=network-online.target time-sync.target
Wants=network-online.target time-sync.target

[Service]
Type=simple
LimitNPROC=500
LimitNOFILE=1000000
Environment="GOGC=20"
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE CAP_SYS_TIME CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE CAP_SYS_TIME CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
Restart=always
RestartSec=5
ExecStartPre=$RULE_SCRIPT start
ExecStart=$BIN_PATH -d $CONF_DIR
ExecStopPost=$RULE_SCRIPT stop
ExecReload=/bin/kill -HUP \$MAINPID

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable mihomo
    }

    # ==================== 安装逻辑 ====================
    install_online() {
        echo -e "${BLUE}>>> 检测架构...${NC}"
        local ARCH=$(uname -m)
        local MIHOMO_ARCH="amd64"
        if [ "$ARCH" == "x86_64" ]; then
            read -p "1.标准 2.高性能(v3): " c < /dev/tty
            [ "$c" == "2" ] && MIHOMO_ARCH="amd64-v3"
        elif [ "$ARCH" == "aarch64" ]; then MIHOMO_ARCH="arm64"
        elif [ "$ARCH" == "armv7l" ]; then MIHOMO_ARCH="armv7"; fi

        LATEST_VER=$(curl -s https://api.github.com/repos/MetaCubeX/mihomo/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        URL="https://github.com/MetaCubeX/mihomo/releases/download/${LATEST_VER}/mihomo-linux-${MIHOMO_ARCH}-${LATEST_VER}.gz"
        
        echo -e "下载中: ${GREEN}$URL${NC}"
        curl -L -o /tmp/mihomo.gz "https://gh-proxy.com/${URL}" --progress-bar
        gzip -d /tmp/mihomo.gz && mv /tmp/mihomo "$BIN_PATH" && chmod 755 "$BIN_PATH"
        optimize_sysctl
        setup_service
    }

    install_local() {
        if [ -f "$AUTO_DIR/mihomo" ]; then cp "$AUTO_DIR/mihomo" "$BIN_PATH";
        elif [ -f "$MANUAL_DIR/mihomo" ]; then cp "$MANUAL_DIR/mihomo" "$BIN_PATH"; fi
        chmod 755 "$BIN_PATH"
        optimize_sysctl
        setup_service
    }

    # ==================== 菜单 ====================
    clear
    echo -e "${GREEN}=== Mihomo TProxy 安装向导 (R5C 修正版) ===${NC}"
    echo "1. 刷新内核与网络规则 (修复重启断流/掉速)"
    echo "2. 在线安装"
    echo "3. 本地/仓库安装"
    echo "4. 服务管理 (启动/停止/日志)"
    echo "5. 卸载"
    echo "0. 返回"
    read -p "选择: " OPT < /dev/tty

    case "$OPT" in
        1) configure_interface; optimize_sysctl ;;
        2) install_online ;;
        3) install_local ;;
        4)
            echo "1.启动 2.停止 3.重启 4.日志"
            read -p ">> " s < /dev/tty
            [ "$s" == "1" ] && systemctl start mihomo
            [ "$s" == "2" ] && systemctl stop mihomo
            [ "$s" == "3" ] && systemctl restart mihomo
            [ "$s" == "4" ] && journalctl -u mihomo -f
            ;;
        5)
            read -p "确认卸载? (y/N): " res < /dev/tty
            if [[ "$res" =~ ^[Yy]$ ]]; then
                systemctl disable --now mihomo 2>/dev/null
                sed -i "/$RULE_SCRIPT start/d" /etc/rc.local
                rm -f "$RULE_SCRIPT" "$BIN_PATH" /etc/systemd/system/mihomo.service
                rm -rf "$CONF_DIR"
                echo "卸载完成。"
            fi
            ;;
        0) return ;;
    esac
}

module_mihomo_tp