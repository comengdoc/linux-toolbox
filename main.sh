#!/bin/bash

# ==============================================================================
# 模块化加载器 (Loader)
# ==============================================================================

# [配置项] 请将此处修改为你的 GitHub 用户名和仓库名
REPO_URL="https://raw.githubusercontent.com/comengdoc/linux-toolbox/main"
CACHE_DIR="/tmp/toolbox_cache"

mkdir -p "$CACHE_DIR"

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
    echo -e " ${GREEN}0.${NC} 退出脚本"
    echo
    read -p "请输入选项 [0-13]: " choice

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
        0) echo "再见！"; exit 0 ;;
        *) echo "无效选项。" ;;
    esac
    
    echo
    read -p "按回车键返回主菜单..."
done
