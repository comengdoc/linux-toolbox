#!/bin/bash
function module_bbr() {
    # 显示关键参数
    show_params() {
        echo "--- 当前关键参数 (sysctl) ---"
        sysctl_output=$(sysctl net.ipv4.tcp_congestion_control \
            net.ipv4.tcp_available_congestion_control \
            net.core.default_qdisc \
            net.ipv4.tcp_fastopen \
            net.core.rmem_max \
            net.core.wmem_max \
            net.ipv4.tcp_rmem \
            net.ipv4.tcp_wmem \
            net.ipv4.tcp_max_syn_backlog \
            net.ipv4.tcp_tw_reuse \
            net.ipv4.tcp_fin_timeout | column -t)
        echo "$sysctl_output"
        echo "-----------------------------------"
    }

    # 检查当前 BBR 状态
    check_bbr() {
        algo=$(sysctl -n net.ipv4.tcp_congestion_control)
        if [ "$algo" = "bbr" ]; then
            echo "✅ 当前已启用 BBR"
            show_params
            return 0
        else
            echo "❌ 当前拥塞控制算法为: $algo"
            show_params
            return 1
        fi
    }

    # 启用 BBR
    enable_bbr() {
        echo ">>> 检查内核是否支持 BBR..."
        if ! sysctl -n net.ipv4.tcp_available_congestion_control | grep -q "bbr"; then
            echo "❌ 当前内核未内置 BBR 或模块未加载。"
            echo "尝试加载 tcp_bbr 模块..."
            sudo modprobe tcp_bbr 2>/dev/null
            if ! sysctl -n net.ipv4.tcp_available_congestion_control | grep -q "bbr"; then
                 echo "❌ 无法加载 tcp_bbr 模块，请检查内核版本或是否支持。"
                 return 1
            fi
            echo "✅ tcp_bbr 模块加载成功。"
        fi
        
        if ! grep -q "tcp_bbr" /etc/modules-load.d/bbr.conf 2>/dev/null; then
            echo ">>> 设置 tcp_bbr 模块开机自动加载..."
            mkdir -p /etc/modules-load.d
            echo "tcp_bbr" | sudo tee /etc/modules-load.d/bbr.conf >/dev/null
        fi

        echo ">>> 写入 sysctl 配置 /etc/sysctl.d/99-bbr.conf ..."
        sudo tee /etc/sysctl.d/99-bbr.conf >/dev/null <<EOF
# BBR Congestion Control Optimized
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
# 通用网络优化参数
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_max_syn_backlog = 65536
EOF
        echo ">>> 应用 sysctl 配置..."
        sudo sysctl --system

        echo ">>> 再次检测当前拥塞控制算法..."
        algo=$(sysctl -n net.ipv4.tcp_congestion_control)
        if [ "$algo" = "bbr" ]; then
            echo "✅ 已成功启用 BBR"
            show_params
        else
            echo "❌ 当前仍为 $algo，未启用 BBR"
            echo "--- 故障排查提示 ---"
            echo "1. 检查是否有其他 sysctl 配置文件覆盖 (如 99-sysctl.conf)。"
            echo "2. 检查引导加载程序配置 (如 Grub 或 armbianEnv.txt) 是否有冲突参数。"
        fi
    }

    check_bbr || {
        # [修复] 增加 < /dev/tty
        # [新增] 提示文字增加 0返回
        read -p "是否要启用 BBR？(y/n, 输入 0 返回): " choice < /dev/tty
        
        # [新增] 处理返回逻辑
        if [[ "$choice" == "0" ]]; then
            return 0
        fi

        if [ "$choice" = "y" ] || [ "$choice" = "Y" ]; then
            enable_bbr
        else
            echo "⚠️ 已取消启用 BBR"
        fi
    }
}