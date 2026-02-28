#!/bin/bash

# =========================================================
# Mihomo TProxy + YouTube Turbo 深度融合版 (R5C Armbian 专用)
# 优化重点：CPU 性能锁定、TCP 闲置不减速、硬件中断隔离、Flow Offload
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

    # ==================== 0. 基础环境自检 ====================
    check_dependencies() {
        echo -e "${BLUE}>>> 正在检查并安装必要依赖...${NC}"
        # [cite_start]增加了 cpufrequtils 以支持性能模式锁定 [cite: 1]
        local cmds=("curl" "gzip" "ethtool" "nft" "ip" "cpufreq-set")
        if ! command -v cpufreq-set >/dev/null 2>&1; then
            apt-get update && apt-get install -y cpufrequtils ethtool nftables iproute2 curl gzip
        fi
    }

    prepare_env() {
        check_dependencies
        modprobe br_netfilter 2>/dev/null
        modprobe nf_conntrack 2>/dev/null
        if ! id -u mihomo >/dev/null 2>&1; then
            useradd -r -s /usr/sbin/nologin mihomo
        fi
        mkdir -p "$CONF_DIR"
        chown -R mihomo:mihomo "$CONF_DIR"
    }

    # ==================== 1. 内核与 YouTube TCP 深度优化 ====================
    optimize_sysctl() {
        echo -e "${BLUE}>>> 正在应用针对 YouTube TCP 缓存的极致优化...${NC}"
        cat > /etc/sysctl.d/99-mihomo-fusion.conf <<EOF
# 核心转发与 TProxy 基础
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
net.ipv4.ip_nonlocal_bind=1

# 旁路由防干扰：禁止 ICMP 重定向
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.default.send_redirects=0
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0

# YouTube TCP 专项补丁：禁用闲置慢启动，防止视频缓存断流
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_mtu_probing=1

# 2.5G 网卡高吞吐大缓冲区 (64MB)
net.core.netdev_max_backlog=16384
net.core.rmem_max=33554432
net.core.wmem_max=33554432
net.ipv4.tcp_rmem=4096 87380 33554432
net.ipv4.tcp_wmem=4096 65536 33554432

# BBR + FQ 调度
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.netfilter.nf_conntrack_max=1048576
EOF
        sysctl --system >/dev/null 2>&1
        generate_network_script
        $RULE_SCRIPT start
        echo -e "${GREEN}✅ 内核参数已优化：BBR 激活，TCP 慢启动已禁用${NC}"
    }

    # ==================== 2. 核心：硬件流水线与 nftables ====================
    generate_network_script() {
        echo -e "${BLUE}>>> 正在生成增强型硬件加速与规则脚本 (已修正变量逃逸)...${NC}"
        
        # 使用 <<'EOF' (带引号) 确保内部的 $ 和变量不被当前 Shell 提前解析
        cat > "$RULE_SCRIPT" <<'EOF'
#!/bin/bash
TPROXY_PORT=7894
DNS_PORT=1053
FWMARK=1
TABLE=100

apply_hardware_opt() {
    # 1. 锁定 CPU 性能模式
    for i in $(seq 0 3); do cpufreq-set -c $i -g performance; done
    
    # 2. 针对 R5C 的网卡进行全队列绑定 (RSS 流哈希)
    # 自动获取物理网卡名
    local IFACE=$(ip route show default | awk '/default/ {print $5}' | head -n1)
    # 修复：使用 awk 提取 IRQ 并清除多余空格，确保路径正确
    local IRQS=$(grep "$IFACE" /proc/interrupts | awk -F: '{print $1}' | xargs)
    
    # 将中断均匀分配到 CPU 1, 2, 3 (位掩码 2, 4, 8)
    local cpus=(2 4 8)
    local i=0
    for irq in $IRQS; do
        if [ -n "$irq" ]; then
            echo "${cpus[$((i % 3))]}" > "/proc/irq/$irq/smp_affinity"
            ((i++))
        fi
    done

    # 3. 关闭软件分流 RPS (避免跨核内存拷贝开销)
    for rps_file in /sys/class/net/$IFACE/queues/rx-*/rps_cpus; do
        echo "0" > "$rps_file" 2>/dev/null
    done
    
    # 4. 网卡底层调优：开启 GRO，关闭可能导致代理异常的 LRO
    ethtool -K "$IFACE" gro on gso on tso on lro off >/dev/null 2>&1
}

enable_rules() {
    apply_hardware_opt
    
    # 清理旧规则并设置路由表
    ip rule del fwmark $FWMARK lookup $TABLE 2>/dev/null
    ip rule add fwmark $FWMARK lookup $TABLE
    ip route add local 0.0.0.0/0 dev lo table $TABLE 2>/dev/null

    # 构造 nftables 规则 (已移除 Flow Offload)
    nft delete table inet mihomo 2>/dev/null
    nft add table inet mihomo
    
    nft add chain inet mihomo prerouting "{ type filter hook prerouting priority 0; policy accept; }"
    # 局域网白名单绕过
    nft add rule inet mihomo prerouting ip daddr { 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } return
    # TCP MSS 修正：防止 MTU 问题导致打不开网页
    nft add rule inet mihomo prerouting tcp flags syn tcp option maxseg size set rt mtudev
    # TProxy 核心流量接管
    nft add rule inet mihomo prerouting meta l4proto { tcp, udp } tproxy to :$TPROXY_PORT meta mark set $FWMARK

    # 处理本机发出的流量
    nft add chain inet mihomo output "{ type route hook output priority 0; policy accept; }"
    nft add rule inet mihomo output skuid mihomo return
    nft add rule inet mihomo output meta l4proto { tcp, udp } meta mark set $FWMARK

    # DNS 劫持
    nft add chain inet mihomo dns_nat "{ type nat hook prerouting priority -100; policy accept; }"
    nft add rule inet mihomo dns_nat udp dport 53 redirect to :$DNS_PORT
}

disable_rules() {
    nft delete table inet mihomo 2>/dev/null
    ip rule del fwmark $FWMARK lookup $TABLE 2>/dev/null
    ip route del local 0.0.0.0/0 dev lo table $TABLE 2>/dev/null
}

case "$1" in
    start) enable_rules ;;
    stop) disable_rules ;;
    restart) disable_rules; sleep 1; enable_rules ;;
