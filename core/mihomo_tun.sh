#!/bin/bash

# =========================================================
# Mihomo 终极融合版 (TUN模式 + N1/R5C 极致性能优化 Pro)
# 融合说明:
# 1. 基础架构基于 M2 (确保 TUN 模式不环路，自动管理 NAT)
# 2. 稳定性代码来自 M1 (时间同步保护、BBR、启动路由检测、菜单修复)
# 3. 修复局域网 DNS 问题 (手动劫持 53 -> 1053)
# 4. 新增网卡绑定选择 (防止 Docker/虚拟网卡 干扰)
# 5. 【新增】Pro级优化: RPS多核均衡 + UDP大缓存 + 硬件卸载优化
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

    # ==================== 0. 内核优化 (Pro 增强版) ====================
    optimize_sysctl() {
        echo -e "${BLUE}>>> 正在应用系统内核优化 (Pro版: RPS均衡 + UDP大缓存 + TUN防环路)...${NC}"
        
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

        # 2. 【新增】开启 RPS (CPU 软中断均衡) & 关闭 Offloading
        # 针对 4 核 CPU (N1/R5C) 的优化，掩码 f (二进制 1111) 代表所有 4 个核都参与处理
        echo -e "    正在配置网卡硬件参数 (RPS/Offloading)..."
        
        # 遍历所有物理网卡 (排除 lo/tun/docker/veth 等)
        for iface in $(ls /sys/class/net | grep -vE "^(lo|tun|docker|veth|cali|flannel|cni|dummy|kube)"); do
            # 开启 RPS (多核分流)
            if [ -f "/sys/class/net/$iface/queues/rx-0/rps_cpus" ]; then
                echo "f" > "/sys/class/net/$iface/queues/rx-0/rps_cpus" 2>/dev/null
                echo "      - $iface: RPS 已启用 (4核负载均衡)"
            fi
            
            # 关闭可能导致问题的 Offloading (解决断流/兼容性)
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

    # ==================== 辅助：网络保障脚本 (已修复 DNS 问题) ====================
    generate_network_script() {
        echo -e "${BLUE}>>> 生成基础网络脚本 (${RULE_SCRIPT})...${NC}"
        # 这个脚本负责在 Mihomo 启动时开启 NAT 和 DNS 劫持
        cat > "$RULE_SCRIPT" <<'EOF'
#!/bin/bash
# Mihomo 基础网络管理器 (增强版)
# 作用: 
# 1. 开启 NAT (Masquerade)，确保作为网关时下游设备有网
# 2. 开启 DNS 劫持 (53->1053)，解决 auto-redirect: false 时局域网设备无法解析的问题

# 获取出口网卡 (用于 NAT)
IFACE=$(ip route show default | awk '/default/ {print $5}' | head -n1)

enable_nat() {
    echo "  - [Network] 正在应用网络规则 (NAT + DNS劫持)..."
    
    # 1. 强制开启转发
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    sysctl -w net.ipv4.conf.all.src_valid_mark=1 >/dev/null
    # 确保防火墙允许转发 (防止默认 DROP)
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
    # 将局域网发往网关 53 端口的 UDP/TCP 请求，重定向到 1053
    # 先清理可能存在的旧规则，避免重复
    iptables -t nat -D PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 1053 2>/dev/null
    iptables -t nat -D PREROUTING -p tcp --dport 53 -j REDIRECT --to-ports 1053 2>/dev/null
    
    # 添加新规则
    iptables -t nat -A PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 1053
    iptables -t nat -A PREROUTING -p tcp --dport 53 -j REDIRECT --to-ports 1053
    echo "    [DNS] 强制劫持已开启: UDP/TCP 53 -> 1053"
}

disable_nat() {
    echo "  - [Network] 清理网络规则..."
    # 停止时清理 DNS 劫持规则，恢复系统原状
    iptables -t nat -D PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 1053 2>/dev/null
    iptables -t nat -D PREROUTING -p tcp --dport 53 -j REDIRECT --to-ports 1053 2>/dev/null
    echo "    [DNS] 劫持规则已移除"
    # NAT 规则通常保留，避免瞬间断网
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
        echo -e "${GREEN}✅ 网络辅助脚本生成完毕 (含 DNS 修复)${NC}"
    }

    # ==================== 新增：网卡选择交互函数 ====================
    configure_interface() {
        echo -e "${BLUE}>>> 正在配置出口网卡 (绑定物理接口)...${NC}"
        
        # 1. 获取物理网卡列表 (排除 lo, tun, docker, veth, cali 等虚拟网卡)
        # 这里的逻辑是获取 /sys/class/net 下的目录
        INTERFACES=$(ls /sys/class/net | grep -vE "^(lo|tun|docker|veth|cali|flannel|cni|dummy)")
        
        # 如果有 br-lan (OpenWrt/旁路由常见)，把它加到列表最前面
        if [ -d "/sys/class/net/br-lan" ]; then
            # 简单去重逻辑
            INTERFACES=$(echo "$INTERFACES" | sed 's/br-lan//g')
            INTERFACES="br-lan $INTERFACES"
        fi

        # 转换为数组以便 select 使用
        IFACE_LIST=($INTERFACES "自动检测(Auto)")

        echo -e "${YELLOW}检测到以下网卡，请选择主要流量出口 (通常是 eth0 或 br-lan):${NC}"
        
        select iface in "${IFACE_LIST[@]}"; do
            if [ "$iface" == "自动检测(Auto)" ]; then
                echo -e "已选择: ${GREEN}自动检测${NC}"
                # 恢复 auto-detect 为 true
                sed -i 's/auto-detect-interface: false/auto-detect-interface: true/' "$CONF_DIR/config.yaml"
                # 注释掉 interface-name
                sed -i 's/^interface-name:/# interface-name:/' "$CONF_DIR/config.yaml"
                break
            elif [ -n "$iface" ]; then
                echo -e "已锁定网卡: ${GREEN}$iface${NC}"
                
                # 1. 修改 auto-detect-interface 为 false
                sed -i 's/auto-detect-interface: true/auto-detect-interface: false/' "$CONF_DIR/config.yaml"
                
                # 2. 修改 interface-name
                # 先尝试替换已有的 (去掉注释 #)
                if grep -q "interface-name:" "$CONF_DIR/config.yaml"; then
                    # 匹配 # interface-name: xxx 或 interface-name: xxx，替换为 interface-name: $iface
                    sed -i "s/^#\? *interface-name:.*/interface-name: $iface/" "$CONF_DIR/config.yaml"
                else
                    # 如果配置文件里完全没这一行，插在文件头部
                    sed -i "1i interface-name: $iface" "$CONF_DIR/config.yaml"
                fi
                break
            else
                echo "输入错误，请重新选择数字。"
            fi
        done
    }

    # ==================== 1. 服务配置函数 (深度融合) ====================
    setup_service() {
        echo -e "${BLUE}>>> 配置 Systemd 服务...${NC}"
        mkdir -p "$CONF_DIR"
        
        generate_network_script

        # --- 配置文件处理 ---
        if [ ! -f "$CONF_DIR/config.yaml" ]; then
             if [ -f "$AUTO_DIR/config_tun.yaml" ]; then
                 cp "$AUTO_DIR/config_tun.yaml" "$CONF_DIR/config.yaml"
                 echo -e "${GREEN}✅ 已应用仓库文件: config_tun.yaml${NC}"
             elif [ -f "$MANUAL_DIR/config_tun.yaml" ]; then
                 cp "$MANUAL_DIR/config_tun.yaml" "$CONF_DIR/config.yaml"
                 echo -e "${GREEN}✅ 已应用本地文件: config_tun.yaml${NC}"
             elif [ -f "$AUTO_DIR/config.yaml" ]; then
                 cp "$AUTO_DIR/config.yaml" "$CONF_DIR/config.yaml"
                 echo -e "${GREEN}✅ 已应用仓库中的 config.yaml${NC}"
             elif [ -f "$MANUAL_DIR/config.yaml" ]; then
                 cp "$MANUAL_DIR/config.yaml" "$CONF_DIR/config.yaml"
                 echo -e "${GREEN}✅ 已应用本地 config.yaml${NC}"
             else
                 echo -e "${YELLOW}⚠️ 未检测到任何配置文件，生成空配置...${NC}"
                 touch "$CONF_DIR/config.yaml"
                 echo -e "${RED}⚠️ 请注意：你需要自行编辑 $CONF_DIR/config.yaml 填入订阅信息！${NC}"
             fi
        fi

        # =========== 【插入点】 ===========
        # 配置文件就位后，立即询问网卡设置
        configure_interface
        # ================================

        # --- Service 文件生成 ---
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

# 启动前检测网络
ExecStartPre=/bin/bash -c 'for i in {1..20}; do if ip route show default | grep -q "default"; then echo "Network ready"; exit 0; fi; sleep 1; done; echo "Network not ready"; exit 1'

# 启动前加载网络规则 (NAT + DNS劫持)
ExecStartPre=$RULE_SCRIPT start

ExecStart=$BIN_PATH -d $CONF_DIR

# 停止后清理规则
ExecStopPost=$RULE_SCRIPT stop

ExecReload=/bin/kill -HUP \$MAINPID
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
        echo -e "${GREEN}✅ 已生成融合优化版服务配置${NC}"

        systemctl daemon-reload
        systemctl enable mihomo
        echo -e "${GREEN}✅ 服务已配置并设置为开机自启${NC}"
    }

    # ==================== 2. 在线下载安装 ====================
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

        echo -e "${BLUE}>>> 正在获取 Mihomo 版本信息...${NC}"
        LATEST_VER=$(curl -s -m 5 https://api.github.com/repos/MetaCubeX/mihomo/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        
        if [ -z "$LATEST_VER" ]; then
            read -p "获取失败，请输入欲安装的版本号 (例如 v1.18.5): " LATEST_VER < /dev/tty
            if [ -z "$LATEST_VER" ]; then echo "❌ 未输入版本号"; return 1; fi
        fi
        
        local proxy_prefix="${PROXY_PREFIX:-https://ghproxy.net/}"
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
            echo "请选择："
            echo "1. 我现在去上传到 $MANUAL_DIR，然后按回车"
            echo "2. 放弃"
            read -p "选择: " choice < /dev/tty
            if [ "$choice" == "1" ]; then
                mkdir -p "$MANUAL_DIR"
                read -p "上传完成后，请按回车继续..." < /dev/tty
                if [ -f "$MANUAL_DIR/mihomo" ]; then
                    SOURCE_FILE="$MANUAL_DIR/mihomo"
                else
                    echo -e "${RED}还是没找到，退出。${NC}"
                    return 1
                fi
            else
                return 1
            fi
        fi

        echo -e "正在安装核心文件..."
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
        echo -e "${RED}⚠️  警告：准备卸载 Mihomo (TUN)${NC}"
        read -p "确认要卸载吗？(y/N): " confirm < /dev/tty
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then echo "已取消"; return; fi

        systemctl stop mihomo 2>/dev/null
        systemctl disable mihomo 2>/dev/null
        
        if [ -f "$RULE_SCRIPT" ]; then
            rm -f "$RULE_SCRIPT"
        fi

        rm -f "$BIN_PATH"
        rm -f /etc/systemd/system/mihomo.service
        systemctl daemon-reload

        if [ -d "$CONF_DIR" ]; then
            read -p "是否保留配置文件? [y/N]: " keep_conf < /dev/tty
            if [[ ! "$keep_conf" =~ ^[Yy]$ ]]; then
                rm -rf "$CONF_DIR"
            fi
        fi
        echo -e "${GREEN}✅ 卸载完成。${NC}"
    }

    # ==================== 菜单逻辑 ====================
    echo -e "${GREEN}=== Mihomo 安装向导 (TUN 融合Pro版) ===${NC}"
    echo "1. 手动应用内核优化 (刷新网络规则+RPS)"
    echo "2. 在线安装 (下载官方最新版)"
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