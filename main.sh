#!/bin/bash

# ==============================================================================
# 模块化加载器 (Loader) - v2.6 (支持手动代理兜底)
# ==============================================================================

# [配置项]
REPO_URL="https://raw.githubusercontent.com/comengdoc/linux-toolbox/main"
GIT_REPO_URL="https://github.com/comengdoc/linux-toolbox"
CACHE_DIR="/tmp/toolbox_cache"
mkdir -p "$CACHE_DIR"

# 定义颜色 (防闪烁兼容)
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

# ==================== 1. 资源同步函数 (Mihomo) ====================
sync_mihomo_folder() {
    local target_dir="/tmp/mihomo"
    local temp_git_dir="/tmp/toolbox_git_temp"
    
    echo -e "----------------------------------------"
    echo -e "🚀 正在检查并同步 mihomo 资源..."

    # 1. 环境清理
    rm -rf "$target_dir"
    rm -rf "$temp_git_dir"

    # 2. 检查 Git
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

    # 3. 下载仓库 (三级重试机制)
    export GIT_SSL_NO_VERIFY=1
    local clone_success=0

    # --- 尝试 1: 默认代理 ---
    echo -e "🔄 [1/3] 尝试官方加速通道 (ghproxy)..."
    if git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=15 clone --depth 1 "https://ghproxy.net/${GIT_REPO_URL}" "$temp_git_dir"; then
        clone_success=1
    else
        echo -e "${YELLOW}⚠️ 默认代理连接超时，尝试直连...${NC}"
        
        # --- 尝试 2: 直连 ---
        echo -e "🔄 [2/3] 尝试直连 GitHub..."
        if git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=15 clone --depth 1 "$GIT_REPO_URL" "$temp_git_dir"; then
            clone_success=1
        else
            echo -e "${RED}❌ 直连也失败了。${NC}"
            
            # --- 尝试 3: 手动输入代理 (新增功能) ---
            echo -e "----------------------------------------"
            echo -e "${YELLOW}检测到网络环境较差，无法自动下载资源。${NC}"
            echo -e "请输入自定义代理前缀 (例如: https://mirror.ghproxy.com/ )"
            echo -e "或者直接按回车跳过安装。"
            # 使用 < /dev/tty 确保在管道模式下能读取键盘输入
            read -p "👉 请输入代理地址: " custom_proxy < /dev/tty
            
            if [ -n "$custom_proxy" ]; then
                echo -e "🔄 [3/3] 尝试使用自定义代理: ${custom_proxy} ..."
                # 确保拼接 URL 格式正确
                local full_url="${custom_proxy}${GIT_REPO_URL}"
                # 去掉可能重复的 // (http://除外)
                # full_url=$(echo "$full_url" | sed 's|(?<!:)//|/|g') 
                
                if git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=20 clone --depth 1 "$full_url" "$temp_git_dir"; then
                    echo -e "${GREEN}✅ 自定义代理下载成功！${NC}"
                    clone_success=1
                else
                    echo -e "${RED}❌ 自定义代理也无效。${NC}"
                fi
            fi
        fi
    fi

    if [ "$clone_success" -eq 0 ]; then
        echo -e "${RED}❌ 错误：所有下载方式均失败，跳过 mihomo 资源同步。${NC}"
        rm -rf "$temp_git_dir"
        return 1
    fi

    # 4. 部署文件
    if [ -d "$temp_git_dir/mihomo" ]; then
        mkdir -p "$target_dir"
        cp -rf "$temp_git_dir/mihomo/." "$target_dir/"
        chmod -R 755 "$target_dir"
        echo -e "${GREEN}📦 资源已准备就绪${NC}"
    else
        echo -e "${YELLOW}⚠️ 仓库结构异常，未找到 mihomo 目录。${NC}"
    fi

    # 5. 清理
    rm -rf "$temp_git_dir"
    echo -e "----------------------------------------"
}

# === 立即执行同步 ===
sync_mihomo_folder

