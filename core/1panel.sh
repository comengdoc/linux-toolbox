#!/bin/bash
function module_1panel() {
    echo -e "${GREEN}>>> 1Panel 服务器面板安装向导${NC}"
    echo "1) 开始安装"
    echo "0) 返回主菜单"
    
    # [新增] 增加选择确认，防止误触，并提供返回入口
    read -p "请选择操作: " choice < /dev/tty
    if [[ "$choice" == "0" ]]; then
        return 0
    fi

    if ! command -v curl &> /dev/null; then
        echo -e "${YELLOW}未找到 curl，正在安装...${NC}"
        apt-get update -qq && apt-get install -y -qq curl
    fi

    echo -e "${YELLOW}正在拉取官方安装脚本...${NC}"
    
    # 【核心修复】
    # 使用 < /dev/tty 强制将官方脚本的输入重定向回终端键盘
    # 否则在 curl | bash 模式下，官方脚本无法读取用户的安装设置
    bash <(curl -sSL https://resource.fit2cloud.com/1panel/package/v2/quick_start.sh) < /dev/tty
}