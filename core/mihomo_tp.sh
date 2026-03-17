#!/bin/bash

# =========================================================
# Mihomo TProxy + YouTube Turbo + Docker 深度融合版
# 适配硬件：友善 NanoPi R5C
# 适配环境：Armbian (Debian 13)
# 优化重点：Docker 桥接转发、IRQ 队列散列、TCP 闲置加速
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

    # ==================== 0. 环境检查与 Docker 依赖 ====================
    check_dependencies() {
        echo -e "${BLUE}>>> 正在检查必要系统组件...${NC}"
        # 补充 procps 以支持更稳定的 sysctl 操作
        local pkgs=("curl" "gzip" "ethtool" "nftables" "iproute2" "cpufrequtils" "procps")
        apt-get update && apt-get install -y "${pkgs[@]}"
    }

    prepare_env() {
        check_dependencies
        # 关键：加载 Docker 与透明代理所需的内核模块
        modprobe br_netfilter 2>/dev/null
        modprobe nf_conntrack 2>/dev/null
        if ! id -u mihomo >/dev/null 2>&1; then
            useradd -r -s /usr/sbin/nologin mihomo
        fi
        mkdir -p "$CONF_DIR"
        chown -R mihomo:mihomo "$CONF_DIR"
    }

    # ==================== 1. 内核与 YouTube/Docker 深度优化 ====================
    optimize_sysctl() {
        echo -e "${BLUE}>>> 正在配置内核参数 (含 Docker 桥接优化)...${NC}"
        cat > /etc/sysctl.d/99-mihomo-fusion.conf <<EOF
# 核心转发基础
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
net.ipv4.ip_nonlocal_bind=1

# Docker 桥接流量接管
# 允许 Netfilter 处理网桥上的数据包，确保容器流量进入 nftables
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.bridge.bridge-nf-call-arptables=1

# 旁路由防干扰
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.default.send_redirects=0
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0

# YouTube TCP 专项加速
# 禁用闲置慢启动，防止视频缓冲断流
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_mtu_probing=1

# 2.5G 网卡高吞吐大缓冲区 (64MB)
net.core.netdev_max_backlog=16384
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864

# BBR + FQ 调度
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.netfilter.nf_conntrack_max=1048576
EOF
        sysctl --system >/dev/null 2>&1
        generate_network_script
        $RULE_SCRIPT start
        echo -e "${GREEN}✅ 系统参数已更新：BBR 已激活，Docker 桥接已关联${NC}"
    }

    # ==================== 2. 硬件中断与规则脚本 ====================
    generate_network_script() {
        echo -e "${BLUE}>>> 正在生成 R5C 硬件优化与 nftables 规则...${NC}"
        
        cat > "$RULE_SCRIPT" <<'EOF'
#!/bin/bash
TPROXY_PORT=7894
DNS_PORT=1053
FWMARK=1
TABLE=100

apply_hardware_opt() {
    # 1. 锁定 R5C 四核性能模式
    for i in $(seq 0 3); do cpufreq-set -c $i -g performance 2>/dev/null; done
    
    # 2. 获取主网卡名称
    local IFACE=$(ip route show default | awk '/default/ {print $5}' | head -n1)
    [ -z "$IFACE" ] && return

    # 3. 硬件中断 (IRQ) 绑定：固定至 CPU 2 (掩码 4)
    local IRQS=$(grep "$IFACE" /proc/interrupts | awk '{print $1}' | tr -d ':')
    for irq in $IRQS; do
        if [[ "$irq" =~ ^[0-9]+$ ]]; then
            echo "4" > "/proc/irq/$irq/smp_affinity" 2>/dev/null
        fi
    done

    # 4. 开启 RPS 软件分流：绑定 CPU 1, 3 (掩码 a)
    for rps_file in /sys/class/net/$IFACE/queues/rx-*/rps_cpus; do
        echo "a" > "$rps_file" 2>/dev/null
    done

    # 5. 【核心修正】强制关闭 GRO/LRO 防单臂折返分片丢包
    ethtool -K "$IFACE" gro off lro off gso on tso on >/dev/null 2>&1
    
    # 6. 增大网卡接收队列
    ip link set dev "$IFACE" txqueuelen 5000 2>/dev/null

    # 7. 【优化版】增加初始拥塞窗口 (initcwnd)
    # 作用：获取真实出口网关，并强制应用 initcwnd 16 优化
    # 使用 ip route get 1.1.1.1 相比 show default 能更精准地定位主路由网关
    local GW=$(ip route get 1.1.1.1 | head -n1 | awk '{print $3}')
    if [ -n "$GW" ]; then
        # 使用 replace 代替 change，具备幂等性（重复执行不报错），且强制绑定物理网卡
        ip route replace default via "$GW" dev "$IFACE" initcwnd 16 initrwnd 16
    fi
}

enable_rules() {
    apply_hardware_opt
    
    local IFACE=$(ip route show default | awk '/default/ {print $5}' | head -n1)
    [ -z "$IFACE" ] && IFACE="eth0"

    # 设置策略路由表
    ip rule del fwmark $FWMARK lookup $TABLE 2>/dev/null
    ip rule add fwmark $FWMARK lookup $TABLE
    ip route add local 0.0.0.0/0 dev lo table $TABLE 2>/dev/null

    # 构造 nftables 规则
    nft delete table inet mihomo 2>/dev/null
    nft add table inet mihomo
    
    # 【新增】定义 Flowtable，绑定物理网卡，用于流量卸载
    nft add flowtable inet mihomo f "{ hook ingress priority 0; devices = { $IFACE }; }"
    
    # A. 接管局域网设备（电视/iPad）及 Bridge 模式 Docker 流量
    nft add chain inet mihomo prerouting "{ type filter hook prerouting priority 0; policy accept; }"
    # 直连白名单 (跳过 TProxy，正常路由)
    nft add rule inet mihomo prerouting ip daddr { 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } return
    
    # MSS 修正与 TProxy 核心拦截
    nft add rule inet mihomo prerouting tcp flags syn tcp option maxseg size set rt mtudev
    nft add rule inet mihomo prerouting meta l4proto { tcp, udp } tproxy to :$TPROXY_PORT meta mark set $FWMARK

    # 【新增】Forward 链加速：拦截未被 TProxy 处理的直连/旁路转发流量，应用硬件卸载
    nft add chain inet mihomo forward "{ type filter hook forward priority 0; policy accept; }"
    nft add rule inet mihomo forward meta l4proto { tcp, udp } flow offload @f

    # B. 处理宿主机本机及 Host 模式容器流量
    nft add chain inet mihomo output "{ type route hook output priority 0; policy accept; }"
    # 必须排除 mihomo 进程自身流量，防止死循环
    nft add rule inet mihomo output meta skuid mihomo return
    nft add rule inet mihomo output meta l4proto { tcp, udp } meta mark set $FWMARK

    # C. DNS 劫持 - 局域网入站 (1053端口)
    nft add chain inet mihomo dns_prerouting "{ type nat hook prerouting priority -100; policy accept; }"
    nft add rule inet mihomo dns_prerouting udp dport 53 redirect to :$DNS_PORT
    nft add rule inet mihomo dns_prerouting tcp dport 53 redirect to :$DNS_PORT

    # D. DNS 劫持 - 宿主机本机及 Host 模式容器
    nft add chain inet mihomo dns_output "{ type nat hook output priority -100; policy accept; }"
    nft add rule inet mihomo dns_output meta skuid mihomo return
    nft add rule inet mihomo dns_output udp dport 53 redirect to :$DNS_PORT
    nft add rule inet mihomo dns_output tcp dport 53 redirect to :$DNS_PORT
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
    }

    # ==================== 3. 服务部署 ====================
    setup_service() {
        echo -e "${BLUE}>>> 部署 Systemd 服务控制架构...${NC}"
        prepare_env
        generate_network_script

        cat > /etc/systemd/system/mihomo.service <<EOF
[Unit]
Description=Mihomo Daemon (TProxy + Docker Enhanced)
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
User=mihomo
Group=mihomo
LimitNPROC=10000
LimitNOFILE=1000000
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW

# 强制以 Root 执行规则脚本 (关键修改)
ExecStartPre=+${RULE_SCRIPT} start
ExecStopPost=+${RULE_SCRIPT} stop

# 主进程以降权身份运行
ExecStart=${BIN_PATH} -d ${CONF_DIR}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable mihomo
        echo -e "${GREEN}✅ 服务部署完成，已关联网络规则提权逻辑${NC}"
    }

    # ==================== 4. 安装与交互 ====================
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

    # ==================== 5. 交互式循环菜单 ====================
    while true; do
        clear
        echo -e "${BLUE}==============================================================${NC}"
        echo -e "${GREEN}=== Mihomo TProxy + Docker 融合增强版 (R5C) ===${NC}"
        echo -e "${BLUE}==============================================================${NC}"
        echo "1. 应用规则与内核优化 (解决容器代理/YouTube加速)"
        echo "2. 在线安装 (自动配置权限)"
        echo "3. 本地安装 (从 /tmp/mihomo 复制)"
        echo "4. 服务管理 (启动/停止/日志)"
        echo "5. 彻底卸载"
        echo "0. 退出菜单"
        echo -e "${BLUE}==============================================================${NC}"
        read -p "请输入选项 [0-5]: " OPT < /dev/tty

        case "$OPT" in
            1) 
                optimize_sysctl 
                ;;
            2) 
                install_online 
                ;;
            3) 
                install_local 
                ;;
            4)
                echo -e "\n${YELLOW}--- 服务管理 ---${NC}"
                echo "1. 启动   2. 停止   3. 重启   4. 查看实时日志 (Ctrl+C 退出)"
                read -p ">> 请选择操作 [1-4]: " s < /dev/tty
                case "$s" in
                    1) systemctl start mihomo && echo -e "${GREEN}服务已启动。${NC}" ;;
                    2) systemctl stop mihomo && echo -e "${YELLOW}服务已停止。${NC}" ;;
                    3) systemctl restart mihomo && echo -e "${GREEN}服务已重启。${NC}" ;;
                    4) journalctl -u mihomo -f ;;
                    *) echo -e "${RED}无效输入。${NC}" ;;
                esac
                ;;
            5)
                echo -e "${YELLOW}正在清理系统服务与网络规则...${NC}"
                systemctl disable --now mihomo 2>/dev/null
                rm -f "$RULE_SCRIPT" "$BIN_PATH" /etc/systemd/system/mihomo.service
                nft delete table inet mihomo 2>/dev/null
                userdel mihomo 2>/dev/null
                echo -e "${GREEN}已彻底移除所有残留。${NC}"
                ;;
            0) 
                echo -e "${GREEN}退出脚本。${NC}"
                return 0 
                ;;
            *) 
                echo -e "${RED}无效输入，请重新选择。${NC}" 
                ;;
        esac
        
        # 核心逻辑：执行完毕后暂停，等待用户确认再进行下一次循环
        echo -e "\n"
        read -n 1 -s -r -p "执行完毕，按任意键返回主菜单..." < /dev/tty
    done
}

module_mihomo_tp