# ==================== 2. 模块加载函数 ====================
load_module() {
    local module_name="$1"
    local remote_file="${REPO_URL}/core/${module_name}"
    local local_file="${CACHE_DIR}/${module_name}"

    if [ "$1" != "update" ] && [ -s "$local_file" ]; then
        source "$local_file"
    else
        echo -ne "下载模块: ${module_name} ... "
        
        # 优先尝试加速地址
        if curl -s -f -o "$local_file" "https://ghproxy.net/${remote_file}"; then
             echo -e "[\033[0;32mOK\033[0m]"
        else
             # 备用直连
             if ! curl -s -f -o "$local_file" "$remote_file"; then
                echo -e "[\033[0;31mFail\033[0m]"
                return 1
             else
                echo -e "[\033[0;32mOK (Direct)\033[0m]"
             fi
        fi
        
        chmod +x "$local_file"
        source "$local_file"
    fi
}

if [ "$1" == "update" ]; then
    rm -rf "$CACHE_DIR"
    echo "缓存已清理..."
fi

# ==================== 3. 加载核心模块 ====================
load_module "utils.sh"

# 权限检查
if [ "$(id -u)" != "0" ]; then
    echo -e "${RED}请使用 Root 用户运行此脚本！${NC}"
    exit 1
fi

load_module "docker_install.sh"
load_module "mihomo.sh"
load_module "bbr.sh"
load_module "network.sh"
load_module "led.sh"
load_module "docker_image.sh"
load_module "backup.sh"
load_module "restore.sh"
load_module "docker_clean.sh"
load_module "1panel.sh"
load_module "disk.sh"
load_module "monitor.sh"
load_module "mount_clean.sh"

# 如果 utils.sh 里有 configure_proxy，则调用
if command -v configure_proxy &> /dev/null; then
    configure_proxy
fi

# ==================== 4. 快捷键管理 ====================
manage_shortcut() {
    local install_path="/usr/local/bin/linux-toolbox"
    local download_url="${REPO_URL}/main.sh" 
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

    echo -e "正在安装到系统..."
    if ! curl -s -f -o "$install_path" "https://ghproxy.net/${download_url}"; then
         if ! curl -s -f -o "$install_path" "$download_url"; then
            echo -e "${RED}❌ 下载失败${NC}"
            return 1
         fi
    fi

    chmod +x "$install_path"
    remove_command "$link_name"
    ln -sf "$install_path" "/usr/bin/${link_name}"

    echo -e "${GREEN}✅ 设置成功!${NC}"
    echo -e "输入 ${YELLOW}${link_name}${NC} 即可启动。"
    
    if [ "$link_name" != "box" ]; then
        if grep -q "alias box=" "${current_user_home}/.bashrc" 2>/dev/null || [ -f "/usr/bin/box" ]; then
            read -p "检测到旧的 'box' 指令，删除? [y/n]: " del_old < /dev/tty
            [[ "$del_old" == "y" ]] && remove_command "box"
        fi
    fi
    hash -r 
}

# ==================== 5. 主菜单 ====================
while true; do
    clear
    echo -e "${BLUE}====================================================${NC}"
    echo -e "       🛠️  Armbian/Docker 工具箱 (v2.6 Proxy Fix)"
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
    echo -e " ${GREEN}0.${NC} 退出"
    echo
    
    # 输入重定向，防止跳过
    read -p "请输入选项 [0-14]: " choice < /dev/tty

    case "$choice" in
        1) module_docker_install ;;
        2) module_mihomo ;;
        3) module_bbr ;;
        4) module_netmgr ;;
        5) module_led_fix ;;
        6) module_docker_image_tool ;;
        7) module_backup ;;
        8) module_restore_smart ;;
        9) module_clean_docker ;;
        10) module_1panel ;;
        11) module_disk_manager ;;
        12) module_nic_monitor ;;
        13) module_mount_cleaner ;;
        14) manage_shortcut ;;
        0) exit 0 ;;
        *) echo "无效选项。" ;;
    esac
    
    echo
    read -p "按回车键返回主菜单..." < /dev/tty
done