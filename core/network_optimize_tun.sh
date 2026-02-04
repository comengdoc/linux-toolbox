#!/bin/bash
# ==============================================================================
# 友善 R5C 全能网络优化脚本 (v2.0 终极修复版)
# 功能：Sysctl/BBR/RPS/Ethtool/NAT/DNS劫持 + NetworkManager钩子防掉速
# ==============================================================================

if [ "$EUID" -ne 0 ]; then
  echo "❌ 请使用 root 权限运行"
  exit 1
fi

# ================= 1. 内核参数与 BBR 优化 =================
echo ">>> [1/5] 配置内核参数与 BBR..."

# 加载必要的内核模块
modprobe tcp_bbr
modprobe sch_fq

# 持久化加载模块
cat > /etc/modules-load.d/r5c_net.conf <<EOF
tcp_bbr
sch_fq
EOF

# 写入 Sysctl 配置
cat > /etc/sysctl.d/99-r5c-ultra.conf <<EOF
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv4.conf.all.src_valid_mark = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.rps_sock_flow_entries = 32768
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 16384 16777216
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_max_syn_backlog = 65536
EOF

sysctl --system >/dev/null 2>&1

# ================= 2. 生成核心优化逻辑脚本 =================
echo ">>> [2/5] 生成运行时核心脚本..."

SCRIPT_PATH="/usr/local/bin/r5c-network-tuning.sh"

cat > "$SCRIPT_PATH" <<'EOF'
#!/bin/bash

# --- A. 硬件中断与卸载优化 ---
# 自动识别物理网卡 (排除 tun/docker/lo 等)
PHY_INTERFACES=$(ls /sys/class/net/ | grep -vE "^(lo|tun|docker|veth|cali|flannel|cni|dummy|br-)")
CPU_MASK="f" 

for IFACE in $PHY_INTERFACES; do
    if [ ! -d "/sys/class/net/$IFACE" ]; then continue; fi

    # 1. 配置 RPS
    for rps_file in /sys/class/net/$IFACE/queues/rx-*/rps_cpus; do
        [ -f "$rps_file" ] && echo "$CPU_MASK" > "$rps_file"
    done
    for rps_flow in /sys/class/net/$IFACE/queues/rx-*/rps_flow_cnt; do
        [ -f "$rps_flow" ] && echo 4096 > "$rps_flow"
    done

    # 2. 配置 Ethtool (关键：关闭 GRO 防止 Tun 模式掉速)
    ethtool -K $IFACE gro off lro off >/dev/null 2>&1
    ethtool -K $IFACE gso on tso on sg on >/dev/null 2>&1
    ethtool -G $IFACE rx 4096 tx 4096 >/dev/null 2>&1
    ethtool --set-eee $IFACE eee off >/dev/null 2>&1
done

# --- B. 防火墙与 NAT 转发 ---
DEFAULT_IFACE=$(ip route show default | awk '/default/ {print $5}' | head -n1)
if [ -n "$DEFAULT_IFACE" ]; then
    iptables -t nat -C POSTROUTING -o "$DEFAULT_IFACE" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -o "$DEFAULT_IFACE" -j MASQUERADE
fi
iptables -P FORWARD ACCEPT

# --- C. DNS 劫持 (配合 Mihomo) ---
UPSTREAM_DNS_1="223.5.5.5"
UPSTREAM_DNS_2="119.29.29.29"

# 清理旧规则
iptables -t nat -D PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 1053 2>/dev/null
iptables -t nat -D PREROUTING -p tcp --dport 53 -j REDIRECT --to-ports 1053 2>/dev/null
iptables -t nat -D OUTPUT -p udp --dport 53 -j REDIRECT --to-ports 1053 2>/dev/null
iptables -t nat -D OUTPUT -p tcp --dport 53 -j REDIRECT --to-ports 1053 2>/dev/null
iptables -t nat -D OUTPUT -d $UPSTREAM_DNS_1 -p udp --dport 53 -j RETURN 2>/dev/null
iptables -t nat -D OUTPUT -d $UPSTREAM_DNS_2 -p udp --dport 53 -j RETURN 2>/dev/null

# 应用规则
iptables -t nat -A PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 1053
iptables -t nat -A PREROUTING -p tcp --dport 53 -j REDIRECT --to-ports 1053
iptables -t nat -A OUTPUT -d $UPSTREAM_DNS_1 -p udp --dport 53 -j RETURN
iptables -t nat -A OUTPUT -d $UPSTREAM_DNS_2 -p udp --dport 53 -j RETURN
iptables -t nat -A OUTPUT -p udp --dport 53 -j REDIRECT --to-ports 1053
iptables -t nat -A OUTPUT -p tcp --dport 53 -j REDIRECT --to-ports 1053

echo "R5C Network Optimized: RPS, Ethtool(GRO:off), NAT, DNS-Hijack applied."
EOF

chmod +x "$SCRIPT_PATH"

# ================= 3. 配置 NetworkManager 钩子 (防掉速核心) =================
# 这是新增的关键步骤：解决重启后 eth0/lan1 设置被覆盖的问题
echo ">>> [3/5] 配置 NetworkManager 钩子 (防止优化被覆盖)..."

mkdir -p /etc/NetworkManager/dispatcher.d/
HOOK_FILE="/etc/NetworkManager/dispatcher.d/99-r5c-optimize"

cat > "$HOOK_FILE" <<EOF
#!/bin/bash
# 自动监听所有接口状态
INTERFACE=\$1
STATUS=\$2

# 当接口建立连接(up)或配置重载(reapply)时，强制执行优化脚本
if [ "\$STATUS" = "up" ] || [ "\$STATUS" = "reapply" ]; then
    /usr/local/bin/r5c-network-tuning.sh
fi
EOF

chmod +x "$HOOK_FILE"
chown root:root "$HOOK_FILE"

# ================= 4. 配置 Systemd 服务 (作为双重保险) =================
echo ">>> [4/5] 配置 Systemd 服务..."

SERVICE_FILE="/etc/systemd/system/r5c-network.service"

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=R5C Advanced Network Optimization
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$SCRIPT_PATH
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# ================= 5. 激活服务 =================
echo ">>> [5/5] 激活并运行优化..."
systemctl daemon-reload
systemctl enable r5c-network.service
systemctl restart r5c-network.service

echo "-------------------------------------------------------"
echo "✅ 终极优化脚本部署完成！"
echo "   1. 核心优化脚本已生成至: $SCRIPT_PATH"
echo "   2. NetworkManager 钩子已安装 (解决重启掉速/GRO问题)"
echo "   3. Systemd 服务已启动 (确保开机自启)"
echo "   4. 无论你使用 eth0 还是 lan1，脚本都会自动识别并优化"
echo "-------------------------------------------------------"