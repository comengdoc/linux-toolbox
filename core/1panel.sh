#!/bin/bash
function module_1panel() {
    echo -e "${GREEN}>>> 准备安装 1Panel 服务器面板...${NC}"
    
    if ! command -v curl &> /dev/null; then
        echo -e "${YELLOW}未找到 curl，正在安装...${NC}"
        apt-get update -qq && apt-get install -y -qq curl
    fi

    echo -e "${YELLOW}正在拉取官方安装脚本...${NC}"
    bash -c "$(curl -sSL https://resource.fit2cloud.com/1panel/package/v2/quick_start.sh)"
}
