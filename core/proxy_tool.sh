#!/bin/bash

# =========================================================
# Linux 本机与 Docker 临时代理工具 (支持账号密码认证版)
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

# 1. 交互式获取代理地址 (新增账号密码支持)
get_proxy_info() {
    echo -e "${BLUE}>>> 请输入代理服务器信息${NC}"
    
    DEFAULT_IP="127.0.0.1"
    read -p "请输入代理 IP [默认: $DEFAULT_IP]: " PROXY_IP
    PROXY_IP=${PROXY_IP:-$DEFAULT_IP}

    DEFAULT_PORT="7890"
    read -p "请输入混合/HTTP端口 [默认: $DEFAULT_PORT]: " PROXY_PORT
    PROXY_PORT=${PROXY_PORT:-$DEFAULT_PORT}

    # --- 新增：账号密码部分 ---
    echo -e "${YELLOW}提示: 如果代理没有设置账号密码，请直接按回车跳过。${NC}"
    read -p "请输入代理用户名 (可选): " PROXY_USER
    
    AUTH_PREFIX=""
    if [[ -n "$PROXY_USER" ]]; then
        # -s 参数使输入的密码不显示在屏幕上
        read -s -p "请输入代理密码: " PROXY_PASS
        echo "" # 输入密码后换行
        # 拼接认证前缀 format: user:pass@
        AUTH_PREFIX="${PROXY_USER}:${PROXY_PASS}@"
        echo -e "${GREEN}已添加认证信息。${NC}"
    fi

    # 拼接最终 URL
    PROXY_URL="http://${AUTH_PREFIX}${PROXY_IP}:${PROXY_PORT}"
    SOCKS_URL="socks5://${AUTH_PREFIX}${PROXY_IP}:${PROXY_PORT}"
}

# 2. 智能切换 Docker 代理 (合并了原来的开启和关闭)
toggle_docker_proxy() {
    if [ -f "$DOCKER_CONF" ]; then
        # --- 如果已存在，则执行关闭逻辑 ---
        echo -e "\n${BLUE}>>> 检测到 Docker 代理已开启，正在执行【关闭】操作...${NC}"
        rm -f "$DOCKER_CONF"
        echo -e "${YELLOW}正在重载 Docker 服务...${NC}"
        systemctl daemon-reload
        systemctl restart docker
        echo -e "${GREEN}✅ Docker 代理已成功移除，恢复直连。${NC}"
    else
        # --- 如果不存在，则执行开启逻辑 ---
        echo -e "\n${BLUE}>>> 检测到 Docker 代理未配置，正在执行【开启】操作...${NC}"
        get_proxy_info # 获取 IP 端口及账号密码
        
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
        echo -e "${GREEN}✅ Docker 代理已开启！(仅限 pull/build 生效)${NC}"
        if [[ -n "$PROXY_USER" ]]; then
            echo -e "${YELLOW}(注: 配置文件中包含明文密码，请注意安全)${NC}"
        fi
    fi
    read -p "按回车键返回菜单..."
}

# 3. 进入代理终端模式
enter_proxy_shell() {
    get_proxy_info
    
    echo -e "\n${GREEN}>>> 正在启动【代理模式】临时终端...${NC}"
    echo -e "${YELLOW}提示: 在此模式下，curl / docker run 等命令自动走代理。${NC}"
    echo -e "${YELLOW}操作: 输入 'exit' 或按 Ctrl+D 即可退出模式并【自动关闭代理】。${NC}"
    echo -e "-----------------------------------------------------"
    
    export http_proxy="$PROXY_URL"
    export https_proxy="$PROXY_URL"
    export all_proxy="$SOCKS_URL"
    export no_proxy="localhost,127.0.0.1,192.168.0.0/16,10.0.0.0/8,172.16.0.0/12"
    
    PS1="[\u@\h \W (Proxy)]\$ " bash --norc
    
    echo -e "\n${BLUE}>>> 已退出代理模式，环境恢复直连。${NC}"
    read -p "按回车键返回菜单..."
}

# ==================== 主菜单 ====================
show_menu() {
    while true; do
        # 每次循环都检查 Docker 代理状态
        if [ -f "$DOCKER_CONF" ]; then
            DOCKER_STATUS="${GREEN}已开启 ✅${NC}"
            TOGGLE_ACTION="关闭"
        else
            DOCKER_STATUS="${RED}未开启 ❌${NC}"
            TOGGLE_ACTION="开启"
        fi

        clear
        echo -e "${BLUE}=======================================${NC}"
        echo -e "   本机与 Docker 临时代理管理工具"
        echo -e "${BLUE}=======================================${NC}"
        
        # 动态显示状态和动作
        echo -e "1. ${TOGGLE_ACTION} Docker 代理 [当前状态: ${DOCKER_STATUS}]"
        echo -e "   ${YELLOW}(用于解决 docker pull 镜像拉取失败问题)${NC}"
        echo "---------------------------------------"
        echo -e "2. 进入 代理终端 [临时 Shell]"
        echo -e "   ${YELLOW}(用于 curl / docker run 容器科学上网)${NC}"
        echo "---------------------------------------"
        echo "0. 返回上级菜单"
        echo -e "${BLUE}=======================================${NC}"
        
        read -p "请选择: " OPT
        case $OPT in
            1) toggle_docker_proxy ;;
            2) enter_proxy_shell ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选项${NC}"; sleep 1 ;;
        esac
    done
}

show_menu