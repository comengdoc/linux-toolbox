#!/bin/bash

# ==============================================================================
# 模块化加载器 (Loader) - v3.1 (智能容错版)
# ==============================================================================

# [基础配置]
REPO_URL="https://raw.githubusercontent.com/comengdoc/linux-toolbox/main"
GIT_REPO_URL="https://github.com/comengdoc/linux-toolbox"
CACHE_DIR="/tmp/toolbox_cache"
mkdir -p "$CACHE_DIR"

# [颜色定义]
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

# ==================== 0. 全局下载通道选择 ====================
PROXY_PREFIX=""

select_download_channel() {
    clear
    echo -e "${BLUE}====================================================${NC}"
    echo -e "       🌐 网络环境预设 (Network Setup)"
    echo -e "${BLUE}====================================================${NC}"
    echo -e "检测到您正在初始化工具箱，请选择下载加速通道："
    echo
    echo -e " ${GREEN}1.${NC} 默认加速 (gh-proxy.com)  ${YELLOW}[推荐国内用户]${NC}"
    echo -e " ${GREEN}2.${NC} GitHub 直连             ${YELLOW}[适合国外/已挂全局]${NC}"
    echo -e " ${GREEN}3.${NC} 手动输入加速地址        ${YELLOW}[自定义代理]${NC}"
    echo
    echo -e "${BLUE}----------------------------------------------------${NC}"
    read -p "请选择 [1-3] (默认 1): " net_choice < /dev/tty
    
    net_choice=${net_choice:-1}

    case "$net_choice" in
        1)
            PROXY_PREFIX="https://gh-proxy.com/"
            echo -e "${GREEN}✅ 已选择: 默认加速通道${NC}"
            ;;
        2)
            PROXY_PREFIX=""
            echo -e "${GREEN}✅ 已选择: GitHub 直连模式${NC}"
            ;;
        3)
            echo
            echo -e "请输入代理前缀 (例如: https://git.886.be/ )"
            echo -e "注意: 输入的地址结尾必须带 / (或者留空取消)"
            read -p "👉 地址: " custom_input < /dev/tty
            if [ -n "$custom_input" ]; then
                if [[ "$custom_input" != */ ]]; then
                    PROXY_PREFIX="${custom_input}/"
                else
                    PROXY_PREFIX="$custom_input"
                fi
                echo -e "${GREEN}✅ 已选择: 自定义通道 ($PROXY_PREFIX)${NC}"
            else
                PROXY_PREFIX="https://gh-proxy.com/"
                echo -e "${YELLOW}⚠️ 未输入，自动回退到默认加速通道${NC}"
            fi
            ;;
        *)
            PROXY_PREFIX="https://gh-proxy.com/"
            echo -e "${YELLOW}⚠️ 选项无效，自动使用默认加速通道${NC}"
            ;;
    esac
    sleep 1
}

# ==================== 1. 资源同步函数 (Mihomo) ====================
sync_mihomo_folder() {
    local target_dir="/tmp/mihomo"
    local temp_git_dir="/tmp/toolbox_git_temp"
    
    echo -e "----------------------------------------"
    echo -e "🚀 正在同步 Mihomo 资源 (使用选定通道)..."

    rm -rf "$target_dir"
    rm -rf "$temp_git_dir"

    if ! command -v git &> /dev/null; then
        echo -ne "正在安装 git... "
        if [ -f /etc/openwrt_release ]; then
            opkg update >/dev/null 2>&1 && opkg install git-http >/dev/null 2>&1
        elif [ -f /etc/debian_version ]; then
            apt-get update >/dev/null 2>&1 && apt-get install -y git >/dev/null 2>&1
        else
            yum install -y git >/dev/null 2>&1 || apk add git >/dev/null 2>&1
        fi
        echo "完成"
    fi

    export GIT_SSL_NO_VERIFY=1
    local final_git_url="${PROXY_PREFIX}${GIT_REPO_URL}"
    echo -e "🔄 Clone Source: ${YELLOW}${final_git_url}${NC}"

    if git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=30 clone --depth 1 "$final_git_url" "$temp_git_dir"; then
        echo -e "${GREEN}✅ 资源下载成功${NC}"
        if [ -d "$temp_git_dir/mihomo" ]; then
            mkdir -p "$target_dir"
            cp -rf "$temp_git_dir/mihomo/." "$target_dir/"
            chmod -R 755 "$target_dir"
            echo -e "📦 资源已缓存至 /tmp/mihomo"
        else
            echo -e "${YELLOW}⚠️ 仓库下载成功但未包含 mihomo 目录${NC}"
        fi
    else
        echo -e "${RED}❌ 资源下载失败！${NC}"
        echo -e "原因可能是代理地址无效或网络超时。"
        rm -rf "$temp_git_dir"
        read -p "按回车键继续 (部分功能可能无法使用)..." < /dev/tty
        return 1
    fi
    rm -rf "$temp_git_dir"
}

