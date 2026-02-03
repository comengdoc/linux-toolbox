#!/bin/bash

# =========================================================
# Mihomo 终极融合版 (R5C 性能持久化加固版)
# 适用设备: 友善 R5C / Armbian
# 特性: 
# 1. 自动注入 rc.local，解决重启后 RPS 优化失效导致的网速掉速
# 2. 增强多队列负载均衡，突破 R5C 单核转发瓶颈
# 3. 包含完整的服务管理与一键卸载功能
# =========================================================

# 定义颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

function module_mihomo_tun() {
    # 路径定义
    AUTO_DIR="/tmp/mihomo"
    MANUAL_DIR="/root/mihomo"
    CONF_DIR="/etc/mihomo"
    BIN_PATH="/usr/local/bin/mihomo"
    RULE_SCRIPT="/usr/local/bin/mihomo-rules.sh"

    # ==================== 0. 内核与硬件优化 (深度持久化) ====================
    optimize_sysctl() {
        echo -e "${BLUE}>>> 正在应用系统内核优化 (持久化模式)...${NC}"
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
        
        # 注入 rc.local 解决重启失效
        if [ ! -f /etc/rc.local ]; then
            echo -e '#!/bin/sh -e\nexit 0' > /etc/rc.local
            chmod +x /etc/rc.local
        fi
        if ! grep -q "$RULE_SCRIPT start" /etc/rc.local; then
            sed -i "/^exit 0/i $RULE_SCRIPT start" /etc/rc.local
            echo -e "${GREEN}✅ 已注入 rc.local，开机自动提速已激活${NC}"
        fi

        $RULE_SCRIPT start
        echo -e "${GREEN}✅ 硬件性能优化已刷新${NC}"
    }

    # ==================== 辅助：网络保障脚本 (增强多队列支持) ====================
    generate_network_script() {
        local CPU_COUNT=$(nproc)
        local RPS_MASK=$(printf '%x' $(( (1 << CPU_COUNT) - 1 )))

        cat > "$RULE_SCRIPT" <<EOF
#!/bin/bash
IFACE=\$(ip route show default | awk '/default/ {print \$5}' | head -n1)

apply_hardware_opt() {
    sleep 3
    for iface in \$(ls /sys/class/net | grep -vE "^(lo|tun|docker|veth|cali|flannel|cni|dummy|kube)"); do
        # 遍历所有接收队列，确保 R5C 所有核心参与转发
        for rps_file in /sys/class/net/\$iface/queues/rx-*/rps_cpus; do
            [ -f "\$rps_file" ] && echo "$RPS_MASK" > "\$rps_file" 2>/dev/null
        done
        if command -v ethtool >/dev/null 2>&1; then
             ethtool -K "\$iface" gro off lro off >/dev/null 2>&1
        fi
    done
}

enable_nat() {
    apply_hardware_opt
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    iptables -P FORWARD ACCEPT
    if [ -n "\$IFACE" ]; then
        iptables -t nat -C POSTROUTING -o "\$IFACE" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o "\$IFACE" -j MASQUERADE
    fi
    # DNS 劫持
    iptables -t nat -D PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 1053 2>/dev/null
    iptables -t nat -A PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 1053
    iptables -t nat -D PREROUTING -p tcp --dport 53 -j REDIRECT --to-ports 1053 2>/dev/null
    iptables -t nat -A PREROUTING -p tcp --dport 53 -j REDIRECT --to-ports 1053
}

case "\$1" in
    start) enable_nat ;;
    stop) iptables -t nat -F PREROUTING ;;
esac
EOF
        chmod +x "$RULE_SCRIPT"
    }

    # ==================== 网卡选择交互函数 ====================
    configure_interface() {
        echo -e "${BLUE}>>> 配置出口网卡绑定...${NC}"
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

    # ==================== 服务部署 ====================
    setup_service() {
        mkdir -p "$CONF_DIR"
        generate_network_script
        [ ! -f "$CONF_DIR/config.yaml" ] && ([ -f "$AUTO_DIR/config_tun.yaml" ] && cp "$AUTO_DIR/config_tun.yaml" "$CONF_DIR/config.yaml" || cp "$MANUAL_DIR/config_tun.yaml" "$CONF_DIR/config.yaml" 2>/dev/null)
        configure_interface
        cat > /etc/systemd/system/mihomo.service <<EOF
[Unit]
Description=mihomo Daemon
After=network-online.target
[Service]
Type=simple
ExecStartPre=$RULE_SCRIPT start
ExecStart=$BIN_PATH -d $CONF_DIR
ExecStopPost=$RULE_SCRIPT stop
Restart=always
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload && systemctl enable mihomo
    }

    install_online() {
        local ARCH=$(uname -m)
        local M_ARCH="amd64"
        [ "$ARCH" == "aarch64" ] && M_ARCH="arm64"
        [ "$ARCH" == "armv7l" ] && M_ARCH="armv7"
        LATEST_VER=$(curl -s https://api.github.com/repos/MetaCubeX/mihomo/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        URL="https://github.com/MetaCubeX/mihomo/releases/download/${LATEST_VER}/mihomo-linux-${M_ARCH}-${LATEST_VER}.gz"
        curl -L -o /tmp/mihomo.gz "https://gh-proxy.com/${URL}" --progress-bar
        gzip -d /tmp/mihomo.gz && mv /tmp/mihomo "$BIN_PATH" && chmod 755 "$BIN_PATH"
        optimize_sysctl
        setup_service
        echo -e "${GREEN}安装完成！${NC}"
    }

    # ==================== 菜单逻辑 (含管理与卸载) ====================
    clear
    echo -e "${GREEN}=== Mihomo 安装向导 (R5C 最终修复版) ===${NC}"
    echo "1. 手动应用内核优化 (修复重启掉速问题)"
    echo "2. 在线安装"
    echo "3. 部署仓库/本地版本"
    echo "4. 服务管理 (启动/停止/重启/日志)"
    echo "5. 卸载 Mihomo"
    echo "0. 返回主菜单"
    
    read -p "请选择: " OPT < /dev/tty
    case "$OPT" in
        1) optimize_sysctl ;;
        2) install_online ;;
        3) 
            [ -f "$AUTO_DIR/mihomo" ] && SRC="$AUTO_DIR/mihomo" || SRC="$MANUAL_DIR/mihomo"
            cp "$SRC" "$BIN_PATH" && chmod 755 "$BIN_PATH"
            optimize_sysctl
            setup_service 
            ;;
        4)
            echo -e "${YELLOW}--- 服务管理 ---${NC}"
            echo "1. 启动服务  2. 停止服务  3. 重启服务  4. 查看实时日志"
            read -p "请选择: " s < /dev/tty
            case "$s" in
                1) systemctl start mihomo && echo "已启动" ;;
                2) systemctl stop mihomo && echo "已停止" ;;
                3) systemctl restart mihomo && echo "已重启" ;;
                4) journalctl -u mihomo -f ;;
            esac
            ;;
        5)
            read -p "确认完全卸载 Mihomo 及其优化配置？(y/N): " res < /dev/tty
            if [[ "$res" =~ ^[Yy]$ ]]; then
                systemctl disable --now mihomo 2>/dev/null
                # 清理 rc.local 注入
                sed -i "/$RULE_SCRIPT start/d" /etc/rc.local
                rm -f "$RULE_SCRIPT" "$BIN_PATH" /etc/systemd/system/mihomo.service
                rm -rf "$CONF_DIR"
                systemctl daemon-reload
                echo -e "${RED}卸载完成，系统已还原。${NC}"
            fi
            ;;
        0) return ;;
    esac
}

module_mihomo_tun