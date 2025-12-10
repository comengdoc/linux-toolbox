#!/bin/bash
# ==================================================
# 基础工具模块 (由自动脚本生成)
# ==================================================

# 全局颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 全局变量
GH_PROXY=""

# 检查 Root 权限
function check_root() {
    if [ "$(id -u)" != "0" ]; then
       echo -e "${RED}错误: 必须使用 root 权限运行此脚本。${NC}"
       exit 1
    fi
}

# 代理配置函数
function configure_proxy() {
    #在此处修改默认的硬编码代理
    local DEFAULT_PROXY="https://ghproxy.net/"
    
    clear
    echo -e "${BLUE}====================================================${NC}"
    echo -e "       🌐 GitHub 加速代理配置 (Proxy Setup)"
    echo -e "${BLUE}====================================================${NC}"
    echo -e "当前默认代理: ${GREEN}${DEFAULT_PROXY}${NC}"
    echo -e "作用范围: 脚本内所有涉及 GitHub 文件下载的模块 (Mihomo, yq 等)"
    echo -e "${YELLOW}提示: 代理地址通常以 https:// 开头${NC}"
    echo "----------------------------------------------------"
    
    read -p "请输入代理地址 (直接回车使用默认，输入 'n' 不使用代理): " USER_INPUT

    if [ -z "$USER_INPUT" ]; then
        GH_PROXY="$DEFAULT_PROXY"
        echo -e "${YELLOW}>>> 已采用默认代理: ${GH_PROXY}${NC}"
    elif [ "$USER_INPUT" == "n" ] || [ "$USER_INPUT" == "N" ]; then
        GH_PROXY=""
        echo -e "${RED}>>> 已禁用代理 (直连模式)${NC}"
    else
        # 自动处理结尾的斜杠，防止拼接错误
        if [[ "$USER_INPUT" != */ ]]; then
            GH_PROXY="${USER_INPUT}/"
        else
            GH_PROXY="$USER_INPUT"
        fi
        echo -e "${GREEN}>>> 已设置自定义代理: ${GH_PROXY}${NC}"
    fi
    echo "----------------------------------------------------"
    sleep 1
}
