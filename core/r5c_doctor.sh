#!/bin/bash
# ==============================================================================
# R5C & Mihomo 全能网络医生 (Ultimate Doctor Script)
# 模块名称: r5c_doctor.sh
# 功能：整合系统内核、物理网卡硬件参数、虚拟网卡、防火墙、服务及连通性测试
# ==============================================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${BLUE}========================================================${NC}"
echo -e "${BLUE}      R5C & Mihomo 系统全能诊断报告 (Doctor v3.0)      ${NC}"
echo -e "${BLUE}========================================================${NC}"

# ----------------------------------------------------------------
# [第一层] 内核与系统参数 (System Kernel)
# ----------------------------------------------------------------
echo -e "${CYAN}>>> [1/7] 内核与系统参数${NC}"

# 1.1 IP 转发
echo -n "   - IPv4 流量转发:        "
FW4=$(sysctl -n net.ipv4.ip_forward)
if [ "$FW4" == "1" ]; then 
    echo -e "${GREEN}✅ 已开启${NC}"
else 
    echo -e "${RED}❌ 未开启 (致命: 无法做路由转发)${NC}"
fi

# 1.2 BBR 拥塞控制
echo -n "   - TCP BBR 拥塞控制:     "
CC=$(sysctl -n net.ipv4.tcp_congestion_control)
if [ "$CC" == "bbr" ]; then 
    echo -e "${GREEN}✅ 已开启${NC}"
else 
    echo -e "${YELLOW}⚠️ 未开启 (当前: $CC, 建议开启以优化速度)${NC}"
fi

# ----------------------------------------------------------------
# [第二层] 系统服务状态 (System Services)
# ----------------------------------------------------------------
echo -e "${CYAN}>>> [2/7] 关键服务状态${NC}"

# 2.1 Mihomo 主程序
echo -n "   - Mihomo 主服务:        "
if systemctl is-active --quiet mihomo; then
    VER=$(/usr/local/bin/mihomo -v 2>/dev/null | head -n 1 | awk '{print $3}')
    echo -e "${GREEN}✅ 运行中 (Ver: $VER)${NC}"
else
    echo -e "${RED}❌ 未运行${NC}"
fi

# 2.2 网络优化脚本
echo -n "   - 网络优化服务:         "
if systemctl is-active --quiet r5c-network.service; then
    echo -e "${GREEN}✅ 运行中 (r5c-network.service)${NC}"
else
    echo -e "${YELLOW}⚠️ 未运行 (透明代理规则可能未加载)${NC}"
fi

# ----------------------------------------------------------------
# [第三层] 物理网卡硬件优化 (Physical Hardware)
# ----------------------------------------------------------------
echo -e "${CYAN}>>> [3/7] 物理网卡硬件参数 (RPS/GSO)${NC}"

