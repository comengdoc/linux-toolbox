#!/bin/bash
function module_bbr() {
    # 辅助：版本对比函数
    version_ge() { test "$(echo "$@" | tr " " "\n" | sort -rV | head -n 1)" == "$1"; }

    # 显示关键参数
    show_params() {
        echo "--- 当前关键参数 (sysctl) ---"
        # 增加显示 qdisc 状态，确认 fq 是否生效
        tc qdisc show dev $(ip route | grep default | awk '{print $5}' | head -n1) 2>/dev/null | head -n 1
        echo "-----------------------------------"
        sysctl_output=$(sysctl net.ipv4.tcp_congestion_control \
            net.ipv4.tcp_available_congestion_control \
            net.core.default_qdisc \
            net.ipv4.tcp_fastopen \
            net.ipv4.tcp_tw_reuse \
            net.ipv4.tcp_fin_timeout | column -t)
        echo "$sysctl_output"
        echo "-----------------------------------"
    }

    # 检查当前 BBR 状态
    check_bbr() {
        local cc=$(sysctl -n net.ipv4.tcp_congestion_control)
        local qdisc=$(sysctl -n net.core.default_qdisc)
        
        # BBR 必须配合 fq 使用才算完美
        if [[ "$cc" == "bbr" ]] && [[ "$qdisc" == "fq" ]]; then
            echo -e "✅ BBR 已启用 (且 qdisc=fq)"
            show_params
            return 0
        elif [[ "$cc" == "bbr" ]]; then
            echo -e "⚠️  BBR 已启用，但 qdisc 不是 fq (当前: $qdisc)，性能可能受限。"
            show_params
            return 1 # 视为未完美启用，允许用户重新配置
        else
            echo -e "❌ 当前拥塞控制算法为: $cc (qdisc: $qdisc)"
            show_params
            return 1
        fi
    }

    # 启用 BBR
    enable_bbr() {
        # 1. 检查内核版本
        KERNEL_VER=$(uname -r | cut -d- -f1)
        if ! version_ge "$KERNEL_VER" "4.9"; then
            echo -e "${RED}❌ 错误：内核版本过低 ($KERNEL_VER)。BBR 需要 Linux 4.9+。${NC}"
            return 1
        fi

        echo ">>> 1. 启用关键内核模块 (tcp_bbr & sch_fq)..."
        
        # [关键修复] 加载 sch_fq (Fair Queue)，这是 BBR 的伴侣
        modprobe sch_fq
        if ! lsmod | grep -q "sch_fq"; then
            echo -e "${YELLOW}⚠️  警告：无法加载 sch_fq 模块，BBR 可能无法全速运行。${NC}"
        fi

        modprobe tcp_bbr
        
        # 持久化模块加载
        mkdir -p /etc/modules-load.d
        echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
        echo "sch_fq" >> /etc/modules-load.d/bbr.conf
        
        echo ">>> 2. 写入 sysctl 优化配置..."
        cat > /etc/sysctl.d/99-bbr.conf <<EOF
# BBR Core Settings
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# TCP Network Optimization (Common)
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_max_syn_backlog = 65536
net.ipv4.tcp_max_tw_buckets = 6000
net.ipv4.tcp_sack = 1
net.ipv4.tcp_window_scaling = 1
EOF

        echo ">>> 3. 应用配置..."
        sysctl --system > /dev/null 2>&1

        echo ">>> 4. 验证结果..."
        local algo=$(sysctl -n net.ipv4.tcp_congestion_control)
        local qdisc=$(sysctl -n net.core.default_qdisc)

        if [ "$algo" = "bbr" ] && [ "$qdisc" = "fq" ]; then
            echo -e "${GREEN}✅ BBR + FQ 已成功启用！${NC}"
            show_params
        else
            echo -e "${RED}❌ 启用失败或不完整。${NC}"
            echo "当前: CC=$algo, QDISC=$qdisc"
        fi
    }

    # 主逻辑
    if ! check_bbr; then
        echo -e "${YELLOW}提示：建议启用 BBR 以优化 Sing-box/Mihomo 的网络吞吐。${NC}"
        
        # [修复] 增加 < /dev/tty
        read -p "是否要启用 BBR？(y/n, 输入 0 返回): " choice < /dev/tty
        
        if [[ "$choice" == "0" ]]; then return 0; fi

        if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
            enable_bbr
        else
            echo "已取消。"
        fi
    else
        # 即使已经开启，也允许用户强制重刷配置（修复 fq 缺失的情况）
        read -p "BBR 已检测到开启。是否强制重新应用配置？(y/N): " reapply < /dev/tty
        if [[ "$reapply" == "y" || "$reapply" == "Y" ]]; then
            enable_bbr
        fi
    fi
}