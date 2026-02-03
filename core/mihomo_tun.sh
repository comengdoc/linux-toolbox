#!/bin/bash

# =========================================================
# Mihomo 终极融合版 (通用架构适配 Pro)
# 适用设备: R5C / N1 / 树莓派 / x86物理机 / PVE虚拟机
# 核心功能:
# 1. TUN 模式防环路 + NAT 自动管理
# 2. 智能 RPS: 自动识别 CPU 核数并计算掩码
# 3. 架构自适应: 支持 ARM64, ARMv7, x86_64 (含 v3 版)
# 4. 修复局域网 DNS 问题 (手动劫持 53 -> 1053)
# 5. 【修复】网卡绑定冲突逻辑：手动指定时自动关闭 auto-detect
# 6. 【修复】RPS/硬件优化重启失效问题：持久化至规则脚本
# =========================================================

# 定义颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

function module_mihomo_tun() {
    # 定义路径
    AUTO_DIR="/tmp/mihomo"
    MANUAL_DIR="/root/mihomo"
    CONF_DIR="/etc/mihomo"
    BIN_PATH="/usr/local/bin/mihomo"
    RULE_SCRIPT="/usr/local/bin/mihomo-rules.sh"

    # ==================== 0. 内核优化 (持久化) ====================
    optimize_sysctl() {
        echo -e "${BLUE}>>> 正在应用系统内核优化 (sysctl 持久化)...${NC}"
        
        cat > /etc/sysctl.d/99-mihomo-fusion.conf <<EOF
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
net.ipv4.conf.all.src_valid_mark=1
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
fs.inotify.max_user_watches=524288
net.netfilter.nf_conntrack_max=262144
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.core.rmem_default=262144
net.core.wmem_default=262144
EOF
        sysctl --system >/dev/null 2>&1
        generate_network_script
        $RULE_SCRIPT start
        echo -e "${GREEN}✅ 内核优化及网卡硬件参数已刷新并持久化${NC}"
    }

    # ==================== 辅助：网络保障脚本 (包含硬件优化持久化) ====================
    generate_network_script() {
        echo -e "${BLUE}>>> 正在同步网络规则脚本 (${RULE_SCRIPT})...${NC}"
        local CPU_COUNT=$(nproc)
        local RPS_MASK=$(printf '%x' $(( (1 << CPU_COUNT) - 1 )))

        cat > "$RULE_SCRIPT" <<EOF
#!/bin/bash
IFACE=\$(ip route show default | awk '/default/ {print \$5}' | head -n1)

apply_hardware_opt() {
    echo "  - [Hardware] 正在应用 RPS 掩码 ($RPS_MASK) 及硬件优化..."
    for iface in \$(ls /sys/class/net | grep -vE "^(lo|tun|docker|veth|cali|flannel|cni|dummy|kube)"); do
        if [ -f "/sys/class/net/\$iface/queues/rx-0/rps_cpus" ]; then
            echo "$RPS_MASK" > "/sys/class/net/\$iface/queues/rx-0/rps_cpus" 2>/dev/null
        fi
        if command -v ethtool >/dev/null 2>&1; then
             ethtool -K "\$iface" gro off lro off >/dev/null 2>&1
        fi
    done
}

enable_nat() {
    apply_hardware_opt
    echo "  - [Network] 正在应用网络规则 (NAT + DNS劫持)..."
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    sysctl -w net.ipv4.conf.all.src_valid_mark=1 >/dev/null
    iptables -P FORWARD ACCEPT
    if [ -n "\$IFACE" ]; then
        iptables -t nat -C POSTROUTING -o "\$IFACE" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o "\$IFACE" -j MASQUERADE
    fi
    iptables -t nat -D PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 1053 2>/dev/null
    iptables -t nat -D PREROUTING -p tcp --dport 53 -j REDIRECT --to-ports 1053 2>/dev/null
    iptables -t nat -A PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 1053
    iptables -t nat -A PREROUTING -p tcp --dport 53 -j REDIRECT --to-ports 1053
}

disable_nat() {
    echo "  - [Network] 清理网络规则..."
    iptables -t nat -D PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 1053 2>/dev/null
    iptables -t nat -D PREROUTING -p tcp --dport 53 -j REDIRECT --to-ports 1053 2>/dev/null
}

case "\$1" in
    start) enable_nat ;;
    stop) disable_nat ;;
    restart) disable_nat; sleep 1; enable_nat ;;
