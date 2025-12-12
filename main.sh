#!/bin/bash

# ==============================================================================
# 模块化加载器 (Loader) - Final Release
# ==============================================================================

# [配置项] 你的 GitHub 用户名和仓库名
REPO_URL="https://raw.githubusercontent.com/comengdoc/linux-toolbox/main"
# 对应的 Git 仓库地址
GIT_REPO_URL="https://github.com/comengdoc/linux-toolbox"

CACHE_DIR="/tmp/toolbox_cache"
mkdir -p "$CACHE_DIR"

# ==================== 1. 资源同步函数 (Mihomo) ====================
sync_mihomo_folder() {
    local target_dir="/tmp/mihomo"
    local temp_git_dir="/tmp/toolbox_git_temp"
    
    # 仅在第一次运行时提示，避免菜单循环时干扰视觉
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

    # 3. 下载仓库 (尝试直连 -> 失败转代理)
    export GIT_SSL_NO_VERIFY=1
    
    # 尝试直连 (静默模式，失败才显示)
    if git clone --depth 1 "$GIT_REPO_URL" "$temp_git_dir" >/dev/null 2>&1; then
        echo -e "✅ GitHub 直连下载成功"
    else
        echo -e "⚠️ 直连慢，尝试使用加速镜像..."
        if git clone --depth 1 "https://ghproxy.net/${GIT_REPO_URL}" "$temp_git_dir" >/dev/null 2>&1; then
            echo -e "✅ 代理加速下载成功"
        else
            echo -e "❌ [警告] 无法连接到仓库，mihomo 安装功能可能受限。"
            rm -rf "$temp_git_dir"
            return 1
        fi
    fi

    # 4. 部署文件
    if [ -d "$temp_git_dir/mihomo" ]; then
        mkdir -p "$target_dir"
        cp -rf "$temp_git_dir/mihomo/." "$target_dir/"
        chmod -R 755 "$target_dir"
        echo -e "📦 资源已就绪 (/tmp/mihomo)"
    else
        echo -e "⚠️ 提示：仓库下载成功，但未找到 mihomo 文件夹 (可能是纯脚本更新)。"
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
        if ! curl -s -f -o "$local_file" "$remote_file"; then
             # 备用下载
             remote_file="https://ghproxy.net/${remote_file}"
             if ! curl -s -f -o "$local_file" "$remote_file"; then
                echo -e "[\033[0;31mFail\033[0m]"
                return 1
             fi
        fi
        echo -e "[\033[0;32mOK\033[0m]"
        chmod +x "$local_file"
        source "$local_file"
    fi
}

if [ "$1" == "update" ]; then
    rm -rf "$CACHE_DIR"
    echo "缓存已清理..."
fi

# ==================== 3. 加载功能模块 ====================
load_module "utils.sh"

check_root

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

configure_proxy

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
    if ! curl -s -f -o "$install_path" "$download_url"; then
         if ! curl -s -f -o "$install_path" "https://ghproxy.net/${download_url}"; then
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

# ==================== 5. 主菜单 (防闪烁版) ====================
while true; do
    clear
    echo -e "${BLUE}====================================================${NC}"
    echo -e "       🛠️  Armbian/Docker 工具箱 (Online v2.5)"
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
    
    # === 关键修改：重定向输入流 ===
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