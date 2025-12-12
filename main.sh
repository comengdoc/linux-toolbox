#!/bin/bash

# ==============================================================================
# 模块化加载器 (Loader) - 强力调试版
# ==============================================================================

# [配置项] 你的 GitHub 用户名和仓库名
REPO_URL="https://raw.githubusercontent.com/comengdoc/linux-toolbox/main"
# 对应的 Git 仓库地址
GIT_REPO_URL="https://github.com/comengdoc/linux-toolbox"

CACHE_DIR="/tmp/toolbox_cache"
mkdir -p "$CACHE_DIR"

# ==================== [核心修改] 文件夹同步函数 ====================
# 去掉 function 关键字，提高兼容性
sync_mihomo_folder() {
    # 设定目标路径
    local target_dir="/tmp/mihomo"
    local temp_git_dir="/tmp/toolbox_git_temp"
    
    echo -e "\n========================================"
    echo -e "🚀 [DEBUG模式] 开始同步 mihomo 资源..."
    echo -e "========================================"

    # 1. 环境清理
    rm -rf "$target_dir"
    rm -rf "$temp_git_dir"

    # 2. 强制检查并安装 Git
    echo "Checking Git..."
    if ! command -v git &> /dev/null; then
        echo "⚠️  未检测到 Git，正在尝试安装..."
        if [ -f /etc/openwrt_release ]; then
            opkg update && opkg install git-http
        elif [ -f /etc/debian_version ]; then
            apt-get update && apt-get install -y git
        else
            yum install -y git || apk add git
        fi
    else
        echo "✅ Git 已安装: $(git --version)"
    fi

    # 3. 开始克隆 (开启指令回显 set -x，确保你能看到哪里卡住了)
    echo -e "📡 正在尝试下载..."
    
    # 临时开启调试模式，屏幕会打印执行的每一行命令
    # set -x 
    
    # 尝试直连 (带进度条 --progress 和 详细信息 --verbose)
    export GIT_SSL_NO_VERIFY=1
    
    if git clone --depth 1 --progress --verbose "$GIT_REPO_URL" "$temp_git_dir"; then
        echo -e "\n✅ Git 直连下载成功！"
    else
        echo -e "\n⚠️ 直连失败，正在尝试 Ghproxy 代理..."
        if git clone --depth 1 --progress --verbose "https://ghproxy.net/${GIT_REPO_URL}" "$temp_git_dir"; then
            echo -e "\n✅ 代理下载成功！"
        else
            echo -e "\n❌ [严重错误] 无法连接到 GitHub。"
            echo "请检查你的网络设置或 DNS。"
            # set +x
            return 1
        fi
    fi
    # 关闭调试模式
    # set +x

    # 4. 暴力检查下载结果
    echo -e "\n🔍 检查下载内容..."
    if [ -d "$temp_git_dir" ]; then
        echo "--------------------------------"
        ls -F "$temp_git_dir"
        echo "--------------------------------"
    else
        echo "❌ 临时目录不存在，下载彻底失败。"
        return 1
    fi

    # 5. 提取并部署
    if [ -d "$temp_git_dir/mihomo" ]; then
        echo "📦 发现 mihomo 文件夹，正在移动..."
        
        mkdir -p "$target_dir"
        cp -rf "$temp_git_dir/mihomo/." "$target_dir/"
        chmod -R 755 "$target_dir"
        
        echo -e "🎉 同步完成！"
        echo "当前 /tmp/mihomo 下的文件："
        ls -lh "$target_dir"
    else
        echo -e "❌ 错误：Git下载成功，但仓库里没有 'mihomo' 文件夹！"
        echo "你仓库里的文件列表如下 (请截图给我):"
        ls -F "$temp_git_dir"
    fi

    # 6. 清理
    rm -rf "$temp_git_dir"
    echo -e "========================================\n"
}

# === 立即执行 (确保这行代码没有被注释) ===
sync_mihomo_folder

# ==================== 模块加载函数 ====================
load_module() {
    local module_name="$1"
    local remote_file="${REPO_URL}/core/${module_name}"
    local local_file="${CACHE_DIR}/${module_name}"

    if [ "$1" != "update" ] && [ -s "$local_file" ]; then
        source "$local_file"
    else
        echo -ne "下载模块: ${module_name} ... "
        if ! curl -s -f -o "$local_file" "$remote_file"; then
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

# ==================== 加载核心模块 ====================
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

# ==================== 快捷键管理函数 ====================
manage_shortcut() {
    local install_path="/usr/local/bin/linux-toolbox"
    local download_url="${REPO_URL}/main.sh" 
    local current_user_home="$HOME"

    echo -e "${BLUE}=== 快捷键管理 ===${NC}"
    echo "1. 设置/更新 快捷键"
    echo "2. 删除 快捷键"
    echo "0. 返回"
    read -p "请选择: " action

    remove_command() {
        local name=$1
        rm -f "/usr/bin/${name}"
        rm -f "/usr/local/bin/${name}"
        if [ -f "${current_user_home}/.bashrc" ]; then
            if grep -q "alias ${name}=" "${current_user_home}/.bashrc"; then
                sed -i "/alias ${name}=/d" "${current_user_home}/.bashrc"
            fi
        fi
        unalias "${name}" 2>/dev/null
    }

    if [ "$action" == "2" ]; then
        read -p "请输入要删除的指令名称 (默认: box): " del_name
        local link_name=${del_name:-box}
        remove_command "$link_name"
        echo -e "${GREEN}✅ 快捷键 '${link_name}' 清理完毕。${NC}"
        hash -r
        return
    elif [ "$action" != "1" ]; then
        return
    fi

    read -p "请输入自定义快捷指令名称 (回车默认: box): " input_name
    local link_name=${input_name:-box}

    echo -e "正在下载最新脚本..."
    
    if ! curl -s -f -o "$install_path" "$download_url"; then
         if ! curl -s -f -o "$install_path" "https://ghproxy.net/${download_url}"; then
            echo -e "${RED}❌ 下载失败。${NC}"
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
            read -p "检测到旧的 'box' 指令，删除? [y/n]: " del_old
            [[ "$del_old" == "y" ]] && remove_command "box"
        fi
    fi
    hash -r 
}

# ==================== 主菜单 ====================
while true; do
    clear
    echo -e "${BLUE}====================================================${NC}"
    echo -e "       🛠️  Armbian/Docker 工具箱 (Debug v2.2)"
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
    read -p "请输入选项 [0-14]: " choice

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
    read -p "按回车键返回主菜单..."
done