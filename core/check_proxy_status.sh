#!/bin/bash

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# --- 核心配置参数 ---
# 这是防火墙(iptables)转发的目标端口
# 请确保这里与 configure_tproxy.sh 中的 TPROXY_PORT 一致 (当前为 7894)
TARGET_PORT=7894
PROXY_FWMARK=0x1
PROXY_ROUTE_TABLE=100

echo -e "${CYAN}=== 系统代理状态检测模块 (Smart Diagnostic) ===${NC}"

# ===========================
# 1. 核心服务、端口及自启检测
# ===========================
CORE_STATUS="未知"
RUNNING_CORE=""
PID=""
AUTO_START_STATUS="${YELLOW}未知${NC}"

# 检测 Systemd 服务状态并获取 PID
if systemctl is-active --quiet mihomo; then
    RUNNING_CORE="mihomo"
    CORE_STATUS="${GREEN}运行中 (Active)${NC}"
    PID=$(pgrep -x mihomo | head -n 1)
elif systemctl is-active --quiet sing-box; then
    RUNNING_CORE="sing-box"
    CORE_STATUS="${GREEN}运行中 (Active)${NC}"
    PID=$(pgrep -x sing-box | head -n 1)
else
    CORE_STATUS="${RED}未运行${NC}"
fi

# 如果检测到核心服务，检查是否开机自启
if [ -n "$RUNNING_CORE" ]; then
    if systemctl is-enabled --quiet "$RUNNING_CORE"; then
        AUTO_START_STATUS="${GREEN}已开启 (Enabled)${NC}"
    else
        AUTO_START_STATUS="${RED}未开启 (Disabled)${NC}"
    fi
fi

echo -e "核心服务: [ ${RUNNING_CORE:-无} ] -> $CORE_STATUS | 自启: $AUTO_START_STATUS"

# --- 端口智能诊断 ---
if [ -n "$RUNNING_CORE" ]; then
    # 1. 检查目标端口是否被监听
    LISTENING_CHECK=$(ss -lntup | grep ":$TARGET_PORT")
    
    if [ -n "$LISTENING_CHECK" ]; then
        echo -e "端口状态: ${GREEN}正常 (监听 $TARGET_PORT)${NC}"
    else
        echo -e "端口状态: ${RED}异常 (目标 $TARGET_PORT 未被监听)${NC}"
        
        # 2. 如果目标端口没开，自动列出该程序实际监听的端口
        if [ -n "$PID" ]; then
            echo -e "${YELLOW}>>> 正在扫描 $RUNNING_CORE (PID: $PID) 实际监听的端口...${NC}"
            # 查找属于该 PID 的监听端口，并格式化输出
            ACTUAL_PORTS=$(ss -lntup | grep "pid=$PID" | awk '{print $5}' | cut -d: -f2 | sort -u | tr '\n' ' ')
            
            if [ -n "$ACTUAL_PORTS" ]; then
                echo -e "发现实际监听端口: ${CYAN}[ $ACTUAL_PORTS]${NC}"
                echo -e "${YELLOW}建议: 请将 configure_tproxy.sh 中的 TPROXY_PORT 修改为上述端口之一。${NC}"
            else
                echo -e "${RED}警告: 该进程似乎没有监听任何 TCP/UDP 端口！${NC}"
            fi
        fi
    fi
else
    echo -e "${YELLOW}跳过端口检测${NC}"
fi

if [ -z "$RUNNING_CORE" ]; then
    echo -e "${YELLOW}提示: 未检测到 Mihomo 或 Sing-box 服务运行。${NC}"
fi

# ===========================
# 2. 网络模式与 NAT 深度检测
# ===========================
NETWORK_MODE="无代理"
MODE_DETAIL=""

# A. 检测 TUN 接口
TUN_DEVICE=$(ip -o link show type tun | awk -F': ' '{print $2}' | head -n 1)

# B. 检测 TProxy 策略路由
TPROXY_RULE=$(ip rule show | grep "fwmark $PROXY_FWMARK")

# C. 深度 NAT 检测函数
check_nat_status() {
    local nat_status="未检测到"
    local color=$RED
    
    # 1. 检查 IPTables
    if iptables -t nat -S POSTROUTING 2>/dev/null | grep -q -E "MASQUERADE|SNAT"; then
        nat_status="已开启 (iptables)"
        color=$GREEN
        echo -e "${color}${nat_status}${NC}"
        return
    fi

    # 2. 检查 NFTables
    if command -v nft >/dev/null; then
        if nft list ruleset 2>/dev/null | grep -q "masquerade"; then
            nat_status="已开启 (nftables)"
            color=$GREEN
        fi
    fi
    echo -e "${color}${nat_status}${NC}"
}

if [ -n "$TUN_DEVICE" ]; then
    NETWORK_MODE="${GREEN}TUN 模式${NC}"
    MODE_DETAIL="(设备名: $TUN_DEVICE)"
    NAT_MSG=$(check_nat_status)
    MODE_DETAIL="$MODE_DETAIL\n      └─ NAT 伪装: $NAT_MSG"

elif [ -n "$TPROXY_RULE" ]; then
    NETWORK_MODE="${GREEN}TProxy 模式${NC}"
    MODE_DETAIL="(策略路由: fwmark $PROXY_FWMARK -> table $PROXY_ROUTE_TABLE)"
    NAT_MSG=$(check_nat_status)
    MODE_DETAIL="$MODE_DETAIL\n      └─ NAT 伪装: $NAT_MSG"
else
    NETWORK_MODE="${YELLOW}直连 / 未知${NC}"
fi

echo -e "运行模式: $NETWORK_MODE $MODE_DETAIL"

# ===========================
# 3. 内核参数连通性检查 (仅 TProxy)
# ===========================
if [[ "$NETWORK_MODE" == *"TProxy"* ]]; then
    echo -e "\n${CYAN}--- TProxy 环境诊断 ---${NC}"
    
    RP_ALL=$(sysctl -n net.ipv4.conf.all.rp_filter)
    RP_DEF=$(sysctl -n net.ipv4.conf.default.rp_filter)
    DEFAULT_IFACE=$(ip -4 route show default | grep default | awk '{print $5}' | head -n 1)
    if [ -n "$DEFAULT_IFACE" ]; then
        RP_IFACE=$(sysctl -n net.ipv4.conf.$DEFAULT_IFACE.rp_filter 2>/dev/null)
    else
        RP_IFACE="未知"
    fi

    if [ "$RP_ALL" -eq 0 ] && [ "$RP_DEF" -eq 0 ] && ([ "$RP_IFACE" -eq 0 ] || [ "$RP_IFACE" = "未知" ]); then
         echo -e "rp_filter (反向过滤): ${GREEN}正常 (全0)${NC}"
    else
         echo -e "rp_filter (反向过滤): ${RED}异常! (all=$RP_ALL, default=$RP_DEF, $DEFAULT_IFACE=$RP_IFACE) -> 需全部为0${NC}"
    fi
    
    IP_FWD=$(sysctl -n net.ipv4.ip_forward)
    if [ "$IP_FWD" -eq 1 ]; then
        echo -e "ip_forward (IP转发):  ${GREEN}正常 (1)${NC}"
    else
        echo -e "ip_forward (IP转发):  ${RED}异常 (0) -> 局域网无法上网${NC}"
    fi
fi

echo -e "${CYAN}=========================${NC}"