esac
EOF
        chmod +x "$RULE_SCRIPT"
        echo -e "${GREEN}✅ 规则脚本生成成功，Flow Offload 已彻底移除${NC}"
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

# 检查配置文件 (以 mihomo 用户身份执行即可)
ExecStartPre=/usr/bin/test -f ${CONF_DIR}/config.yaml

# 核心修正：添加 '+' 前缀，强制网络规则和硬件调优脚本以 root 权限执行
ExecStartPre=+${RULE_SCRIPT} start
ExecStopPost=+${RULE_SCRIPT} stop

# 代理核心本身安全地以 mihomo 身份运行
ExecStart=${BIN_PATH} -d ${CONF_DIR}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable mihomo
        echo -e "${GREEN}✅ Systemd 服务部署完成 (已修正提权执行逻辑)${NC}"
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
        echo -e "${YELLOW}请确保已在 $CONF_DIR 内存放 config.yaml 后再启动服务。${NC}"
    }

    install_local() {
        check_dependencies
        [ -f "$AUTO_DIR/mihomo" ] && cp "$AUTO_DIR/mihomo" "$BIN_PATH"
        chmod 755 "$BIN_PATH"
        chown mihomo:mihomo "$BIN_PATH"
        optimize_sysctl
        setup_service
        echo -e "${YELLOW}请确保已在 $CONF_DIR 内存放 config.yaml 后再启动服务。${NC}"
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