#!/bin/bash

# =========================================================
# Linux 本机与 Docker 临时代理工具 (Proxy Tool)
# 功能:
# 1. 交互式设置代理 IP 和端口
# 2. 一键配置 Docker 守护进程代理 (用于 pull/build)
# 3. 生成 Shell 终端代理命令 (用于 curl/wget/host-mode容器)
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
TEMP_ENV_FILE="/tmp/proxy_env_cmd.sh"

# 检查是否以 root 运行
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}请使用 sudo 或 root 权限运行此脚本${NC}" 
   exit 1
fi

# ==================== 核心功能函数 ====================

# 1. 交互式获取代理地址
get_proxy_info() {
    echo -e "${BLUE}>>> 请输入代理服务器信息${NC}"
    
    # 尝试自动获取本机 IP 作为默认值 (假设代理就在本机)
    DEFAULT_IP="127.0.0.1"
    read -p "请输入代理 IP [默认: $DEFAULT_IP]: " PROXY_IP
    PROXY_IP=${PROXY_IP:-$DEFAULT_IP}

    DEFAULT_PORT="7890"
    read -p "请输入混合/HTTP端口 [默认: $DEFAULT_PORT]: " PROXY_PORT
    PROXY_PORT=${PROXY_PORT:-$DEFAULT_PORT}

    PROXY_URL="http://$PROXY_IP:$PROXY_PORT"
    SOCKS_URL="socks5://$PROXY_IP:$PROXY_PORT"
    
    echo -e "已设定目标代理: ${GREEN}$PROXY_URL${NC}"
}

# 2. 设置 Docker 代理
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
    
    echo -e "${YELLOW}正在重载 Docker 服务 (这不会停止运行中的容器，但会刷新守护进程配置)...${NC}"
    systemctl daemon-reload
    systemctl restart docker
    
    echo -e "${GREEN}✅ Docker 代理已开启！${NC}"
    echo -e "现在你可以尝试 'docker pull' 拉取被墙的镜像了。"
}

# 3. 清除 Docker 代理
unset_docker_proxy() {
    echo -e "${BLUE}>>> 正在清除 Docker 代理...${NC}"
    if [ -f "$DOCKER_CONF" ]; then
        rm -f "$DOCKER_CONF"
        systemctl daemon-reload
        systemctl restart docker
        echo -e "${GREEN}✅ Docker 代理已移除，恢复直连。${NC}"
    else
        echo -e "${YELLOW}Docker 代理配置不存在，无需清除。${NC}"
    fi
}

# 4. 生成本机 Shell 代理命令
set_shell_proxy() {
    get_proxy_info
    
    # 生成一个临时文件供用户 source
    cat > "$TEMP_ENV_FILE" <<EOF
export http_proxy="$PROXY_URL"
export https_proxy="$PROXY_URL"
export all_proxy="$SOCKS_URL"
export no_proxy="localhost,127.0.0.1,192.168.0.0/16,10.0.0.0/8,172.16.0.0/12"
echo -e "\033[0;32m✅ 当前终端代理已开启 ($PROXY_URL)\033[0m"
EOF
    
    echo -e "\n${GREEN}=== 操作指南 ===${NC}"
    echo -e "由于脚本无法直接修改你当前终端的环境变量，"
    echo -e "请复制并执行以下命令 (或者直接手动 source)："
    echo -e "\n${YELLOW}source $TEMP_ENV_FILE${NC}\n"
}

# 5. 清除本机 Shell 代理命令
unset_shell_proxy() {
    cat > "$TEMP_ENV_FILE" <<EOF
unset http_proxy https_proxy all_proxy no_proxy
echo -e "\033[0;33m🛑 当前终端代理已清除\033[0m"
EOF

    echo -e "\n${GREEN}=== 操作指南 ===${NC}"
    echo -e "请复制并执行以下命令："
    echo -e "\n${YELLOW}source $TEMP_ENV_FILE${NC}\n"
}

# ==================== 主菜单 ====================
show_menu() {
    clear
    echo -e "${BLUE}=======================================${NC}"
    echo -e "   本机与 Docker 临时代理管理工具"
    echo -e "${BLUE}=======================================${NC}"
    echo "1. 开启 Docker 代理 (用于 pull/update 镜像)"
    echo "2. 关闭 Docker 代理 (恢复直连)"
    echo "---------------------------------------"
    echo "3. 开启 本机Shell 代理 (生成 source 命令)"
    echo "4. 关闭 本机Shell 代理 (生成 unset 命令)"
    echo "---------------------------------------"
    echo "0. 退出"
    echo -e "${BLUE}=======================================${NC}"
    
    read -p "请选择: " OPT
    case $OPT in
        1) set_docker_proxy ;;
        2) unset_docker_proxy ;;
        3) set_shell_proxy ;;
        4) unset_shell_proxy ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${NC}" ;;
    esac
}

show_menu
