#!/bin/bash

# 定义颜色
Green_font_prefix="\033[32m" && Red_font_prefix="\033[31m" && Green_background_prefix="\033[42;37m" && Red_background_prefix="\033[41;37m" && Font_color_suffix="\033[0m"
Info="${Green_font_prefix}[信息]${Font_color_suffix}"
Error="${Red_font_prefix}[错误]${Font_color_suffix}"
Tip="${Green_font_prefix}[注意]${Font_color_suffix}"

# 导入工具类（保持原有逻辑）
source ./core/utils.sh

# 检查Root权限
check_root(){
	[[ $EUID != 0 ]] && echo -e "${Error} 当前非ROOT账号(或没有ROOT权限)，无法继续操作，请更换ROOT账号或使用 sudo su 后重试。" && exit 1
}

# 新增功能：设置快捷键 box
set_shortcut(){
    local current_path=$(readlink -f "$0")
    ln -sf "$current_path" /usr/bin/box
    chmod +x "$current_path"
    echo -e "${Info} 快捷键设置成功！"
    echo -e "${Info} 您现在可以在终端任意位置输入 ${Green_font_prefix}box${Font_color_suffix} 来启动本工具。"
    read -p " 按回车键返回主菜单..."
}

# 主菜单显示
show_menu(){
	clear
	echo -e "
  ${Green_font_prefix}Linux Toolbox 一键脚本工具箱${Font_color_suffix}
  
  ${Green_font_prefix}1.${Font_color_suffix} 系统信息监控 (System Monitor)
  ${Green_font_prefix}2.${Font_color_suffix} Docker 安装与管理 (Docker Manager)
  ${Green_font_prefix}3.${Font_color_suffix} Docker 容器清理 (Docker Clean)
  ${Green_font_prefix}4.${Font_color_suffix} 网络管理 (Network Manager)
  ${Green_font_prefix}5.${Font_color_suffix} 系统备份 (Backup System)
  ${Green_font_prefix}6.${Font_color_suffix} 系统还原 (Restore System)
  ${Green_font_prefix}7.${Font_color_suffix} 磁盘挂载/清理 (Disk Tools)
  ${Green_font_prefix}8.${Font_color_suffix} LED控制 (LED Control)
  
  ${Green_font_prefix}9. 设置快捷键 box 启动本程序${Font_color_suffix}
  
  ${Green_font_prefix}0.${Font_color_suffix} 退出脚本
 "
}

# 菜单逻辑处理
start_menu(){
    check_root
    show_menu
    read -p " 请输入数字 [0-9]:" num
    case "$num" in
        1)
            bash ./core/system_monitor.sh
            ;;
        2)
            bash ./core/docker_install.sh
            ;;
        3)
            bash ./core/docker_clean.sh
            ;;
        4)
            bash ./core/network.sh
            ;;
        5)
            bash ./core/backup.sh
            ;;
        6)
            bash ./core/restore.sh
            ;;
        7)
            bash ./core/disk.sh
            ;;
        8)
            bash ./core/led.sh
            ;;
        9)
            set_shortcut  # 调用新增的快捷键函数
            start_menu
            ;;
        0)
            exit 1
            ;;
        *)
            clear
            echo -e "${Error}:请输入正确数字 [0-9]"
            sleep 2s
            start_menu
            ;;
    esac
}

# 启动主程序
start_menu