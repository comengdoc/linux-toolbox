#!/bin/bash

# =========================================================
# Linux 本机与 Docker 临时代理工具 (Proxy Tool)
# =========================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 默认配置文件路径
DOCKER_DIR="/etc/systemd/system/docker.service.d"
DOCKER_CONF="$DOCKER_DIR/http-proxy.conf"

# 检查是否以 root 运行
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}请使用 sudo 或 root 权限运行此脚本${NC}" 
   exit 1
fi

# ==================== 核心功能函数 ====================

# 1. 交互式获取代理地址
get_proxy_info() {
    echo -e "${BLUE}>>> 请输入代理服务器信息${NC}"
    
    DEFAULT_IP="127.0.0.1"
    read -p "请输入代理 IP [默认: $DEFAULT_IP]: " PROXY_IP
    PROXY_IP=${PROXY_IP:-$DEFAULT_IP}

    DEFAULT_PORT="7890"
    read -p "请输入混合/HTTP端口 [默认: $DEFAULT_PORT]: " PROXY_PORT
    PROXY_PORT=${PROXY_PORT:-$DEFAULT_PORT}

    PROXY_URL="http://$PROXY_IP:$PROXY_PORT"
    SOCKS_URL="socks5://$PROXY_IP:$PROXY_PORT"
}

# 2. 设置 Docker 代理 (不变)
set_docker_proxy() {
    get_proxy_info
    echo -e "${BLUE}>>> 正在配置 Docker 守护进程代理...${NC}"
    mkdir -p "$DOCKER_DIR"
    cat > "$DOCKER_CONF" <<EOF
[Service]
Environment="HTTP_PROXY=$PROXY_URL"
Environment="HTTPS_PROXY=$PROXY_URL"
Environment="NO_PROXY=localhost,127.0.0.1,192.168.0.0/16,10.0.0.0/8,172.16.0.0/12,::1"
EOF
    echo -e "${YELLOW}正在重载 Docker 服务...${NC}"
    systemctl daemon-reload
    systemctl restart docker
    echo -e "${GREEN}✅ Docker 代理已开启！${NC}"
    read -p "按回车键返回菜单..."
}

# 3. 清除 Docker 代理 (不变)
unset_docker_proxy() {
    echo -e "${BLUE}>>> 正在清除 Docker 代理...${NC}"
    if [ -f "$DOCKER_CONF" ]; then
        rm -f "$DOCKER_CONF"
        systemctl daemon-reload
        systemctl restart docker
        echo -e "${GREEN}✅ Docker 代理已移除。${NC}"
    else
        echo -e "${YELLOW}Docker 代理配置不存在。${NC}"
    fi
    read -p "按回车键返回菜单..."
}

# 4. 【核心修改】进入代理终端模式
enter_proxy_shell() {
    get_proxy_info
    
    echo -e "\n${GREEN}>>> 正在启动【代理模式】临时终端...${NC}"
    echo -e "${YELLOW}提示: 在此模式下输入的所有命令(curl/docker run等)均自动走代理。${NC}"
    echo -e "${YELLOW}操作: 输入 'exit' 或按 Ctrl+D 即可退出代理模式，返回菜单。${NC}"
    echo -e "-----------------------------------------------------"
    
    # 导出变量到即将启动的子 Shell
    export http_proxy="$PROXY_URL"
    export https_proxy="$PROXY_URL"
    export all_proxy="$SOCKS_URL"
    export no_proxy="localhost,127.0.0.1,192.168.0.0/16,10.0.0.0/8,172.16.0.0/12"
    
    # 启动一个新的 bash，并修改提示符让用户知道状态
    # --rcfile /dev/null 防止加载用户配置覆盖变量，或者直接用 bash 继承当前环境
    PS1="[\u@\h \W (ProxyMode)]\$ " bash --norc
    
    echo -e "\n${BLUE}>>> 已退出代理模式，环境恢复直连。${NC}"
    read -p "按回车键返回菜单..."
}

# 5. 【核心修改】打印 unset 命令并退出脚本
show_unset_command() {
    echo -e "\n${GREEN}=== 清理指南 ===${NC}"
    echo -e "由于脚本即将退出，请手动复制执行以下命令以清理环境："
    echo -e "\n${YELLOW}unset http_proxy https_proxy all_proxy no_proxy${NC}\n"
    exit 0
}

# ==================== 主菜单 ====================
show_menu() {
    while true; do
        clear
        echo -e "${BLUE}=======================================${NC}"
        echo -e "   本机与 Docker 临时代理管理工具"
        echo -e "${BLUE}=======================================${NC}"
        echo "1. 开启 Docker 代理 (用于 pull/update 镜像)"
        echo "2. 关闭 Docker 代理 (恢复直连)"
        echo "---------------------------------------"
        echo "3. 进入 代理模式终端 (直接在这里输入命令!)"
        echo "4. 退出并显示清理命令"
        echo "---------------------------------------"
        echo "0. 返回上级菜单/退出"
        echo -e "${BLUE}=======================================${NC}"
        
        read -p "请选择: " OPT
        case $OPT in
            1) set_docker_proxy ;;
            2) unset_docker_proxy ;;
            3) enter_proxy_shell ;;
            4) show_unset_command ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选项${NC}"; sleep 1 ;;
        esac
    done
}

show_menu