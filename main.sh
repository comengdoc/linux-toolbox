#!/bin/bash

# ==============================================================================
# 模块化加载器 (Loader) - 增强修复版
# ==============================================================================

# [配置项] 你的 GitHub 用户名和仓库名
REPO_URL="https://raw.githubusercontent.com/comengdoc/linux-toolbox/main"
# 对应的 Git 仓库地址 (用于下载文件夹)
GIT_REPO_URL="https://github.com/comengdoc/linux-toolbox"

CACHE_DIR="/tmp/toolbox_cache"
mkdir -p "$CACHE_DIR"

# ==================== [核心修改] 文件夹同步函数 ====================
function sync_mihomo_folder() {
    # 设定目标路径为 /tmp/mihomo
    local target_dir="/tmp/mihomo"
    local temp_git_dir="/tmp/toolbox_git_temp"
    
    echo -e "----------------------------------------"
    echo -e "🚀 正在同步 mihomo 资源..."

    # 1. 环境清理
    rm -rf "$target_dir"
    rm -rf "$temp_git_dir"

    # 2. 检查 Git (如果缺失则安装)
    if ! command -v git &> /dev/null; then
        echo -ne "正在安装 git 环境... "
        if [ -f /etc/openwrt_release ]; then
            opkg update >/dev/null 2>&1 && opkg install git-http >/dev/null 2>&1
        elif [ -f /etc/debian_version ]; then
            apt-get update >/dev/null 2>&1 && apt-get install -y git >/dev/null 2>&1
        else
            yum install -y git >/dev/null 2>&1 || apk add git >/dev/null 2>&1
        fi
        echo "完成"
    fi

    # 3. 开始克隆 (移除 >/dev/null 以显示真实错误，方便调试)
    echo -e "📡 正在尝试从 GitHub 拉取配置..."
    
    # 尝试直连 (关闭 SSL 验证防止老旧设备证书报错)
    export GIT_SSL_NO_VERIFY=1
    
    # 优先尝试直连
    if git clone --depth 1 "$GIT_REPO_URL" "$temp_git_dir"; then
        echo -e "✅ 直连下载成功"
    else
        echo -e "⚠️ 直连失败，尝试使用 Ghproxy 代理..."
        # 尝试代理
        if git clone --depth 1 "https://ghproxy.net/${GIT_REPO_URL}" "$temp_git_dir"; then
            echo -e "✅ 代理下载成功"
        else
            echo -e "❌ 严重错误：无法连接到 GitHub！"
            echo -e "可能原因：网络问题 / 仓库地址错误 / 仓库是私有的"
            rm -rf "$temp_git_dir"
            # 这里不退出脚本，以免影响后续菜单显示，但会打印错误
            return 1 
        fi
    fi

    # 4. 提取文件并部署
    if [ -d "$temp_git_dir/mihomo" ]; then
        echo "📦 发现 mihomo 文件夹，正在部署到 $target_dir ..."
        
        mkdir -p "$target_dir"
        # 使用 cp -rf 强制复制，比 mv 更稳定
        cp -rf "$temp_git_dir/mihomo/." "$target_dir/"
        chmod -R 755 "$target_dir"
        
        echo -e "🎉 同步完成！"
        # 打印一下文件列表证明下载成功了
        echo "当前 /tmp/mihomo 内容："
        ls -F "$target_dir" | head -n 5
    else
        echo -e "❌ 错误：仓库下载成功，但其中没有找到 'mihomo' 文件夹！"
        echo -e "请检查 GitHub 仓库根目录下是否存在该文件夹（注意大小写）。"
    fi

    # 5. 清理临时仓库
    rm -rf "$temp_git_dir"
    echo -e "----------------------------------------"
}

# === 立即执行文件夹同步 (在加载菜单前执行) ===
sync_mihomo_folder

# ==================== 模块加载函数 (保持不变) ====================
function load_module() {
    local module_name="$1"
    local remote_file="${REPO_URL}/core/${module_name}"
    local local_file="${CACHE_DIR}/${module_name}"

    # 简单的缓存策略：文件存在且大小不为0则直接加载
    if [ "$1" != "update" ] && [ -s "$local_file" ]; then
        source "$local_file"
    else
        echo -ne "下载模块: ${module_name} ... "
        # 尝试直连下载
        if ! curl -s -f -o "$local_file" "$remote_file"; then
             # 备用：代理下载
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

# 如果第一个参数是 update，清空缓存
if [ "$1" == "update" ]; then
    rm -rf "$CACHE_DIR"
    echo "缓存已清理，准备更新..."
fi

# ==================== 加载核心模块 ====================
load_module "utils.sh"

# 检查权限
check_root

# 加载所有功能模块
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

# 启动代理配置 (来自 utils.sh)
configure_proxy

# ==================== 快捷键管理函数 ====================
function manage_shortcut() {
    local install_path="/usr/local/bin/linux-toolbox"
    local download_url="${REPO_URL}/main.sh" 
    local current_user_home="$HOME"

    echo -e "${BLUE}=== 快捷键管理 ===${NC}"
    echo "1. 设置/更新 快捷键"
    echo "2. 删除 快捷键"
    echo "0. 返回"
    read -p "请选择: " action

    function remove_command() {
        local name=$1
        rm -f "/usr/bin/${name}"
        rm -f "/usr/local/bin/${name}"
        if [ -f "${current_user_home}/.bashrc" ]; then
            if grep -q "alias ${name}=" "${current_user_home}/.bashrc"; then
                sed -i "/alias ${name}=/d" "${current_user_home}/.bashrc"
                echo -e "${YELLOW}已清理 .bashrc 中的别名: ${name}${NC}"
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

    echo -e "正在下载最新脚本到: ${install_path} ..."
    
    if ! curl -s -f -o "$install_path" "$download_url"; then
         echo -e "${YELLOW}下载失败，尝试使用加速镜像...${NC}"
         if ! curl -s -f -o "$install_path" "https://ghproxy.net/${download_url}"; then
            echo -e "${RED}❌ 安装失败：无法下载脚本文件。${NC}"
            return 1
         fi
    fi

    chmod +x "$install_path"
    remove_command "$link_name"
    ln -sf "$install_path" "/usr/bin/${link_name}"

    echo -e "${GREEN}✅ 设置成功!${NC}"
    echo -e "以后在终端输入 ${YELLOW}${link_name}${NC} 即可启动本工具。"
    
    if [ "$link_name" != "box" ]; then
        if grep -q "alias box=" "${current_user_home}/.bashrc" 2>/dev/null || [ -f "/usr/bin/box" ] || [ -f "/usr/local/bin/box" ]; then
            echo
            read -p "检测到旧的 'box' 指令存在，是否删除? [y/n]: " del_old
            if [[ "$del_old" == "y" ]]; then
                remove_command "box"
                echo -e "${GREEN}旧指令 'box' 已删除。${NC}"
            fi
        fi
    fi
    hash -r 
}

# ==================== 主菜单循环 ====================
while true; do
    clear
    echo -e "${BLUE}====================================================${NC}"
    echo -e "       🛠️  Armbian/Docker 模块化工具箱 (Online v2.1)"
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
    echo -e " ${GREEN}14.${NC} 管理快捷键 (安装/删除/改名)"
    echo -e " ${GREEN}0.${NC} 退出脚本"
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
        0) echo "再见！"; exit 0 ;;
        *) echo "无效选项。" ;;
    esac
    
    echo
    read -p "按回车键返回主菜单..."
done