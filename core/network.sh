#!/bin/bash
function module_netmgr() {
    if ! command -v nmcli &> /dev/null; then echo -e "${RED}未检测到 nmcli，无法管理网络。${NC}"; return 1; fi
    
    # 自动尝试检测主网卡
    DETECTED_IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
    # 如果没联网，尝试找第一个非 lo 的网卡
    [ -z "$DETECTED_IFACE" ] && DETECTED_IFACE=$(ls /sys/class/net | grep -v lo | head -n1)
    
    echo -e "${BLUE}>>> 目标网卡确认${NC}"
    echo "系统检测到的默认网卡: ${GREEN}${DETECTED_IFACE}${NC}"
    echo -e "可用网卡列表: $(ls /sys/class/net | grep -v lo | tr '\n' ' ')"
    read -p "请确认操作网卡 (直接回车使用 ${DETECTED_IFACE}): " USER_IFACE
    
    DEFAULT_IFACE=${USER_IFACE:-$DETECTED_IFACE}
    
    CON_NAME=$(nmcli -t -f NAME,DEVICE connection show --active | grep ":${DEFAULT_IFACE}" | cut -d: -f1 | head -n1)
    if [ -z "$CON_NAME" ]; then CON_NAME=$(nmcli -t -f NAME,DEVICE connection show | grep ":${DEFAULT_IFACE}" | cut -d: -f1 | head -n1); fi
    
    if [ -z "$CON_NAME" ]; then echo -e "${RED}未找到网卡 ${DEFAULT_IFACE} 的连接配置。${NC}"; return 1; fi

    CON_FILE=$(grep -l "id=$CON_NAME" /etc/NetworkManager/system-connections/*.nmconnection 2>/dev/null | head -n 1)

    show_status() {
        echo -e "${BLUE}=== 当前网络状态 ($DEFAULT_IFACE) ===${NC}"
        local ip_addr=$(ip -4 addr show $DEFAULT_IFACE | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+')
        local gateway=$(ip route | grep default | awk '{print $3}')
        local dns=$(nmcli dev show $DEFAULT_IFACE | grep IP4.DNS | awk '{print $2}' | tr '\n' ' ')
        local method=$(nmcli -f ipv4.method connection show "$CON_NAME" | awk '{print $2}')
        echo -e "连接: ${GREEN}$CON_NAME${NC} | 模式: ${GREEN}$method${NC}"
        echo -e "IP: ${GREEN}${ip_addr:-未连接}${NC} | 网关: ${GREEN}${gateway:-未知}${NC} | DNS: ${GREEN}${dns:-未知}${NC}"
    }

    apply_changes_safe() {
        echo -e "\n${YELLOW}⚠️  准备应用更改...${NC}"
        
        if [ -n "$CON_FILE" ] && [ -f "$CON_FILE" ]; then
            cp "$CON_FILE" /tmp/nm_backup.nmconnection
        else
            echo -e "${RED}无法定位配置文件，跳过安全模式，直接应用。${NC}"
            nmcli connection up "$CON_NAME"
            return
        fi

        cat > /tmp/revert_net.sh <<EOF
#!/bin/bash
# Network Revert Script
cp /tmp/nm_backup.nmconnection "$CON_FILE"
chmod 600 "$CON_FILE"
nmcli connection reload
nmcli connection up "$CON_NAME"
EOF
        chmod +x /tmp/revert_net.sh

        echo -e "${YELLOW}>>> 启动 60秒 安全倒计时...${NC}"
        (sleep 60; if [ -f /tmp/revert_net.sh ]; then bash /tmp/revert_net.sh; rm -f /tmp/revert_net.sh; fi) &
        WATCHDOG_PID=$!

        if nmcli connection up "$CON_NAME"; then
            echo -e "${GREEN}✅ 网络已重启。${NC}"
            echo -e "${RED}!!! 关键步骤 !!!${NC}"
            echo -e "如果你能看到这句话，说明网络正常。"
            read -p "请在 60秒 内输入 'y' 确认保留配置，否则将自动回滚: " CONFIRM
            
            if [ "$CONFIRM" == "y" ] || [ "$CONFIRM" == "Y" ]; then
                kill $WATCHDOG_PID 2>/dev/null
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
        wait $WATCHDOG_PID 2>/dev/null
        rm -f /tmp/nm_backup.nmconnection /tmp/revert_net.sh
        read -p "按回车继续..."
    }

    set_dhcp() {
        nmcli connection modify "$CON_NAME" ipv4.method auto ipv4.ignore-auto-dns no ipv4.gateway "" ipv4.addresses "" ipv4.dns ""
        apply_changes_safe
    }

    set_static() {
        current_ip=$(ip -4 addr show $DEFAULT_IFACE | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)
        read -p "IP ($current_ip): " input_ip; input_ip=${input_ip:-$current_ip}
        read -p "Mask (24): " input_mask; input_mask=${input_mask:-24}
        read -p "Gateway: " input_gw
        read -p "DNS1 (223.5.5.5): " input_dns1; input_dns1=${input_dns1:-223.5.5.5}
        
        if [[ ! $input_ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then echo "IP格式错误"; return; fi
        
        nmcli connection modify "$CON_NAME" ipv4.method manual ipv4.addresses "$input_ip/$input_mask" ipv4.gateway "$input_gw" ipv4.dns "$input_dns1" ipv4.ignore-auto-dns yes
        apply_changes_safe
    }

    while true; do
        show_status
        echo -e "\n1) 设为 DHCP (自动获取)"
        echo "2) 设为 Static IP (静态地址) [带防失联保护]"
        echo "3) Ping 测试"
        echo "4) 返回主菜单"
        read -p "选择: " choice
        case $choice in
            1) set_dhcp ;;
            2) set_static ;;
            3) ping -c 4 223.5.5.5; read -p "按回车..." ;;
            4) break ;;
        esac
    done
}
