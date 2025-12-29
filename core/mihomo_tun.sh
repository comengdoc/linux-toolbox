#!/bin/bash

# =========================================================
# Mihomo 终极融合版 (通用架构适配 Pro)
# 适用设备: R5C / N1 / 树莓派 / x86物理机 / PVE虚拟机
# 核心功能:
# 1. TUN 模式防环路 + NAT 自动管理
# 2. 智能 RPS: 自动识别 CPU 核数并计算掩码 (2核/4核/8核/12核...)
# 3. 架构自适应: 支持 ARM64, ARMv7, x86_64 (含 v3 AVX2 高性能版)
# 4. 修复局域网 DNS 问题 (手动劫持 53 -> 1053)
# 5. 网卡绑定选择 (防止 Docker/虚拟网卡 干扰)
# =========================================================

# 定义颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

function module_mihomo_tun() {
    # 定义路径
    AUTO_DIR="/tmp/mihomo"          # 自动下载缓存路径
    MANUAL_DIR="/root/mihomo"       # 手动上传路径
    CONF_DIR="/etc/mihomo"          # 配置文件路径
    BIN_PATH="/usr/local/bin/mihomo" # 二进制文件路径
    RULE_SCRIPT="/usr/local/bin/mihomo-rules.sh" # 网络规则脚本路径

    # ==================== 0. 内核优化 (通用动态版) ====================
    optimize_sysctl() {
        echo -e "${BLUE}>>> 正在应用系统内核优化 (动态RPS均衡 + UDP大缓存 + TUN防环路)...${NC}"
        
        # 1. 写入 sysctl 配置文件
        cat > /etc/sysctl.d/99-mihomo-fusion.conf <<EOF
# --- 基础转发 ---
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1

# --- TUN 模式核心防环路 ---
net.ipv4.conf.all.src_valid_mark=1

# --- 性能优化: TCP BBR ---
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

# --- 性能优化: 连接数保障 ---
fs.inotify.max_user_watches=524288
net.netfilter.nf_conntrack_max=262144

# --- 【新增】UDP 缓冲区优化 (针对 Hysteria2/QUIC) ---
# 提升到 16MB 以应对高吞吐 UDP，解决游戏/QUIC 丢包
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
        # 计算掩码: (1 << 核心数) - 1，并转为十六进制
        # 例如: 4核 -> 1111(二进制) -> f(十六进制); 2核 -> 3; 8核 -> ff
        local RPS_MASK=$(printf '%x' $(( (1 << CPU_COUNT) - 1 )))
        
        echo -e "      - 检测到 CPU 核心数: ${GREEN}${CPU_COUNT}${NC} (RPS掩码: ${GREEN}${RPS_MASK}${NC})"
        
        # 遍历所有物理网卡 (排除 lo/tun/docker/veth 等)
        for iface in $(ls /sys/class/net | grep -vE "^(lo|tun|docker|veth|cali|flannel|cni|dummy|kube)"); do
            # 开启 RPS (多核分流)
            if [ -f "/sys/class/net/$iface/queues/rx-0/rps_cpus" ]; then
                echo "$RPS_MASK" > "/sys/class/net/$iface/queues/rx-0/rps_cpus" 2>/dev/null
                echo "      - $iface: RPS 已启用 (均衡到所有 ${CPU_COUNT} 个核心)"
            fi
            
            # 关闭可能导致问题的 Offloading (解决断流/兼容性)
            # 在通用脚本中，默认关闭 GRO/LRO 是最稳妥的策略，无论是 Realtek 还是虚拟网卡
            if command -v ethtool >/dev/null 2>&1; then
                 ethtool -K "$iface" gro off lro off >/dev/null 2>&1
                 echo "      - $iface: GRO/LRO 硬件卸载已关闭 (提升稳定性)"
            fi
        done
        
        # 这里同时也调用一次生成网络脚本，确保更新规则
        generate_network_script

        echo -e "${GREEN}>>> 内核参数验证:${NC}"
        echo -n "转发状态: "; sysctl net.ipv4.ip_forward
        echo -n "防环路状态: "; sysctl net.ipv4.conf.all.src_valid_mark
        echo -n "拥塞控制: "; sysctl net.ipv4.tcp_congestion_control
        echo -e "${GREEN}✅ 内核优化及网络规则更新完成${NC}"
    }

    # ==================== 辅助：网络保障脚本 (DNS/NAT) ====================
    generate_network_script() {
        echo -e "${BLUE}>>> 生成基础网络脚本 (${RULE_SCRIPT})...${NC}"
        cat > "$RULE_SCRIPT" <<'EOF'
#!/bin/bash
# Mihomo 基础网络管理器
# 作用: 开启 NAT (Masquerade) 和 DNS 劫持 (53->1053)

# 获取出口网卡 (用于 NAT)
IFACE=$(ip route show default | awk '/default/ {print $5}' | head -n1)

enable_nat() {
    echo "  - [Network] 正在应用网络规则 (NAT + DNS劫持)..."
    
    # 1. 强制开启转发
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    sysctl -w net.ipv4.conf.all.src_valid_mark=1 >/dev/null
    iptables -P FORWARD ACCEPT

    # 2. 开启 NAT 伪装
    if [ -n "$IFACE" ]; then
        if ! iptables -t nat -C POSTROUTING -o "$IFACE" -j MASQUERADE 2>/dev/null; then
            iptables -t nat -A POSTROUTING -o "$IFACE" -j MASQUERADE
            echo "    [NAT] 出口伪装已开启: $IFACE"
        else
            echo "    [NAT] 伪装规则已存在"
        fi
    fi

    # 3. 开启 DNS 劫持 (关键修复)
    iptables -t nat -D PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 1053 2>/dev/null
    iptables -t nat -D PREROUTING -p tcp --dport 53 -j REDIRECT --to-ports 1053 2>/dev/null
    
    iptables -t nat -A PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 1053
    iptables -t nat -A PREROUTING -p tcp --dport 53 -j REDIRECT --to-ports 1053
    echo "    [DNS] 强制劫持已开启: UDP/TCP 53 -> 1053"
}

disable_nat() {
    echo "  - [Network] 清理网络规则..."
    iptables -t nat -D PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 1053 2>/dev/null
    iptables -t nat -D PREROUTING -p tcp --dport 53 -j REDIRECT --to-ports 1053 2>/dev/null
    echo "    [DNS] 劫持规则已移除"
    # NAT 规则保留，避免断网
}

case "$1" in
    start) enable_nat ;;
    stop) disable_nat ;;
    restart) disable_nat; sleep 1; enable_nat ;;
    uninstall) echo "保留 NAT 规则。" ;;
    *) echo "Usage: $0 {start|stop|restart|uninstall}"; exit 1 ;;