esac
EOF
        chmod +x "$RULE_SCRIPT"
    }

    # ==================== 网卡选择交互函数 ====================
    configure_interface() {
        echo -e "${BLUE}>>> 正在配置出口网卡绑定...${NC}"
        INTERFACES=$(ls /sys/class/net | grep -vE "^(lo|tun|docker|veth|cali|flannel|cni|dummy)")
        [ -d "/sys/class/net/br-lan" ] && INTERFACES="br-lan $(echo "$INTERFACES" | sed 's/br-lan//g')"
        IFACE_LIST=($INTERFACES "自动检测(Auto)")
        
        select iface in "${IFACE_LIST[@]}"; do
            if [ "$iface" == "自动检测(Auto)" ]; then
                sed -i 's/auto-detect-interface: .*/auto-detect-interface: true/' "$CONF_DIR/config.yaml"
                sed -i '/^interface-name:/d' "$CONF_DIR/config.yaml"
                break
            elif [ -n "$iface" ]; then
                sed -i 's/auto-detect-interface: .*/auto-detect-interface: false/' "$CONF_DIR/config.yaml"
                grep -q "^interface-name:" "$CONF_DIR/config.yaml" && sed -i "s/^interface-name:.*/interface-name: $iface/" "$CONF_DIR/config.yaml" || sed -i "1i interface-name: $iface" "$CONF_DIR/config.yaml"
                break
            fi
        done
    }

    # ==================== 服务配置 ====================
    setup_service() {
        echo -e "${BLUE}>>> 部署 Systemd 服务...${NC}"
        mkdir -p "$CONF_DIR"
        generate_network_script
        [ ! -f "$CONF_DIR/config.yaml" ] && ([ -f "$AUTO_DIR/config_tun.yaml" ] && cp "$AUTO_DIR/config_tun.yaml" "$CONF_DIR/config.yaml" || cp "$MANUAL_DIR/config_tun.yaml" "$CONF_DIR/config.yaml" 2>/dev/null)
        configure_interface

        cat > /etc/systemd/system/mihomo.service <<EOF
[Unit]
Description=mihomo Daemon (TUN Mode & Optimized)
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

    # ==================== 在线/本地安装逻辑 ====================
    install_online() {
        local ARCH=$(uname -m)
        local M_ARCH="amd64"
        [ "$ARCH" == "x86_64" ] && { read -p "1.标准 2.高性能(v3): " c < /dev/tty; [ "$c" == "2" ] && M_ARCH="amd64-v3"; }
        [ "$ARCH" == "aarch64" ] && M_ARCH="arm64"
        [ "$ARCH" == "armv7l" ] && M_ARCH="armv7"

        LATEST_VER=$(curl -s https://api.github.com/repos/MetaCubeX/mihomo/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        URL="https://github.com/MetaCubeX/mihomo/releases/download/${LATEST_VER}/mihomo-linux-${M_ARCH}-${LATEST_VER}.gz"
        
        curl -L -o /tmp/mihomo.gz "https://gh-proxy.com/${URL}" --progress-bar
        gzip -d /tmp/mihomo.gz && mv /tmp/mihomo "$BIN_PATH" && chmod 755 "$BIN_PATH"
        optimize_sysctl
        setup_service
    }

    install_local() {
        [ -f "$AUTO_DIR/mihomo" ] && SRC="$AUTO_DIR/mihomo" || SRC="$MANUAL_DIR/mihomo"
        cp "$SRC" "$BIN_PATH" && chmod 755 "$BIN_PATH"
        optimize_sysctl
        setup_service
    }

    # ==================== 卸载 ====================
    uninstall_mihomo() {
        read -p "确认卸载？(y/N): " res < /dev/tty
        [[ "$res" =~ ^[Yy]$ ]] || return
        systemctl disable --now mihomo 2>/dev/null
        rm -f "$RULE_SCRIPT" "$BIN_PATH" /etc/systemd/system/mihomo.service
        rm -rf "$CONF_DIR"
        systemctl daemon-reload
        echo "卸载完成。"
    }

    # ==================== 菜单逻辑 ====================
    clear
    echo -e "${GREEN}=== Mihomo 安装向导 (R5C 优化版) ===${NC}"
    echo "1. 手动应用内核优化 (持久化硬件参数)"
    echo "2. 在线安装"
    echo "3. 部署仓库/本地版本"
    echo "4. 服务管理 (启动/停止/重启/日志)"
    echo "5. 卸载 Mihomo"
    echo "0. 返回主菜单"
    
    read -p "请选择: " OPT < /dev/tty
    case "$OPT" in
        1) optimize_sysctl ;;
        2) install_online ;;
        3) install_local ;;
        4)
            echo "1.启动 2.停止 3.重启 4.日志"
            read -p "选择: " s < /dev/tty
            [ "$s" == "1" ] && systemctl start mihomo
            [ "$s" == "2" ] && systemctl stop mihomo
            [ "$s" == "3" ] && systemctl restart mihomo
            [ "$s" == "4" ] && journalctl -u mihomo -f
            ;;
        5) uninstall_mihomo ;;
        0) return ;;
    esac
}

# 调用函数
module_mihomo_tun