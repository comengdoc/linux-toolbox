#!/bin/bash

# =========================================================
# Mihomo TProxy 极智重构跨平台版 (R5C/Ophub Armbian 深度优化版)
# 整合内容：2.5G 吞吐优化 + ICMP 重定向屏蔽 + 内核模块自检
# =========================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

function module_mihomo_tp() {
    AUTO_DIR="/tmp/mihomo"          
    MANUAL_DIR="/root/mihomo"       
    CONF_DIR="/etc/mihomo"          
    BIN_PATH="/usr/local/bin/mihomo" 
    RULE_SCRIPT="/usr/local/bin/mihomo-rules.sh" 
    IFACE_FILE="$CONF_DIR/interface_name" 

    # ==================== 0. 基础环境与依赖自检 ====================
    check_dependencies() {
        echo -e "${BLUE}>>> 正在检查并安装必要依赖...${NC}"
        local cmds=("curl" "gzip" "ethtool" "nft" "ip")
        local missing=()
        
        for cmd in "${cmds[@]}"; do
            if ! command -v "$cmd" >/dev/null 2>&1; then
                missing+=("$cmd")
            fi
        done

        if [ ${#missing[@]} -gt 0 ]; then
            echo -e "${YELLOW}检测到缺少依赖: ${missing[*]}，尝试自动安装...${NC}"
            if command -v apt-get >/dev/null 2>&1; then
                apt-get update && apt-get install -y curl gzip ethtool nftables iproute2
            elif command -v dnf >/dev/null 2>&1; then
                dnf install -y curl gzip ethtool nftables iproute
            elif command -v yum >/dev/null 2>&1; then
                yum install -y curl gzip ethtool nftables iproute
            elif command -v pacman >/dev/null 2>&1; then
                pacman -Sy --noconfirm curl gzip ethtool nftables iproute2
            else
                echo -e "${RED}无法自动安装依赖，请手动安装: curl, gzip, ethtool, nftables, iproute2${NC}"
                exit 1
            fi
        fi
    }

    prepare_env() {
        check_dependencies
        # 【新增】加载关键内核模块，确保 TProxy 和 Bridge 过滤正常
        modprobe br_netfilter 2>/dev/null
        modprobe nf_conntrack 2>/dev/null
        
        if ! id -u mihomo >/dev/null 2>&1; then
            echo -e "${BLUE}>>> 创建代理专用系统用户: mihomo${NC}"
            useradd -r -s /usr/sbin/nologin mihomo
        fi
        mkdir -p "$CONF_DIR"
        chown -R mihomo:mihomo "$CONF_DIR"
    }

    # ==================== 1. 内核与硬件深度优化 ====================
    optimize_sysctl() {
        echo -e "${BLUE}>>> 正在应用针对 R5C 旁路由环境的深度优化...${NC}"
        cat > /etc/sysctl.d/99-mihomo-fusion.conf <<EOF
# 核心转发
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
net.ipv4.ip_nonlocal_bind=1

# 【关键】旁路由防干扰：禁止 ICMP 重定向，防止主路由 AX6000 干扰路径
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.default.send_redirects=0
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0

# 【关键】2.5G 网卡高吞吐优化：增大接收队列与内核缓存
net.core.netdev_max_backlog=16384
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_fastopen=3

# 性能与 BBR
net.netfilter.nf_conntrack_max=1048576
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
        sysctl --system >/dev/null 2>&1
        generate_network_script
        
        if [ ! -f /etc/rc.local ]; then
            echo -e '#!/bin/sh -e\nexit 0' > /etc/rc.local
            chmod +x /etc/rc.local
        fi
        if ! grep -q "$RULE_SCRIPT start" /etc/rc.local; then
            sed -i "/^exit 0/i $RULE_SCRIPT start" /etc/rc.local
        fi

        $RULE_SCRIPT start
        echo -e "${GREEN}✅ 深度优化规则已生效 (已禁用 ICMP 重定向)${NC}"
    }

    # ==================== 2. 核心：nftables 策略逻辑 (保持原有逻辑) ====================
    generate_network_script() {
        echo -e "${BLUE}>>> 生成 nftables 策略管理脚本...${NC}"
        local CPU_COUNT=$(nproc)
        local RPS_MASK=$(printf '%x' $(( (1 << CPU_COUNT) - 1 )))

        cat > "$RULE_SCRIPT" <<EOF
#!/bin/bash
TPROXY_PORT=7894
DNS_PORT=1053
FWMARK=1
TABLE=100
CONF_IFACE="$IFACE_FILE"

apply_hardware_opt() {
    sleep 2
    for iface in \$(ls /sys/class/net | grep -vE "^(lo|tun|docker|veth|br-)"); do
        ethtool -K "\$iface" gro off lro off >/dev/null 2>&1
        for rps_file in /sys/class/net/\$iface/queues/rx-*/rps_cpus; do
            [ -f "\$rps_file" ] && echo "$RPS_MASK" > "\$rps_file" 2>/dev/null
        done
        sysctl -w net.ipv4.conf.\$iface.rp_filter=0 >/dev/null 2>&1
    done
}

get_iface() {
    if [ -f "\$CONF_IFACE" ]; then IFACE=\$(cat "\$CONF_IFACE"); else
        IFACE=\$(ip route show default | awk '/default/ {print \$5}' | head -n1)
    fi
}

enable_rules() {
    apply_hardware_opt
    get_iface
    
    ip rule add fwmark \$FWMARK lookup \$TABLE 2>/dev/null
    ip route add local 0.0.0.0/0 dev lo table \$TABLE 2>/dev/null

    nft add table inet mihomo
    
    if nft "add flowtable inet mihomo ft { hook ingress priority 0; devices = { \$IFACE }; }" 2>/dev/null; then
        nft add chain inet mihomo forward "{ type filter hook forward priority 0; policy accept; }"
        nft add rule inet mihomo forward ip protocol { tcp, udp } flow offload @ft
    else
        : 
    fi

    nft add chain inet mihomo prerouting "{ type filter hook prerouting priority 0; policy accept; }"
    nft add rule inet mihomo prerouting meta nfproto ipv6 reject
    nft add rule inet mihomo prerouting ip daddr { 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } return
    nft add rule inet mihomo prerouting tcp flags syn tcp option maxseg size set rt mtudev
    nft add rule inet mihomo prerouting meta l4proto { tcp, udp } tproxy to :\$TPROXY_PORT meta mark set \$FWMARK

    nft add chain inet mihomo output "{ type route hook output priority 0; policy accept; }"
    nft add rule inet mihomo output ip daddr { 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } return
    nft add rule inet mihomo output skuid mihomo return
    nft add rule inet mihomo output meta l4proto { tcp, udp } meta mark set \$FWMARK

    nft add chain inet mihomo dns_nat "{ type nat hook prerouting priority -100; policy accept; }"
    nft add rule inet mihomo dns_nat udp dport 53 redirect to :\$DNS_PORT
    nft add rule inet mihomo dns_nat tcp dport 53 redirect to :\$DNS_PORT
    
    nft add chain inet mihomo dns_output "{ type nat hook output priority -100; policy accept; }"
    nft add rule inet mihomo dns_output skuid mihomo return
    nft add rule inet mihomo dns_output udp dport 53 redirect to :\$DNS_PORT
    nft add rule inet mihomo dns_output tcp dport 53 redirect to :\$DNS_PORT

    nft add chain inet mihomo postrouting "{ type nat hook postrouting priority 100; policy accept; }"
    nft add rule inet mihomo postrouting iifname "wg0" oifname "\$IFACE" masquerade
}

disable_rules() {
    nft delete table inet mihomo 2>/dev/null
    ip rule del fwmark \$FWMARK lookup \$TABLE 2>/dev/null
    ip route del local 0.0.0.0/0 dev lo table \$TABLE 2>/dev/null
}

case "\$1" in
    start) enable_rules ;;
    stop) disable_rules ;;
    restart) disable_rules; sleep 1; enable_rules ;;
esac
EOF
        chmod +x "$RULE_SCRIPT"
    }

    # ==================== 3. 服务部署 ====================
    setup_service() {
        echo -e "${BLUE}>>> 部署 Systemd 服务 (运行身份: mihomo)...${NC}"
        prepare_env
        generate_network_script

        cat > /etc/systemd/system/mihomo.service <<EOF
[Unit]
Description=mihomo Daemon (nftables + LocalProxy)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=mihomo
Group=mihomo
LimitNPROC=10000
LimitNOFILE=1000000
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStartPre=$RULE_SCRIPT start
ExecStart=$BIN_PATH -d $CONF_DIR
ExecStopPost=$RULE_SCRIPT stop
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable mihomo
    }

    # ==================== 4. 安装逻辑 ====================
    install_online() {
        local ARCH=$(uname -m)
        local MIHOMO_ARCH="amd64"
        [ "$ARCH" == "aarch64" ] && MIHOMO_ARCH="arm64"
        LATEST_VER=$(curl -s https://api.github.com/repos/MetaCubeX/mihomo/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        URL="https://github.com/MetaCubeX/mihomo/releases/download/${LATEST_VER}/mihomo-linux-${MIHOMO_ARCH}-${LATEST_VER}.gz"
        
        check_dependencies
        
        curl -L -o /tmp/mihomo.gz "https://gh-proxy.com/${URL}" --progress-bar
        gzip -d /tmp/mihomo.gz && mv /tmp/mihomo "$BIN_PATH" && chmod 755 "$BIN_PATH"
        chown mihomo:mihomo "$BIN_PATH"
        optimize_sysctl
        setup_service
    }

    install_local() {
        check_dependencies
        [ -f "$AUTO_DIR/mihomo" ] && cp "$AUTO_DIR/mihomo" "$BIN_PATH"
        chmod 755 "$BIN_PATH"
        chown mihomo:mihomo "$BIN_PATH"
        optimize_sysctl
        setup_service
    }

    clear
    echo -e "${GREEN}=== Mihomo TProxy nftables 增强版 (R5C 适配) ===${NC}"
    echo "1. 刷新规则并优化内核 (Flow Offload + 2.5G Tuned)"
    echo "2. 在线安装 (自动配置用户权限)"
    echo "3. 本地安装 (从 /tmp/mihomo 读取)"
    echo "4. 服务管理"
    echo "5. 卸载"
    echo "0. 返回"
    read -p "选择: " OPT < /dev/tty

    case "$OPT" in
        1) optimize_sysctl ;;
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
            systemctl disable --now mihomo 2>/dev/null
            rm -f "$RULE_SCRIPT" "$BIN_PATH" /etc/systemd/system/mihomo.service
            nft delete table inet mihomo 2>/dev/null
            userdel mihomo 2>/dev/null
            echo "已彻底移除。";;
        0) return ;;
    esac
}

module_mihomo_tp