esac
EOF
        chmod +x "$RULE_SCRIPT"
        echo -e "${GREEN}✅ 网络辅助脚本生成完毕${NC}"
    }

    # ==================== 新增：网卡选择交互函数 ====================
    configure_interface() {
        echo -e "${BLUE}>>> 正在配置出口网卡 (绑定物理接口)...${NC}"
        
        # 1. 获取物理网卡列表
        INTERFACES=$(ls /sys/class/net | grep -vE "^(lo|tun|docker|veth|cali|flannel|cni|dummy)")
        
        if [ -d "/sys/class/net/br-lan" ]; then
            INTERFACES=$(echo "$INTERFACES" | sed 's/br-lan//g')
            INTERFACES="br-lan $INTERFACES"
        fi

        IFACE_LIST=($INTERFACES "自动检测(Auto)")

        echo -e "${YELLOW}检测到以下网卡，请选择主要流量出口 (x86/R5C 建议手动选择):${NC}"
        
        select iface in "${IFACE_LIST[@]}"; do
            if [ "$iface" == "自动检测(Auto)" ]; then
                echo -e "已选择: ${GREEN}自动检测${NC}"
                sed -i 's/auto-detect-interface: false/auto-detect-interface: true/' "$CONF_DIR/config.yaml"
                sed -i 's/^interface-name:/# interface-name:/' "$CONF_DIR/config.yaml"
                break
            elif [ -n "$iface" ]; then
                echo -e "已锁定网卡: ${GREEN}$iface${NC}"
                sed -i 's/auto-detect-interface: true/auto-detect-interface: false/' "$CONF_DIR/config.yaml"
                
                if grep -q "interface-name:" "$CONF_DIR/config.yaml"; then
                    sed -i "s/^#\? *interface-name:.*/interface-name: $iface/" "$CONF_DIR/config.yaml"
                else
                    sed -i "1i interface-name: $iface" "$CONF_DIR/config.yaml"
                fi
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
        
        generate_network_script

        if [ ! -f "$CONF_DIR/config.yaml" ]; then
             if [ -f "$AUTO_DIR/config_tun.yaml" ]; then
                 cp "$AUTO_DIR/config_tun.yaml" "$CONF_DIR/config.yaml"
                 echo -e "${GREEN}✅ 已应用 config_tun.yaml${NC}"
             elif [ -f "$MANUAL_DIR/config_tun.yaml" ]; then
                 cp "$MANUAL_DIR/config_tun.yaml" "$CONF_DIR/config.yaml"
                 echo -e "${GREEN}✅ 已应用 config_tun.yaml${NC}"
             else
                 touch "$CONF_DIR/config.yaml"
                 echo -e "${RED}⚠️ 请注意：你需要自行编辑 config.yaml！${NC}"
             fi
        fi

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
ExecStartPre=/bin/bash -c 'for i in {1..20}; do if ip route show default | grep -q "default"; then echo "Network ready"; exit 0; fi; sleep 1; done; echo "Network not ready"; exit 1'
ExecStartPre=$RULE_SCRIPT start
ExecStart=$BIN_PATH -d $CONF_DIR
ExecStopPost=$RULE_SCRIPT stop
ExecReload=/bin/kill -HUP \$MAINPID
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable mihomo
        echo -e "${GREEN}✅ 服务已配置并设置为开机自启${NC}"
    }

    # ==================== 2. 在线下载安装 (含架构选择) ====================
    install_online() {
        echo -e "${BLUE}>>> 正在检测系统架构...${NC}"
        local ARCH=$(uname -m)
        local MIHOMO_ARCH=""
        
        # 【升级】x86 架构细分逻辑
        if [ "$ARCH" == "x86_64" ]; then
            echo -e "${YELLOW}检测到 x86_64 架构，请选择指令集版本：${NC}"
            echo "1. amd64 (标准版 - 兼容性好，适用大多数虚拟机/旧电脑)"
            echo "2. amd64-v3 (高性能版 - 需近10年CPU，支持AVX2，加解密更快)"
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
            read -p "获取失败，请输入欲安装的版本号 (例如 v1.18.5): " LATEST_VER < /dev/tty
            if [ -z "$LATEST_VER" ]; then echo "❌ 未输入版本号"; return 1; fi
        fi
        
        local proxy_prefix="${PROXY_PREFIX:-https://ghproxy.net/}"
        # URL 构造适配 v3 版本
        TARGET_URL="https://github.com/MetaCubeX/mihomo/releases/download/${LATEST_VER}/mihomo-linux-${MIHOMO_ARCH}-${LATEST_VER}.gz"
        PROXY_URL="${proxy_prefix}${TARGET_URL}"
        
        echo -e "正在下载: ${GREEN}${PROXY_URL}${NC}"
        rm -f /tmp/mihomo.gz
        curl -L -o /tmp/mihomo.gz "$PROXY_URL" --progress-bar

        if [ ! -s /tmp/mihomo.gz ]; then
            echo -e "${RED}❌ 下载失败。${NC}"
            return 1
        fi

        gzip -d /tmp/mihomo.gz
        mv /tmp/mihomo "$BIN_PATH"
        chmod 755 "$BIN_PATH"
        
        echo -e "${GREEN}✅ Mihomo 已在线安装完毕${NC}"
        optimize_sysctl
        setup_service
    }

    # ==================== 3. 仓库/本地安装 ====================
    install_local() {
        echo -e "${GREEN}=== 仓库/本地 部署模式 ===${NC}"
        local SOURCE_FILE=""

        if [ -f "$AUTO_DIR/mihomo" ]; then
            echo -e "${GREEN}🎉 检测到 GitHub 仓库文件 (/tmp/mihomo)${NC}"
            SOURCE_FILE="$AUTO_DIR/mihomo"
        elif [ -f "$MANUAL_DIR/mihomo" ]; then
             echo -e "${YELLOW}检测到本地上传文件 (/root/mihomo)${NC}"
             SOURCE_FILE="$MANUAL_DIR/mihomo"
        else
            echo -e "${RED}❌ 未检测到安装文件！${NC}"
            echo "请手动上传文件到 $MANUAL_DIR"
            return 1
        fi

        cp "$SOURCE_FILE" "$BIN_PATH"
        chmod 755 "$BIN_PATH"
        
        if "$BIN_PATH" -v >/dev/null 2>&1; then
            echo -e "${GREEN}✅ 核心文件安装成功: $("$BIN_PATH" -v)${NC}"
        else
            echo -e "${RED}❌ 文件无法运行 (架构错误或文件损坏)${NC}"
            return 1
        fi

        optimize_sysctl
        setup_service
    }

    # ==================== 4. 卸载函数 ====================
    uninstall_mihomo() {
        echo -e "${RED}⚠️  警告：准备卸载 Mihomo${NC}"
        read -p "确认要卸载吗？(y/N): " confirm < /dev/tty
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then echo "已取消"; return; fi

        systemctl stop mihomo 2>/dev/null
        systemctl disable mihomo 2>/dev/null
        rm -f "$RULE_SCRIPT"
        rm -f "$BIN_PATH"
        rm -f /etc/systemd/system/mihomo.service
        systemctl daemon-reload
        rm -rf "$CONF_DIR"
        echo -e "${GREEN}✅ 卸载完成。${NC}"
    }

    # ==================== 菜单逻辑 ====================
    echo -e "${GREEN}=== Mihomo 安装向导 (通用全平台版) ===${NC}"
    echo "1. 手动应用内核优化 (刷新网络规则+动态RPS)"
    echo "2. 在线安装 (下载官方最新版, 支持 x86 v3)"
    echo "3. 部署仓库版本 (推荐！使用本地/仓库文件)"
    echo "4. 服务管理 (启动/停止/日志)"
    echo -e "${RED}5. 卸载 Mihomo${NC}"
    echo "0. 返回主菜单"
    
    read -p "请选择: " OPT < /dev/tty

    case "$OPT" in
        1) optimize_sysctl ;;
        2) install_online ;;
        3) install_local ;;
        4)
            echo "1) 启动  2) 停止  3) 重启  4) 查看日志"
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