# 智能扫描物理网卡 (排除 lo, tun, docker, br, veth, meta 等)
PHY_INTERFACES=""
for iface_path in /sys/class/net/*; do
    iface_name=$(basename "$iface_path")
    # 排除逻辑
    if [[ "$iface_name" =~ ^(lo|tun|utun|meta|docker|veth|br-|wg)*$ ]]; then continue; fi
    # 包含逻辑：有 device 物理链接 或者是 lan/wan/eth/enp 开头
    if [ -e "$iface_path/device" ] || [[ "$iface_name" =~ ^(lan|wan|eth|end|enp) ]]; then
        PHY_INTERFACES="$PHY_INTERFACES $iface_name"
    fi
done

for IFACE in $PHY_INTERFACES; do
    # Check RPS (4核均衡)
    RPS_VAL=$(cat /sys/class/net/$IFACE/queues/rx-0/rps_cpus 2>/dev/null)
    if [[ "$RPS_VAL" =~ [fF]$ ]]; then
         RPS_MSG="${GREEN}✅ RPS均衡($RPS_VAL)${NC}"
    else
         RPS_MSG="${RED}❌ RPS未全核($RPS_VAL)${NC}"
    fi

    # Check GSO (Offload)
    GSO_VAL=$(ethtool -k $IFACE 2>/dev/null | grep "generic-segmentation-offload:" | awk '{print $2}')
    if [ "$GSO_VAL" == "on" ]; then
        GSO_MSG="${GREEN}✅ GSO开启${NC}"
    else
        GSO_MSG="${RED}❌ GSO关闭${NC}"
    fi
    
    echo -e "   - 接口 $IFACE: \t$RPS_MSG | $GSO_MSG"
done

# ----------------------------------------------------------------
# [第四层] 虚拟网络接口 (Virtual Network)
# ----------------------------------------------------------------
echo -e "${CYAN}>>> [4/7] Tun 虚拟网卡检测${NC}"

# 智能匹配 (忽略大小写)
echo -n "   - Tun/Meta 接口:        "
TUN_INFO=$(ip addr show | grep -iE "^[0-9]+: (meta|utun|tun|clash)" | head -n 1)
TUN_NAME=$(echo "$TUN_INFO" | awk -F': ' '{print $2}')

if [ -n "$TUN_NAME" ]; then
    echo -e "${GREEN}✅ 正常 (名称: $TUN_NAME)${NC}"
else
    echo -e "${RED}❌ 未找到 (Mihomo 未创建网卡)${NC}"
fi

# ----------------------------------------------------------------
# [第五层] 防火墙与路由规则 (Firewall & Routing)
# ----------------------------------------------------------------
echo -e "${CYAN}>>> [5/7] 防火墙与劫持规则${NC}"

# 5.1 NAT 伪装 (决定局域网设备能否通过R5C上网)
echo -n "   - NAT 伪装 (Masquerade):"
if iptables -t nat -nL POSTROUTING 2>/dev/null | grep -q "MASQUERADE"; then
    echo -e "${GREEN}✅ 已启用${NC}"
else
    echo -e "${YELLOW}⚠️ 未启用 (旁路网关可能异常)${NC}"
fi

# 5.2 DNS 劫持 - OUTPUT (决定本机能否翻墙)
echo -n "   - 本机 DNS 劫持 (OUTPUT):"
if iptables -t nat -S OUTPUT | grep -q "1053"; then
    echo -e "${GREEN}✅ 已启用${NC}"
else
    echo -e "${RED}❌ 未启用 (本机无法解析国外域名)${NC}"
fi

# 5.3 DNS 劫持 - PREROUTING (决定局域网设备能否翻墙)
echo -n "   - 局域网 DNS劫持 (PRE): "
if iptables -t nat -S PREROUTING | grep -q "1053"; then
    echo -e "${GREEN}✅ 已启用${NC}"
else
    echo -e "${RED}❌ 未启用 (局域网设备DNS未接管)${NC}"
fi

# ----------------------------------------------------------------
# [第六层] 端口监听 (Ports)
# ----------------------------------------------------------------
echo -e "${CYAN}>>> [6/7] 核心端口监听${NC}"

check_port() {
    local port=$1
    local name=$2
    if ss -tulpn | grep -q ":$port "; then
        echo -e "   - $name ($port): \t${GREEN}✅ 正常${NC}"
    else
        echo -e "   - $name ($port): \t${RED}❌ 未监听${NC}"
    fi
}
check_port 7890 "混合代理TCP"
check_port 1053 "DNS服务UDP "

# ----------------------------------------------------------------
# [第七层] 连通性测试 (Connectivity)
# ----------------------------------------------------------------
echo -e "${CYAN}>>> [7/7] 实战连通性测试${NC}"

# 7.1 代理连接测试
echo -n "   - Google (代理访问):    "
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 --proxy http://127.0.0.1:7890 https://www.google.com)
if [ "$HTTP_CODE" == "200" ]; then
    echo -e "${GREEN}✅ 成功 (200 OK)${NC}"
else
    echo -e "${RED}❌ 失败 (Code: $HTTP_CODE)${NC}"
fi

# 7.2 直连/DNS测试 (测试透明代理是否对本机生效)
echo -n "   - Google (本机Ping):    "
if ping -c 1 -W 2 www.google.com >/dev/null 2>&1; then
    echo -e "${GREEN}✅ 成功 (DNS/透明代理正常)${NC}"
else
    echo -e "${YELLOW}⚠️ 失败 (本机透明代理可能未生效)${NC}"
fi

echo -e "${BLUE}========================================================${NC}"