#!/bin/bash

# =========================================================
# Mihomo TProxy 终极版 (通用架构适配 Pro)
# 适用设备: R5C / N1 / 树莓派 / x86物理机 / PVE虚拟机
# 核心功能:
# 1. 纯 TProxy 模式 (仅接管局域网流量，极度稳定)
# 2. 智能 RPS: 自动识别 CPU 核数并计算掩码 (2核/4核/8核...)
# 3. 架构自适应: 支持 ARM64, ARMv7, x86_64 (含 v3 AVX2 高性能版)
# 4. 网卡绑定: 支持手动锁定物理网卡，防止 NAT 失效
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
    IFACE_FILE="$CONF_DIR/interface_name" # 网卡配置文件

    # ==================== 0. 内核优化 (通用动态版) ====================
    optimize_sysctl() {
        echo -e "${BLUE}>>> 正在应用系统内核优化 (动态RPS + TProxy专用 + UDP大缓存)...${NC}"
        cat > /etc/sysctl.d/99-mihomo-fusion.conf <<EOF
# --- 基础转发 ---
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1

# --- TProxy 关键参数 (必须) ---
net.ipv4.ip_nonlocal_bind=1
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0

# --- 性能优化: TCP BBR ---
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

# --- 性能优化: 连接数保障 ---
fs.inotify.max_user_watches=524288
net.netfilter.nf_conntrack_max=262144

# --- UDP 缓冲区优化 (针对 Hysteria2/QUIC) ---
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.core.rmem_default=262144
net.core.wmem_default=262144
EOF
        sysctl --system >/dev/null 2>&1

        # 2. 【升级】动态计算 RPS 掩码 & 关闭 Offloading
        echo -e "    正在配置网卡硬件参数 (动态RPS/Offloading)..."
        
        # 自动获取 CPU 核心数
        local CPU_COUNT=$(nproc)
        # 计算掩码: (1 << 核心数) - 1
        local RPS_MASK=$(printf '%x' $(( (1 << CPU_COUNT) - 1 )))
        
        echo -e "      - 检测到 CPU 核心数: ${GREEN}${CPU_COUNT}${NC} (RPS掩码: ${GREEN}${RPS_MASK}${NC})"
        
        # 遍历所有物理网卡
        for iface in $(ls /sys/class/net | grep -vE "^(lo|tun|docker|veth|cali|flannel|cni|dummy|kube)"); do
            # 开启 RPS
            if [ -f "/sys/class/net/$iface/queues/rx-0/rps_cpus" ]; then
                echo "$RPS_MASK" > "/sys/class/net/$iface/queues/rx-0/rps_cpus" 2>/dev/null
                echo "      - $iface: RPS 已启用 (均衡到所有 ${CPU_COUNT} 个核心)"
            fi
            
            # 关闭 Offloading (TProxy 模式下必须关闭，否则断流/校验和错误)
            if command -v ethtool >/dev/null 2>&1; then
                 ethtool -K "$iface" gro off lro off >/dev/null 2>&1
                 echo "      - $iface: GRO/LRO 硬件卸载已关闭 (保障 TProxy 稳定性)"
            fi
        done

        # 确保 TProxy 必要的 rp_filter 对物理网卡生效
        for iface in $(ls /sys/class/net | grep -vE "^(lo|tun|docker|veth)"); do
             sysctl -w net.ipv4.conf.$iface.rp_filter=0 >/dev/null 2>&1
        done

        echo -e "${GREEN}✅ 内核优化(Pro)完成${NC}"
    }

    # ==================== 辅助：网络保障脚本 (纯净版) ====================
    generate_network_script() {
        echo -e "${BLUE}>>> 生成 TProxy 网络接管脚本 (仅局域网)...${NC}"
        
        cat > "$RULE_SCRIPT" <<EOF
#!/bin/bash
# Mihomo TProxy 网络管理器 (局域网专用版)

# 配置参数 (必须与 config_tp.yaml 一致)
TPROXY_PORT=7894
DNS_PORT=1053
FWMARK=1
TABLE=100
CONF_IFACE="$IFACE_FILE"

# 获取出口网卡逻辑
if [ -f "\$CONF_IFACE" ]; then
    IFACE=\$(cat "\$CONF_IFACE")
    echo "  - [Network] 使用锁定网卡: \$IFACE"
else
    IFACE=\$(ip route show default | awk '/default/ {print \$5}' | head -n1)
    echo "  - [Network] 自动检测网卡: \$IFACE"
fi

enable_rules() {
    echo "  - [Network] 正在初始化 TProxy 规则..."
    
    # 1. 基础设置与策略路由
    ip rule add fwmark \$FWMARK lookup \$TABLE 2>/dev/null
    ip route add local 0.0.0.0/0 dev lo table \$TABLE 2>/dev/null

    # 2. 新建自定义链 MIHOMO (Mangle表)
    iptables -t mangle -N MIHOMO 2>/dev/null
    iptables -t mangle -F MIHOMO

    # --- 规则排除区 (直连网段) ---
    iptables -t mangle -A MIHOMO -d 0.0.0.0/8 -j RETURN
    iptables -t mangle -A MIHOMO -d 10.0.0.0/8 -j RETURN
    iptables -t mangle -A MIHOMO -d 127.0.0.0/8 -j RETURN
    iptables -t mangle -A MIHOMO -d 169.254.0.0/16 -j RETURN
    iptables -t mangle -A MIHOMO -d 172.16.0.0/12 -j RETURN
    iptables -t mangle -A MIHOMO -d 192.168.0.0/16 -j RETURN
    iptables -t mangle -A MIHOMO -d 224.0.0.0/4 -j RETURN
    iptables -t mangle -A MIHOMO -d 240.0.0.0/4 -j RETURN
    
    # --- 流量打标 ---
    iptables -t mangle -A MIHOMO -p tcp -j TPROXY --on-port \$TPROXY_PORT --tproxy-mark \$FWMARK
    iptables -t mangle -A MIHOMO -p udp -j TPROXY --on-port \$TPROXY_PORT --tproxy-mark \$FWMARK

    # 3. 应用规则到 PREROUTING (局域网流量入口)
    iptables -t mangle -C PREROUTING -j MIHOMO 2>/dev/null || \
    iptables -t mangle -A PREROUTING -j MIHOMO

    # 4. DNS 劫持 (53 -> 1053)
    iptables -t nat -N MIHOMO_DNS 2>/dev/null
    iptables -t nat -F MIHOMO_DNS
    iptables -t nat -A MIHOMO_DNS -p udp --dport 53 -j REDIRECT --to-ports \$DNS_PORT
    iptables -t nat -A MIHOMO_DNS -p tcp --dport 53 -j REDIRECT --to-ports \$DNS_PORT
    
    # 应用到 PREROUTING
    iptables -t nat -C PREROUTING -j MIHOMO_DNS 2>/dev/null || \
    iptables -t nat -A PREROUTING -j MIHOMO_DNS

    # 5. 开启 NAT (保证回程)
    if [ -n "\$IFACE" ]; then
        iptables -t nat -C POSTROUTING -o "\$IFACE" -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING -o "\$IFACE" -j MASQUERADE
    fi

    echo "    [TProxy] 局域网透明代理已生效 (本机直连)"
}

disable_rules() {
    echo "  - [Network] 清理 TProxy 规则..."
    
    # 清理 PREROUTING (Mangle)
    iptables -t mangle -D PREROUTING -j MIHOMO 2>/dev/null
    iptables -t mangle -F MIHOMO 2>/dev/null
    iptables -t mangle -X MIHOMO 2>/dev/null

    # 清理 PREROUTING (Nat)
    iptables -t nat -D PREROUTING -j MIHOMO_DNS 2>/dev/null
    iptables -t nat -F MIHOMO_DNS 2>/dev/null
    iptables -t nat -X MIHOMO_DNS 2>/dev/null

    # 清理策略路由
    ip rule del fwmark \$FWMARK lookup \$TABLE 2>/dev/null
    ip route del local 0.0.0.0/0 dev lo table \$TABLE 2>/dev/null
}

case "\$1" in
    start) enable_rules ;;
    stop) disable_rules ;;
    restart) disable_rules; sleep 1; enable_rules ;;
    uninstall) disable_rules ;;
    *) echo "Usage: \$0 {start|stop|restart|uninstall}"; exit 1 ;;
