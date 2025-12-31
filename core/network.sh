#!/bin/bash
function module_netmgr() {
    # 检查 nmcli 工具
    if ! command -v nmcli &> /dev/null; then echo -e "${RED}未检测到 nmcli，无法管理网络。${NC}"; return 1; fi
    
    # 自动探测默认网卡
    DETECTED_IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
    [ -z "$DETECTED_IFACE" ] && DETECTED_IFACE=$(ls /sys/class/net | grep -v lo | head -n1)
    
    echo -e "${BLUE}>>> 目标网卡确认${NC}"
    echo "系统检测到的默认网卡: ${GREEN}${DETECTED_IFACE}${NC}"
    echo -e "可用网卡列表: $(ls /sys/class/net | grep -v lo | tr '\n' ' ')"
    
    read -p "请确认操作网卡 (回车使用 ${DETECTED_IFACE}, 输入 0 返回): " USER_IFACE < /dev/tty
    
    if [[ "$USER_IFACE" == "0" ]]; then return 0; fi

    DEFAULT_IFACE=${USER_IFACE:-$DETECTED_IFACE}
    
    # 获取连接名称 (兼容有空格的情况)
    CON_NAME=$(nmcli -t -f NAME,DEVICE connection show --active | grep ":${DEFAULT_IFACE}" | cut -d: -f1 | head -n1)
    if [ -z "$CON_NAME" ]; then CON_NAME=$(nmcli -t -f NAME,DEVICE connection show | grep ":${DEFAULT_IFACE}" | cut -d: -f1 | head -n1); fi
    
    if [ -z "$CON_NAME" ]; then echo -e "${RED}未找到网卡 ${DEFAULT_IFACE} 的连接配置。${NC}"; return 1; fi

    # 定位配置文件 (用于回滚备份)
    CON_FILE=$(grep -l "id=$CON_NAME" /etc/NetworkManager/system-connections/*.nmconnection 2>/dev/null | head -n 1)

    # 辅助函数：校验 IP 格式 (0-255)
    validate_ip() {
        local ip=$1
        local stat=1
        if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            OIFS=$IFS; IFS='.'
            ip_arr=($ip)
            IFS=$OIFS
            [[ ${ip_arr[0]} -le 255 && ${ip_arr[1]} -le 255 && ${ip_arr[2]} -le 255 && ${ip_arr[3]} -le 255 ]]
            stat=$?
        fi
        return $stat
    }

    show_status() {
        echo -e "${BLUE}=== 当前网络状态 ($DEFAULT_IFACE) ===${NC}"
        local ip_addr=$(ip -4 addr show "$DEFAULT_IFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+')
        local gateway=$(ip route | grep default | awk '{print $3}')
        local dns=$(nmcli dev show "$DEFAULT_IFACE" | grep IP4.DNS | awk '{print $2}' | tr '\n' ' ')
        local method=$(nmcli -f ipv4.method connection show "$CON_NAME" | awk '{print $2}')
        echo -e "连接: ${GREEN}$CON_NAME${NC} | 模式: ${GREEN}$method${NC}"
        echo -e "IP: ${GREEN}${ip_addr:-未连接}${NC} | 网关: ${GREEN}${gateway:-未知}${NC} | DNS: ${GREEN}${dns:-未知}${NC}"
    }

    apply_changes_safe() {
        echo -e "\n${YELLOW}⚠️  准备应用更改...${NC}"
        
        # 备份逻辑
        if [ -n "$CON_FILE" ] && [ -f "$CON_FILE" ]; then
            cp "$CON_FILE" /tmp/nm_backup.nmconnection
        else
            echo -e "${RED}无法定位配置文件，跳过安全模式，直接应用。${NC}"
            nmcli connection up "$CON_NAME"
            return
        fi

        # 生成回滚脚本 (增加锁检查)
        cat > /tmp/revert_net.sh <<EOF
#!/bin/bash
# 只有当锁文件不存在时，才执行回滚
if [ ! -f /tmp/net_confirmed.lock ]; then
    cp /tmp/nm_backup.nmconnection "$CON_FILE"
    chmod 600 "$CON_FILE"
    nmcli connection reload
    nmcli connection up "$CON_NAME"
fi
EOF
        chmod +x /tmp/revert_net.sh
        rm -f /tmp/net_confirmed.lock # 清除旧锁

        echo -e "${YELLOW}>>> 启动 60秒 安全倒计时...${NC}"
        # 后台运行倒计时，不再依赖 PID，而是依赖文件锁
        (sleep 60; if [ -f /tmp/revert_net.sh ]; then bash /tmp/revert_net.sh >/dev/null 2>&1; rm -f /tmp/revert_net.sh; fi) &

        if nmcli connection up "$CON_NAME"; then
            echo -e "${GREEN}✅ 网络已重启。${NC}"
            echo -e "${RED}!!! 关键步骤 !!!${NC}"
            echo -e "如果你能看到这句话，说明网络正常。"
            
            read -p "请在 60秒 内输入 'y' 确认保留配置，否则将自动回滚: " CONFIRM < /dev/tty
            
            if [ "$CONFIRM" == "y" ] || [ "$CONFIRM" == "Y" ]; then
                # 用户确认：创建锁文件，阻止回滚
                touch /tmp/net_confirmed.lock
                rm -f /tmp/revert_net.sh
                echo -e "${GREEN}配置已保存。${NC}"
            else
                echo -e "${YELLOW}用户未确认，手动触发回滚...${NC}"
                bash /tmp/revert_net.sh
            fi
        else
            echo -e "${RED}应用失败，立即回滚...${NC}"
            bash /tmp/revert_net.sh
        fi
        
        # 清理临时文件
        rm -f /tmp/nm_backup.nmconnection /tmp/revert_net.sh /tmp/net_confirmed.lock
        read -p "按回车继续..." < /dev/tty
    }

    set_dhcp() {
        # 使用数组传参，更安全
        local args=(connection modify "$CON_NAME" ipv4.method auto ipv4.ignore-auto-dns no ipv4.gateway "" ipv4.addresses "" ipv4.dns "")
        nmcli "${args[@]}"
        apply_changes_safe
    }

    set_static() {
        current_ip=$(ip -4 addr show "$DEFAULT_IFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)
        
        read -p "IP ($current_ip): " input_ip < /dev/tty; input_ip=${input_ip:-$current_ip}
        read -p "Mask (24): " input_mask < /dev/tty; input_mask=${input_mask:-24}
        read -p "Gateway: " input_gw < /dev/tty
        read -p "DNS1 (223.5.5.5): " input_dns1 < /dev/tty; input_dns1=${input_dns1:-223.5.5.5}
        
        # 增强的 IP 校验
        if ! validate_ip "$input_ip"; then echo -e "${RED}IP 格式错误或数值超出范围 (0-255)。${NC}"; return; fi
        
        # 构建命令数组
        local args=(connection modify "$CON_NAME" ipv4.method manual ipv4.addresses "$input_ip/$input_mask" ipv4.dns "$input_dns1" ipv4.ignore-auto-dns yes)
        
        # 智能处理网关：只有输入了才设置
        if [ -n "$input_gw" ]; then
            if ! validate_ip "$input_gw"; then echo -e "${RED}网关 IP 格式错误。${NC}"; return; fi
            args+=(ipv4.gateway "$input_gw")
        fi
        
        nmcli "${args[@]}"
        apply_changes_safe
    }

    while true; do
        show_status
        echo -e "\n1) 设为 DHCP (自动获取)"
        echo "2) 设为 Static IP (静态地址) [带防失联保护]"
        echo "3) Ping 测试"
        echo "0) 返回主菜单"
        
        read -p "选择: " choice < /dev/tty
        case $choice in
            1) set_dhcp ;;
            2) set_static ;;
            3) ping -c 4 223.5.5.5; read -p "按回车..." < /dev/tty ;;
            0) break ;;
        esac
    done
}