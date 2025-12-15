#!/bin/bash
function module_led_fix() {
    echo -e "${BLUE}=== 网络 LED 指示灯配置工具 ===${NC}"
    echo -e "功能：将物理 LED 灯与网卡状态(Rx/Tx)绑定。"
    echo -e "${YELLOW}注意：此功能依赖 /sys/class/leds 接口，主要用于 SBC (如 NanoPi, 树莓派)。${NC}"
    echo -e "${YELLOW}通用 x86 PC 或虚拟机通常不支持此功能，请谨慎操作。${NC}"

    local MODEL="Unknown"
    if [ -f "/proc/device-tree/model" ]; then
        MODEL=$(tr -d '\0' < /proc/device-tree/model)
    elif [ -f "/sys/devices/virtual/dmi/id/product_name" ]; then
        MODEL=$(cat /sys/devices/virtual/dmi/id/product_name)
    fi
    echo -e "当前硬件识别: ${GREEN}$MODEL${NC}"

    if [ ! -d "/sys/class/leds" ] || [ -z "$(ls /sys/class/leds)" ]; then
        echo -e "${RED}❌ 系统未检测到可控 LED 设备 (/sys/class/leds 为空)。${NC}"
        echo "本模块不适用于当前硬件。"
        return 1
    fi

    echo -e "\n当前可用 LED 设备："
    ls /sys/class/leds | xargs echo
    echo "----------------------------------------"
    
    # [修复] 增加 < /dev/tty
    # [新增] 0返回提示
    read -p "是否继续配置？(y/n, 输入 0 返回) [n]: " START_OPT < /dev/tty
    
    # [新增] 处理返回
    if [[ "$START_OPT" == "0" ]]; then return; fi
    if [[ "$START_OPT" != "y" ]]; then return; fi

    echo -e "\n${BLUE}>>> 步骤 1: 选择 LAN (内网) 接口绑定${NC}"
    echo "可用网卡: $(ls /sys/class/net | grep -v lo | xargs echo)"
    
    # [修复] 增加 < /dev/tty
    read -p "输入 LAN 网卡名称 (默认 eth0, 跳过输入 n): " IFACE_LAN < /dev/tty
    if [[ "$IFACE_LAN" != "n" ]]; then
        IFACE_LAN=${IFACE_LAN:-eth0}
        # [修复] 增加 < /dev/tty
        read -p "输入对应 LED 名称 (例如 green:lan): " LED_LAN < /dev/tty
    else
        LED_LAN=""
    fi

    echo -e "\n${BLUE}>>> 步骤 2: 选择 WAN (外网) 接口绑定${NC}"
    # [修复] 增加 < /dev/tty
    read -p "输入 WAN 网卡名称 (默认 eth1, 跳过输入 n): " IFACE_WAN < /dev/tty
    if [[ "$IFACE_WAN" != "n" ]]; then
        IFACE_WAN=${IFACE_WAN:-eth1}
        # [修复] 增加 < /dev/tty
        read -p "输入对应 LED 名称 (例如 green:wan): " LED_WAN < /dev/tty
    else
        LED_WAN=""
    fi

    if [ -z "$LED_LAN" ] && [ -z "$LED_WAN" ]; then echo "未配置任何 LED。"; return; fi

    SCRIPT_PATH="/usr/local/bin/net-led-setup.sh"
    SERVICE_PATH="/etc/systemd/system/net-led.service"

    echo -e "${YELLOW}>>> 正在生成配置脚本...${NC}"

    if ! command -v ethtool >/dev/null 2>&1; then
        echo "安装 ethtool..."
        apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq ethtool >/dev/null 2>&1
    fi

    cat > "$SCRIPT_PATH" <<EOF
#!/bin/bash
# Network LED Configuration Script
modprobe ledtrig-netdev

configure_single_led() { 
    local LED_NAME=\$1
    local IFACE_NAME=\$2
    local LED_PATH="/sys/class/leds/\${LED_NAME}"
    
    if [ ! -d "/sys/class/net/\${IFACE_NAME}" ] || [ ! -d "\${LED_PATH}" ]; then 
        echo "Interface \${IFACE_NAME} or LED \${LED_NAME} not found, skipping."
        return 1
    fi
    
    # 尝试关闭 EEE 节能模式以防断流 (仅物理网卡有效)
    ethtool --set-eee "\${IFACE_NAME}" ee off >/dev/null 2>&1
    
    echo none > "\${LED_PATH}/trigger"
    echo 0 > "\${LED_PATH}/brightness"
    echo netdev > "\${LED_PATH}/trigger"
    
    for i in {1..5}; do
        echo "\${IFACE_NAME}" > "\${LED_PATH}/device_name" 2>/dev/null
        if [ "\$(cat "\${LED_PATH}/device_name" 2>/dev/null)" == "\$IFACE_NAME" ]; then break; fi
        sleep 0.5
    done
    
    echo 1 > "\${LED_PATH}/link"
    echo 1 > "\${LED_PATH}/rx"
    echo 1 > "\${LED_PATH}/tx"
}
EOF

    if [ -n "$LED_LAN" ]; then echo "configure_single_led \"$LED_LAN\" \"$IFACE_LAN\"" >> "$SCRIPT_PATH"; fi
    if [ -n "$LED_WAN" ]; then echo "configure_single_led \"$LED_WAN\" \"$IFACE_WAN\"" >> "$SCRIPT_PATH"; fi

    chmod +x "$SCRIPT_PATH"

    cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=Setup Network LEDs linked to Interfaces
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$SCRIPT_PATH
RemainAfterExit=yes
StandardOutput=journal

[Install]
WantedBy=multi-user.target
EOF

    echo ">>> 注册并启动系统服务..."
    systemctl daemon-reload
    systemctl enable net-led.service
    systemctl restart net-led.service

    if systemctl is-active --quiet net-led.service; then
        echo -e "${GREEN}✅ LED 服务已配置并启动！${NC}"
    else
        echo -e "${RED}❌ 服务启动失败，请检查配置名称是否正确。${NC}"
    fi
}