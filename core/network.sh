#!/bin/bash
function module_netmgr() {
    # === 内部函数：安装 NetworkManager ===
    install_nm() {
        echo -e "${YELLOW}>>> 正在安装 NetworkManager...${NC}"
        
        if [ "$EUID" -ne 0 ]; then
             echo -e "${RED}错误：请使用 root (sudo) 权限运行。${NC}"
             read -p "按回车键返回..." < /dev/tty
             return 1
        fi

        apt-get update
        if apt-get install -y network-manager; then
            echo -e "${GREEN}软件安装成功。${NC}"
            
            if [ -f /etc/NetworkManager/NetworkManager.conf ]; then
                echo ">>> 正在配置 NetworkManager 接管网卡..."
                sed -i 's/managed=false/managed=true/g' /etc/NetworkManager/NetworkManager.conf
            fi
            
            echo ">>> 正在启动服务..."
            systemctl enable NetworkManager
            systemctl start NetworkManager
            
            echo -e "${GREEN}✅ NetworkManager 准备就绪！正在重试检测...${NC}"
            sleep 2
            return 0
        else
            echo -e "${RED}❌ 安装失败。请检查网络连接或源配置。${NC}"
            read -p "按回车键返回..." < /dev/tty
            return 1
        fi
    }

    # === 主逻辑循环 ===
    while true; do
        # 1. 检查 nmcli 工具是否存在
        if ! command -v nmcli &> /dev/null; then
            echo -e "${RED}❌ 错误：未检测到 'nmcli' 工具。${NC}"
            echo -e "${YELLOW}提示：这是 Armbian Minimal/Server 版本的常见情况。${NC}"
            echo "------------------------------------------------"
            echo "1) 安装 NetworkManager (修复 nmcli 缺失)"
            echo "0) 返回主菜单"
            echo "------------------------------------------------"
            
            read -p "请选择: " missing_opt < /dev/tty
            case $missing_opt in
                1) 
                    install_nm
                    continue 
                    ;;
                0) return 1 ;;
                *) echo "无效输入。"; continue ;;
            esac
        fi

        # 2. nmcli 存在，执行正常逻辑
        
        # 自动探测默认网卡
        DETECTED_IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
        [ -z "$DETECTED_IFACE" ] && DETECTED_IFACE=$(ls /sys/class/net | grep -v lo | head -n1)
        
        if [ -z "$DETECTED_IFACE" ]; then
             echo -e "${RED}错误：未找到任何物理网卡。${NC}"
             read -p "按回车键返回..." < /dev/tty
             return 1
        fi

        echo -e "${BLUE}>>> 目标网卡确认${NC}"
        echo "系统检测到的默认网卡: ${GREEN}${DETECTED_IFACE}${NC}"
        echo -e "可用网卡列表: $(ls /sys/class/net | grep -v lo | tr '\n' ' ')"
        
        read -p "请确认操作网卡 (回车使用 ${DETECTED_IFACE}, 输入 0 返回): " USER_IFACE < /dev/tty
        
        if [[ "$USER_IFACE" == "0" ]]; then return 0; fi

        DEFAULT_IFACE=${USER_IFACE:-$DETECTED_IFACE}
        
        # 获取连接名称
        CON_NAME=$(nmcli -t -f NAME,DEVICE connection show --active | grep ":${DEFAULT_IFACE}" | cut -d: -f1 | head -n1)
        if [ -z "$CON_NAME" ]; then CON_NAME=$(nmcli -t -f NAME,DEVICE connection show | grep ":${DEFAULT_IFACE}" | cut -d: -f1 | head -n1); fi
        
        # [核心修复] 如果找不到连接配置，自动创建
        if [ -z "$CON_NAME" ]; then 
            echo -e "${YELLOW}>>> 未找到网卡 ${DEFAULT_IFACE} 的连接配置，正在自动创建...${NC}"
            
            # 尝试创建标准以太网连接
            if nmcli con add type ethernet con-name "${DEFAULT_IFACE}" ifname "${DEFAULT_IFACE}"; then
                echo -e "${GREEN}✅ 已成功创建连接配置: ${DEFAULT_IFACE}${NC}"
                # 尝试激活
                nmcli connection up "${DEFAULT_IFACE}" >/dev/null 2>&1
                # 赋值连接名，继续后续流程
                CON_NAME="${DEFAULT_IFACE}"
                sleep 1
            else
                echo -e "${RED}❌ 自动创建失败。${NC}"
                echo -e "${YELLOW}请尝试手动运行: nmcli con add type ethernet con-name \"${DEFAULT_IFACE}\" ifname \"${DEFAULT_IFACE}\"${NC}"
                read -p "按回车键返回..." < /dev/tty
                return 1
            fi
        fi

        # 定位配置文件
        CON_FILE=$(grep -l "id=$CON_NAME" /etc/NetworkManager/system-connections/*.nmconnection 2>/dev/null | head -n 1)

        # --- 子函数 ---

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
            echo -e "连接名称: ${GREEN}$CON_NAME${NC} | 模式: ${GREEN}$method${NC}"
            echo -e "IP地址: ${GREEN}${ip_addr:-未连接}${NC} | 网关: ${GREEN}${gateway:-未知}${NC} | DNS: ${GREEN}${dns:-未知}${NC}"
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
if [ ! -f /tmp/net_confirmed.lock ]; then
    cp /tmp/nm_backup.nmconnection "$CON_FILE"
    chmod 600 "$CON_FILE"
    nmcli connection reload
    nmcli connection up "$CON_NAME"
fi
EOF
            chmod +x /tmp/revert_net.sh
            rm -f /tmp/net_confirmed.lock

            echo -e "${YELLOW}>>> 启动 60秒 安全倒计时...${NC}"
            (sleep 60; if [ -f /tmp/revert_net.sh ]; then bash /tmp/revert_net.sh >/dev/null 2>&1; rm -f /tmp/revert_net.sh; fi) &

            if nmcli connection up "$CON_NAME"; then
                echo -e "${GREEN}✅ 网络已重启。${NC}"
                echo -e "${RED}!!! 关键步骤 !!!${NC}"
                echo -e "如果你能看到这句话，说明网络连接正常。"
                
                read -p "请在 60秒 内输入 'y' 确认保留配置，否则将自动回滚: " CONFIRM < /dev/tty
                
                if [ "$CONFIRM" == "y" ] || [ "$CONFIRM" == "Y" ]; then
                    touch /tmp/net_confirmed.lock
                    rm -f /tmp/revert_net.sh
                    echo -e "${GREEN}配置已永久保存。${NC}"
                else
                    echo -e "${YELLOW}用户未确认，正在回滚...${NC}"
                    bash /tmp/revert_net.sh
                fi
            else
                echo -e "${RED}应用失败，立即自动回滚...${NC}"
                bash /tmp/revert_net.sh
            fi
            
            rm -f /tmp/nm_backup.nmconnection /tmp/revert_net.sh /tmp/net_confirmed.lock
            read -p "按回车键继续..." < /dev/tty
        }

        set_dhcp() {
            local args=(connection modify "$CON_NAME" ipv4.method auto ipv4.ignore-auto-dns no ipv4.gateway "" ipv4.addresses "" ipv4.dns "")
            nmcli "${args[@]}"
            apply_changes_safe
        }

        set_static() {
            current_ip=$(ip -4 addr show "$DEFAULT_IFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)
            
            read -p "IP地址 ($current_ip): " input_ip < /dev/tty; input_ip=${input_ip:-$current_ip}
            read -p "子网掩码 (24): " input_mask < /dev/tty; input_mask=${input_mask:-24}
            read -p "网关地址: " input_gw < /dev/tty
            read -p "DNS服务器 (223.5.5.5): " input_dns1 < /dev/tty; input_dns1=${input_dns1:-223.5.5.5}
            
            if ! validate_ip "$input_ip"; then echo -e "${RED}IP 格式错误或数值超出范围。${NC}"; return; fi
            
            local args=(connection modify "$CON_NAME" ipv4.method manual ipv4.addresses "$input_ip/$input_mask" ipv4.dns "$input_dns1" ipv4.ignore-auto-dns yes)
            
            if [ -n "$input_gw" ]; then
                if ! validate_ip "$input_gw"; then echo -e "${RED}网关格式错误。${NC}"; return; fi
                args+=(ipv4.gateway "$input_gw")
            fi
            
            nmcli "${args[@]}"
            apply_changes_safe
        }

        # === 菜单 ===
        while true; do
            show_status
            echo -e "\n1) 设为 DHCP (自动获取)"
            echo "2) 设为 Static IP (静态地址) [带防失联保护]"
            echo "3) Ping 测试 (223.5.5.5)"
            echo "0) 返回主菜单"
            
            read -p "请选择: " choice < /dev/tty
            case $choice in
                1) set_dhcp ;;
                2) set_static ;;
                3) ping -c 4 223.5.5.5; read -p "按回车键继续..." < /dev/tty ;;
                0) return 0 ;;
                *) echo "无效选项。" ;;
            esac
        done
    done
}