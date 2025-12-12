#!/bin/bash

# ==============================================================================
# 模块化加载器 (Loader)
# ==============================================================================

# [配置项] 请将此处修改为你的 GitHub 用户名和仓库名
REPO_URL="https://raw.githubusercontent.com/comengdoc/linux-toolbox/main"
# 对应的 Git 仓库地址 (用于下载文件夹)
GIT_REPO_URL="https://github.com/comengdoc/linux-toolbox"

CACHE_DIR="/tmp/toolbox_cache"
mkdir -p "$CACHE_DIR"

# ==================== [新增] 文件夹同步函数 ====================
function sync_mihomo_folder() {
    local target_dir="/tmp/mihomo"
    local temp_git_dir="/tmp/toolbox_git_temp"
    
    # 每次运行先清理旧文件，确保下载的是最新的
    rm -rf "$target_dir"
    rm -rf "$temp_git_dir"

    echo -ne "正在同步 mihomo 资源文件夹... "

    # 1. 检查 git 是否安装 (如果系统极简可能需要安装)
    if ! command -v git &> /dev/null; then
        echo -ne "(安装git)... "
        if [ -f /etc/openwrt_release ]; then
            opkg update >/dev/null 2>&1 && opkg install git-http >/dev/null 2>&1
        elif [ -f /etc/debian_version ]; then
            apt-get update >/dev/null 2>&1 && apt-get install -y git >/dev/null 2>&1
        else
            yum install -y git >/dev/null 2>&1 || apk add git >/dev/null 2>&1
        fi
    fi

    # 2. 尝试拉取仓库 (使用 depth=1 极速模式，不下载历史记录)
    # 优先尝试直连，失败则走代理
    if git clone --depth 1 "$GIT_REPO_URL" "$temp_git_dir" >/dev/null 2>&1; then
        STATUS="OK"
    else
        # 备用：使用 ghproxy 代理拉取
        if git clone --depth 1 "https://ghproxy.net/${GIT_REPO_URL}" "$temp_git_dir" >/dev/null 2>&1; then
            STATUS="OK (Proxy)"
        else
            STATUS="FAIL"
        fi
    fi

    # 3. 提取文件并清理
    if [ "$STATUS" != "FAIL" ] && [ -d "$temp_git_dir/mihomo" ]; then
        # 将 mihomo 文件夹移动到 /tmp/mihomo
        mv "$temp_git_dir/mihomo" "/tmp/"
        echo -e "[\033[0;32m${STATUS}\033[0m]"
    else
        echo -e "[\033[0;31mFail\033[0m] (未找到文件夹或网络错误)"
    fi

    # 4. 删除临时的 git 仓库，节省空间
    rm -rf "$temp_git_dir"
}

# === 立即执行文件夹同步 ===
sync_mihomo_folder

# 模块加载函数
function load_module() {
    local module_name="$1"
    local remote_file="${REPO_URL}/core/${module_name}"
    local local_file="${CACHE_DIR}/${module_name}"

    # 简单的缓存策略：文件存在且大小不为0则直接加载，否则下载
    # 如果需要强制更新，请运行脚本时带参数: ./main.sh update
    if [ "$1" != "update" ] && [ -s "$local_file" ]; then
        source "$local_file"
    else
        echo -ne "下载模块: ${module_name} ... "
        # 尝试使用国内代理下载 (如果主链接失败)
        if ! curl -s -f -o "$local_file" "$remote_file"; then
             # 备用下载逻辑 (可选)
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

# ==================== 快捷键管理函数 (最终增强版) ====================
function manage_shortcut() {
    local install_path="/usr/local/bin/linux-toolbox"
    local download_url="${REPO_URL}/main.sh" 
    # 获取当前用户的 home 目录
    local current_user_home="$HOME"

    echo -e "${BLUE}=== 快捷键管理 ===${NC}"
    echo "1. 设置/更新 快捷键"
    echo "2. 删除 快捷键"
    echo "0. 返回"
    read -p "请选择: " action

    # 内部函数：全方位清理指令（文件+别名）
    function remove_command() {
        local name=$1
        
        # 1. 删除常见路径下的软连接文件
        rm -f "/usr/bin/${name}"
        rm -f "/usr/local/bin/${name}"
        
        # 2. 清理 .bashrc 中的别名 (解决你遇到的问题)
        if [ -f "${current_user_home}/.bashrc" ]; then
            # 如果 .bashrc 里有 alias name=... 的行，直接删除
            if grep -q "alias ${name}=" "${current_user_home}/.bashrc"; then
                sed -i "/alias ${name}=/d" "${current_user_home}/.bashrc"
                echo -e "${YELLOW}已清理 .bashrc 中的别名: ${name}${NC}"
            fi
        fi
        
        # 3. 尝试取消当前会话的别名 (如果存在)
        unalias "${name}" 2>/dev/null
    }

    if [ "$action" == "2" ]; then
        read -p "请输入要删除的指令名称 (默认: box): " del_name
        local link_name=${del_name:-box}
        
        remove_command "$link_name"
        
        echo -e "${GREEN}✅ 快捷键 '${link_name}' 清理完毕。${NC}"
        echo -e "${YELLOW}提示: 如果之前是别名，请断开 SSH 重新连接以彻底生效。${NC}"
        hash -r
        return
    elif [ "$action" != "1" ]; then
        return
    fi

    # === 下面是设置逻辑 ===
    
    # 1. 让用户自定义名称
    read -p "请输入自定义快捷指令名称 (回车默认: box): " input_name
    local link_name=${input_name:-box}

    echo -e "正在下载最新脚本到: ${install_path} ..."
    
    # 2. 下载脚本
    if ! curl -s -f -o "$install_path" "$download_url"; then
         echo -e "${YELLOW}下载失败，尝试使用加速镜像...${NC}"
         if ! curl -s -f -o "$install_path" "https://ghproxy.net/${download_url}"; then
            echo -e "${RED}❌ 安装失败：无法下载脚本文件。请检查网络。${NC}"
            return 1
         fi
    fi

    # 3. 赋予权限
    chmod +x "$install_path"

    # 4. 创建软连接 (先清理旧的，防止冲突)
    remove_command "$link_name"
    ln -sf "$install_path" "/usr/bin/${link_name}"

    echo -e "${GREEN}✅ 设置成功!${NC}"
    echo -e "以后在终端输入 ${YELLOW}${link_name}${NC} 即可启动本工具。"
    
    # 5. 智能清理旧指令 (特别是默认的 box)
    if [ "$link_name" != "box" ]; then
        # 检查是否还有 box 的残留 (文件或别名)
        if grep -q "alias box=" "${current_user_home}/.bashrc" 2>/dev/null || [ -f "/usr/bin/box" ] || [ -f "/usr/local/bin/box" ]; then
            echo
            read -p "检测到旧的 'box' 指令(或别名)存在，是否删除? [y/n]: " del_old
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
    echo -e "       🛠️  Armbian/Docker 模块化工具箱 (Online v2.0)"
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