# ==================== 2. 核心：模块加载函数 (防崩坏版) ====================
# 参数1: 脚本文件名 (例如 backup.sh)
# 参数2: (可选) 脚本内的核心函数名 (例如 module_backup)，用于验证加载是否成功
load_module() {
    local module_name="$1"
    local func_check="$2"  # 新增：要检查的函数名
    local remote_file="${PROXY_PREFIX}${REPO_URL}/core/${module_name}"
    local local_file="${CACHE_DIR}/${module_name}"

    # 1. 内存检查：如果函数已经存在，直接返回成功 (秒开)
    if [ -n "$func_check" ] && declare -f "$func_check" > /dev/null; then
        return 0
    fi

    # 2. 本地缓存检查：如果文件存在且不为空，尝试 source
    if [ -s "$local_file" ]; then
        source "$local_file"
        # Source 完再次检查函数是否存在
        if [ -n "$func_check" ] && declare -f "$func_check" > /dev/null; then
            return 0
        fi
        # 如果 source 了文件但函数还是没有，说明文件可能损坏，删除之
        rm -f "$local_file"
    fi

    # 3. 下载流程
    echo -ne "📥 下载模块: ${module_name} ... "
    if curl -s -f -o "$local_file" "$remote_file"; then
         chmod +x "$local_file"
         source "$local_file"
         
         # 4. 最终验证
         if [ -n "$func_check" ] && ! declare -f "$func_check" > /dev/null; then
             echo -e "[\033[0;31m内容错误\033[0m]"
             echo -e "${RED}❌ 模块已下载但未检测到入口函数: ${func_check}${NC}"
             return 1
         fi
         
         echo -e "[\033[0;32mOK\033[0m]"
         return 0
    else
         echo -e "[\033[0;31m网络失败\033[0m]"
         return 1
    fi
}

# 辅助函数：安全运行模块 (用于菜单)
run_safe() {
    local script="$1"
    local func="$2"
    
    # 尝试加载，如果失败则提示
    if load_module "$script" "$func"; then
        $func
    else
        echo
        echo -e "${RED}❌ 无法运行功能: $func${NC}"
        echo -e "${YELLOW}可能是网络波动导致模块下载失败。${NC}"
        echo -e "建议：检查网络或更换加速通道后重试。"
        read -p "按回车键返回..." < /dev/tty
    fi
}

# ==================== 3. 脚本初始化流程 ====================

if [ "$1" == "update" ]; then
    rm -rf "$CACHE_DIR"
    echo "缓存已清理..."
fi

select_download_channel
sync_mihomo_folder

# 加载基础库 (不检查特定函数)
load_module "utils.sh"

if [ "$(id -u)" != "0" ]; then
    echo -e "${RED}请使用 Root 用户运行此脚本！${NC}"
    exit 1
fi

# [预加载所有模块]
# 即使这里部分失败，也不会报错退出，而是会在点击菜单时重试
echo -e "${BLUE}>>> 正在预加载功能模块...${NC}"
load_module "docker_install.sh" "module_docker_install"
load_module "mihomo.sh"         "module_mihomo"
load_module "bbr.sh"            "module_bbr"
load_module "network.sh"        "module_netmgr"
load_module "led.sh"            "module_led_fix"
load_module "docker_image.sh"   "module_docker_image_tool"
load_module "backup.sh"         "module_backup"
load_module "restore.sh"        "module_restore_smart"
load_module "docker_clean.sh"   "module_clean_docker"
load_module "1panel.sh"         "module_1panel"
load_module "disk.sh"           "module_disk_manager"
load_module "monitor.sh"        "module_nic_monitor"
load_module "mount_clean.sh"    "module_mount_cleaner"

if command -v configure_proxy &> /dev/null; then
    configure_proxy
fi