esac
EOF
        chmod +x "$RULE_SCRIPT"
        echo -e "${GREEN}✅ TProxy 网络脚本生成完毕${NC}"
    }

    # ==================== 新增：网卡选择交互函数 ====================
    configure_interface() {
        echo -e "${BLUE}>>> 正在配置出口网卡 (用于 NAT Masquerade)...${NC}"
        
        # 1. 获取物理网卡列表
        INTERFACES=$(ls /sys/class/net | grep -vE "^(lo|tun|docker|veth|cali|flannel|cni|dummy)")
        
        # 优先处理 br-lan
        if [ -d "/sys/class/net/br-lan" ]; then
            INTERFACES=$(echo "$INTERFACES" | sed 's/br-lan//g')
            INTERFACES="br-lan $INTERFACES"
        fi

        IFACE_LIST=($INTERFACES "自动检测(Auto)")

        echo -e "${YELLOW}检测到以下网卡，请选择主要流量出口 (通常是 eth0 或 br-lan):${NC}"
        
        select iface in "${IFACE_LIST[@]}"; do
            if [ "$iface" == "自动检测(Auto)" ]; then
                echo -e "已选择: ${GREEN}自动检测${NC}"
                rm -f "$IFACE_FILE"
                break
            elif [ -n "$iface" ]; then
                echo -e "已锁定网卡: ${GREEN}$iface${NC}"
                echo "$iface" > "$IFACE_FILE"
                break
            else
                echo "输入错误，请重新选择数字。"
            fi
        done
    }

    # ==================== 1. 服务配置函数 ====================
    setup_service() {
        echo -e "${BLUE}>>> 配置 Systemd 服务...${NC}"
        mkdir -p "$CONF_DIR"
        
        # 先复制配置，确保目录存在
        if [ ! -f "$CONF_DIR/config.yaml" ]; then
             if [ -f "$AUTO_DIR/config_tp.yaml" ]; then
                 cp "$AUTO_DIR/config_tp.yaml" "$CONF_DIR/config.yaml"
             elif [ -f "$MANUAL_DIR/config_tp.yaml" ]; then
                 cp "$MANUAL_DIR/config_tp.yaml" "$CONF_DIR/config.yaml"
             else
                 touch "$CONF_DIR/config.yaml"
                 echo -e "${RED}⚠️ 请注意：请确保 config.yaml 已就位${NC}"
             fi
        fi

        # =========== 【插入点】 ===========
        # 询问网卡并生成网络脚本
        configure_interface
        generate_network_script
        # ================================

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

    # ==================== 2. 在线下载安装 (含通用架构选择) ====================
    install_online() {
        echo -e "${BLUE}>>> 正在检测系统架构...${NC}"
        local ARCH=$(uname -m)
        local MIHOMO_ARCH=""
        
        # 【升级】x86 架构细分逻辑
        if [ "$ARCH" == "x86_64" ]; then
            echo -e "${YELLOW}检测到 x86_64 架构，请选择指令集版本：${NC}"
            echo "1. amd64 (标准版 - 兼容性好)"
            echo "2. amd64-v3 (高性能版 - AVX2, 加解密更快)"
            read -p "请选择 [默认1]: " cpu_choice < /dev/tty
            
            if [ "$cpu_choice" == "2" ]; then
                MIHOMO_ARCH="amd64-v3"
                echo -e "已选择: ${GREEN}amd64-v3 (高性能)${NC}"
            else
                MIHOMO_ARCH="amd64"
                echo -e "已选择: ${GREEN}amd64 (标准兼容)${NC}"
            fi
        elif [ "$ARCH" == "aarch64" ]; then
            MIHOMO_ARCH="arm64"
        elif [ "$ARCH" == "armv7l" ]; then
            MIHOMO_ARCH="armv7"
        else
            echo -e "${RED}不支持的架构: $ARCH${NC}"; return 1
        fi

        echo -e "${BLUE}>>> 正在获取 Mihomo 版本信息...${NC}"
        LATEST_VER=$(curl -s -m 5 https://api.github.com/repos/MetaCubeX/mihomo/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        if [ -z "$LATEST_VER" ]; then
            read -p "获取失败，输入版本号 (如 v1.18.5): " LATEST_VER < /dev/tty
        fi
        
        local proxy_prefix="${PROXY_PREFIX:-https://ghproxy.net/}"
        TARGET_URL="https://github.com/MetaCubeX/mihomo/releases/download/${LATEST_VER}/mihomo-linux-${MIHOMO_ARCH}-${LATEST_VER}.gz"
        
        echo -e "正在下载: ${GREEN}${proxy_prefix}${TARGET_URL}${NC}"
        rm -f /tmp/mihomo.gz
        curl -L -o /tmp/mihomo.gz "${proxy_prefix}${TARGET_URL}" --progress-bar

        if [ ! -s /tmp/mihomo.gz ]; then
            echo -e "${RED}❌ 下载失败。${NC}"
            return 1
        fi

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

    echo -e "${GREEN}=== Mihomo TProxy (通用全平台版) ===${NC}"
    echo "1. 刷新内核与网络规则 (含网卡设置)"
    echo "2. 在线安装 (支持 x86 v3)"
    echo "3. 本地/仓库安装"
    echo "4. 服务管理"
    echo "5. 卸载"
    echo "0. 返回"
    read -p "选择: " OPT < /dev/tty

    case "$OPT" in
        1) configure_interface; optimize_sysctl; generate_network_script ;;
        2) install_online ;;
        3) install_local ;;
        4) systemctl restart mihomo; echo "已重启" ;;
        5) uninstall_mihomo ;;
        0) return ;;
        *) echo "无效选择" ;;
    esac
}