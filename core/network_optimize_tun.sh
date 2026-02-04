#!/bin/bash
# ==============================================================================
# 友善 R5C 全能网络优化脚本 (Tun模式适配版) - 已修复本机 DNS 问题
# 功能：整合 Sysctl/BBR/RPS/Ethtool/NAT/DNS劫持，并实现 Systemd 持久化
# ==============================================================================

if [ "$EUID" -ne 0 ]; then
  echo "❌ 请使用 root 权限运行"
  exit 1
fi

# ================= 1. 内核参数与 BBR 优化 =================
echo ">>> [1/4] 配置内核参数与 BBR..."

# 加载必要的内核模块
modprobe tcp_bbr
modprobe sch_fq

# 持久化加载模块
cat > /etc/modules-load.d/r5c_net.conf <<EOF
tcp_bbr
sch_fq
EOF

# 写入 Sysctl 配置 (强制 fq + bbr，优化连接跟踪)
cat > /etc/sysctl.d/99-r5c-ultra.conf <<EOF
# 开启转发
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv4.conf.all.src_valid_mark = 1

# 拥塞控制 (解决冲突：统一使用 fq + bbr)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# 连接跟踪 (针对 P2P 和大量连接优化)
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_tcp_timeout_established = 7200

# 缓冲区优化 (适配千兆/2.5G网络)
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.rps_sock_flow_entries = 32768
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 16384 16777216

# TCP 特性
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_max_syn_backlog = 65536
EOF

# 应用 Sysctl
sysctl --system >/dev/null 2>&1

# ================= 2. 生成硬件与防火墙执行脚本 =================
echo ">>> [2/4] 生成运行时优化脚本..."

SCRIPT_PATH="/usr/local/bin/r5c-network-tuning.sh"

cat > "$SCRIPT_PATH" <<'EOF'
#!/bin/bash

# --- A. 硬件中断与卸载优化 ---
# 排除虚拟接口，只针对物理网卡
PHY_INTERFACES=$(ls /sys/class/net/ | grep -vE "^(lo|tun|docker|veth|cali|flannel|cni|dummy|br-)")
CPU_MASK="f" # R5C 是4核CPU，掩码 f (二进制 1111) 表示所有核心参与

for IFACE in $PHY_INTERFACES; do
    if [ ! -d "/sys/class/net/$IFACE" ]; then continue; fi

    # 1. 配置 RPS (Receive Packet Steering) - 解决软中断单核瓶颈
    for rps_file in /sys/class/net/$IFACE/queues/rx-*/rps_cpus; do
        [ -f "$rps_file" ] && echo "$CPU_MASK" > "$rps_file"
    done
    for rps_flow in /sys/class/net/$IFACE/queues/rx-*/rps_flow_cnt; do
        [ -f "$rps_flow" ] && echo 4096 > "$rps_flow"
    done

    # 2. 配置 Ethtool (解决冲突：Tun模式下必须关闭 GRO/LRO)
    # 开启 GSO/TSO 减轻 CPU 负担，但关闭 GRO 防止 Tun 包聚合问题
    ethtool -K $IFACE gro off lro off >/dev/null 2>&1
    ethtool -K $IFACE gso on tso on sg on >/dev/null 2>&1
    
    # 增大环形缓冲区
    ethtool -G $IFACE rx 4096 tx 4096 >/dev/null 2>&1
    
    # 关闭节能 (EEE) 防止断流
    ethtool --set-eee $IFACE eee off >/dev/null 2>&1
done

# --- B. 防火墙与 NAT 转发 ---
# 获取默认出口网卡
DEFAULT_IFACE=$(ip route show default | awk '/default/ {print $5}' | head -n1)

# 开启 NAT 伪装 (Masquerade)
if [ -n "$DEFAULT_IFACE" ]; then
    iptables -t nat -C POSTROUTING -o "$DEFAULT_IFACE" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -o "$DEFAULT_IFACE" -j MASQUERADE
fi

# 确保转发链开放
iptables -P FORWARD ACCEPT

# --- C. DNS 劫持 (配合 Mihomo) ---
# 定义 Mihomo 配置文件中使用的上游直连 DNS (防止死循环)
# 必须与 config.yaml 中的 direct-nameserver 保持一致
UPSTREAM_DNS_1="223.5.5.5"
UPSTREAM_DNS_2="119.29.29.29"

# 1. 清理旧规则 (防止重复叠加)
iptables -t nat -D PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 1053 2>/dev/null
iptables -t nat -D PREROUTING -p tcp --dport 53 -j REDIRECT --to-ports 1053 2>/dev/null
iptables -t nat -D OUTPUT -p udp --dport 53 -j REDIRECT --to-ports 1053 2>/dev/null
iptables -t nat -D OUTPUT -p tcp --dport 53 -j REDIRECT --to-ports 1053 2>/dev/null
# 清理防环路规则
iptables -t nat -D OUTPUT -d $UPSTREAM_DNS_1 -p udp --dport 53 -j RETURN 2>/dev/null
iptables -t nat -D OUTPUT -d $UPSTREAM_DNS_2 -p udp --dport 53 -j RETURN 2>/dev/null

# 2. 局域网设备劫持 (PREROUTING 链)
iptables -t nat -A PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 1053
iptables -t nat -A PREROUTING -p tcp --dport 53 -j REDIRECT --to-ports 1053

# 3. 本机劫持 (OUTPUT 链) - 【关键修复】
# 3.1 防环路：如果目标是 Mihomo 的上游 DNS，直接放行 (RETURN)，不进行重定向
iptables -t nat -A OUTPUT -d $UPSTREAM_DNS_1 -p udp --dport 53 -j RETURN
iptables -t nat -A OUTPUT -d $UPSTREAM_DNS_2 -p udp --dport 53 -j RETURN

# 3.2 劫持：其他所有发往 53 端口的流量重定向到本地 1053
iptables -t nat -A OUTPUT -p udp --dport 53 -j REDIRECT --to-ports 1053
iptables -t nat -A OUTPUT -p tcp --dport 53 -j REDIRECT --to-ports 1053

echo "R5C Network Optimized: RPS(Mask:f), Offload(Fixed), NAT($DEFAULT_IFACE), DNS-Hijack(LAN+Localhost)"
EOF

chmod +x "$SCRIPT_PATH"

# ================= 3. 配置 Systemd 服务实现持久化 =================
echo ">>> [3/4] 配置开机自启服务..."

SERVICE_FILE="/etc/systemd/system/r5c-network.service"

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=R5C Advanced Network Optimization & Persistence
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$SCRIPT_PATH
RemainAfterExit=yes
SuccessExitStatus=0 1

[Install]
WantedBy=multi-user.target
EOF

# ================= 4. 激活服务 =================
echo ">>> [4/4] 激活并运行优化..."
systemctl daemon-reload
systemctl enable r5c-network.service
systemctl restart r5c-network.service

echo "-------------------------------------------------------"
echo "✅ 优化脚本部署完成！"
echo "   - 核心: BBR + FQ 已启用"
echo "   - 硬件: RPS 4核均衡, 关闭 GRO/LRO (适配 Tun)"
echo "   - 网络: 开启 NAT, 开启 DNS 劫持 (53->1053)"
echo "   - 修复: 已增加本机 DNS (OUTPUT链) 劫持与防环路保护"
echo "   - 状态: 已设置为开机自启 (r5c-network.service)"
echo "-------------------------------------------------------"