# ==================== 4. 快捷键管理 ====================
manage_shortcut() {
    local install_path="/usr/local/bin/linux-toolbox"
    local download_url="${PROXY_PREFIX}${REPO_URL}/main.sh" 
    local current_user_home="$HOME"

    echo -e "${BLUE}=== 快捷键管理 ===${NC}"
    echo "1. 设置/更新 快捷键"
    echo "2. 删除 快捷键"
    echo "0. 返回"
    read -p "请选择: " action < /dev/tty

    remove_command() {
        local name=$1
        rm -f "/usr/bin/${name}"
        rm -f "/usr/local/bin/${name}"
        if [ -f "${current_user_home}/.bashrc" ]; then
            sed -i "/alias ${name}=/d" "${current_user_home}/.bashrc" 2>/dev/null
        fi
        unalias "${name}" 2>/dev/null
    }

    if [ "$action" == "2" ]; then
        read -p "请输入要删除的指令名称 (默认: box): " del_name < /dev/tty
        local link_name=${del_name:-box}
        remove_command "$link_name"
        echo -e "${GREEN}✅ 快捷键 '${link_name}' 清理完毕。${NC}"
        hash -r
        return
    elif [ "$action" != "1" ]; then
        return
    fi

    read -p "请输入自定义快捷指令名称 (回车默认: box): " input_name < /dev/tty
    local link_name=${input_name:-box}

    echo -e "正在下载最新脚本 (使用当前加速通道)..."
    if curl -s -f -o "$install_path" "$download_url"; then
        chmod +x "$install_path"
        remove_command "$link_name"
        ln -sf "$install_path" "/usr/bin/${link_name}"
        echo -e "${GREEN}✅ 设置成功!${NC}"
        echo -e "输入 ${YELLOW}${link_name}${NC} 即可启动。"
    else
        echo -e "${RED}❌ 下载失败，请检查当前选择的加速通道是否可用。${NC}"
    fi
}

# ==================== 5. 主菜单 ====================
while true; do
    clear
    echo -e "${BLUE}====================================================${NC}"
    echo -e "       🛠️  Armbian/Docker 工具箱 (v3.1 智能容错版)"
    echo -e "${BLUE}====================================================${NC}"
    echo -e " ${GREEN}1.${NC} 安装/管理 Docker"
    echo -e " ${GREEN}2.${NC} 安装 Mihomo/Clash"
    echo -e " ${GREEN}3.${NC} BBR 加速管理"
    echo -e " ${GREEN}4.${NC} 网络/IP设置"
    echo -e " ${GREEN}5.${NC} R5C LED 修复"
    echo -e "${BLUE}----------------------------------------------------${NC}"
    echo -e " ${YELLOW}6.${NC} Docker 镜像备份/恢复"
    echo -e " ${YELLOW}7.${NC} 容器智能备份"
    echo -e " ${YELLOW}8.${NC} 容器智能恢复"
    echo -e " ${RED}9.${NC} 彻底清理 Docker"
    echo -e "${BLUE}----------------------------------------------------${NC}"
    echo -e " ${GREEN}10.${NC} 安装 1Panel 面板"
    echo -e " ${GREEN}11.${NC} 磁盘/分区管理"
    echo -e " ${GREEN}12.${NC} 网卡流量监控"
    echo -e " ${RED}13.${NC} Docker 挂载清理"
    echo -e "${BLUE}----------------------------------------------------${NC}"
    echo -e " ${GREEN}14.${NC} 管理快捷键"
    echo -e " ${GREEN}0.${NC} 退出脚本"
    echo
    
    read -p "请输入选项 [0-14]: " choice < /dev/tty

    # 使用 run_safe 包裹，确保运行时再次检查模块是否存在
    case "$choice" in
        1) run_safe "docker_install.sh" "module_docker_install" ;;
        2) run_safe "mihomo.sh"         "module_mihomo" ;;
        3) run_safe "bbr.sh"            "module_bbr" ;;
        4) run_safe "network.sh"        "module_netmgr" ;;
        5) run_safe "led.sh"            "module_led_fix" ;;
        6) run_safe "docker_image.sh"   "module_docker_image_tool" ;;
        7) run_safe "backup.sh"         "module_backup" ;;
        8) run_safe "restore.sh"        "module_restore_smart" ;;
        9) run_safe "docker_clean.sh"   "module_clean_docker" ;;
        10) run_safe "1panel.sh"        "module_1panel" ;;
        11) run_safe "disk.sh"          "module_disk_manager" ;;
        12) run_safe "monitor.sh"       "module_nic_monitor" ;;
        13) run_safe "mount_clean.sh"   "module_mount_cleaner" ;;
        14) manage_shortcut ;;
        0) exit 0 ;;
        *) echo "无效选项。" ;;
    esac
    
    echo
    if [ "$choice" != "0" ] && [ "$choice" != "14" ]; then
        read -p "按回车键返回主菜单..." < /dev/tty
    fi
done