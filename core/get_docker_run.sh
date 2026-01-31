#!/bin/bash
# 模块名称: Docker Run 命令导出工具 (GHCR 云端版)
# 适配: main.sh v3.9+ (通过 run_safe 调用)
# 功能: 自动拉取 GHCR 镜像，支持屏幕输出及导出 .txt 文件到当前目录

function docker_run_export() {
    # --- 1. 定义局部变量 ---
    local GREEN='\033[0;32m'
    local BLUE='\033[0;34m'
    local RED='\033[0;31m'
    local YELLOW='\033[1;33m'
    local NC='\033[0m'
    
    # [核心修改] 定义您的 GitHub 镜像地址
    local TARGET_IMAGE="ghcr.io/comengdoc/runlike:main"

    # --- 2. 内部函数定义 ---
    
    # 函数: 检查并拉取镜像 (替代原有的构建逻辑)
    check_and_pull_image() {
        # 检查本地是否有该镜像
        if [ -z "$(docker images -q "$TARGET_IMAGE" 2> /dev/null)" ]; then
            echo -e "${BLUE}[INFO] 本地未检测到工具镜像，正在从 GitHub 拉取...${NC}"
            echo -e "${BLUE}>>> 目标: ${GREEN}$TARGET_IMAGE${NC}"
            
            if docker pull "$TARGET_IMAGE"; then
                echo -e "${GREEN}[SUCCESS] 镜像拉取成功！${NC}"
            else
                echo -e "${RED}[ERROR] 镜像拉取失败！${NC}"
                echo -e "${YELLOW}可能原因: 网络无法访问 GitHub 容器仓库。建议开启全局代理或检查网络。${NC}"
                return 1
            fi
        else
            # 只有在调试时才显示，保持界面清爽
            # echo -e "${GREEN}[INFO] 镜像已就绪。${NC}" 
            :
        fi
    }

    # 函数: 获取纯净命令文本
    get_clean_cmd() {
        local c_name=$1
        # [核心修改] 使用 TARGET_IMAGE 变量运行容器
        docker run --rm -v /var/run/docker.sock:/var/run/docker.sock "$TARGET_IMAGE" -p "$c_name" 2>/dev/null | grep -vE 'com.docker.compose|--label|--hostname|--runtime|--workdir'
    }

    # 函数: 屏幕显示模式 (单个容器)
    generate_command_screen() {
        local container_name=$1
        echo -e "\n${BLUE}====================================================${NC}"
        echo -e "${BLUE}容器名称: ${GREEN}$container_name${NC}"
        echo -e "${BLUE}====================================================${NC}"
        
        local cmd=$(get_clean_cmd "$container_name")
        
        if [ -z "$cmd" ]; then
            echo -e "${RED}[ERROR] 无法获取信息，请确认容器名正确且正在运行。${NC}"
        else
            echo "$cmd"
        fi
        echo "" 
    }

    # --- 3. 主逻辑执行 ---

    echo -e "${BLUE}=== Docker 启动命令反推工具 (Cloud Edition) ===${NC}"

    # 1. 检查/拉取镜像
    check_and_pull_image
    if [ $? -ne 0 ]; then return 1; fi

    # 2. 列出容器
    echo -e "\n${BLUE}--- 当前正在运行的容器 ---${NC}"
    docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}"
    echo -e "${BLUE}---------------------------${NC}"

    # 3. 交互循环
    while true; do
        echo -e "\n请输入容器名称 (直接回车返回主菜单，输入 ${GREEN}all${NC} 导出所有): "
        read -p "> " input_name

        if [ -z "$input_name" ]; then
            echo "正在返回主菜单..."
            break
        fi

        if [ "$input_name" == "all" ]; then
            # --- 全量导出模式 ---
            local timestamp=$(date +%Y%m%d_%H%M%S)
            
            # [核心修改] 保存到当前执行脚本的目录 (${PWD})，而不是 /root
            # 这样您在哪里运行脚本，文件就在哪里，方便查找
            local output_file="${PWD}/docker_run_backup_${timestamp}.txt"
            
            echo -e "\n${YELLOW}>>> 正在批量导出...${NC}"
            
            # 写入文件头
            echo "# Docker Run Commands Backup" > "$output_file"
            echo "# Generated Time: $(date)" >> "$output_file"
            echo "# Generator Image: $TARGET_IMAGE" >> "$output_file"
            echo "# ----------------------------------------" >> "$output_file"
            
            local containers=$(docker ps --format "{{.Names}}")
            for c in $containers; do
                echo -e "正在处理: ${GREEN}$c${NC} ..."
                local cmd=$(get_clean_cmd "$c")
                
                if [ -n "$cmd" ]; then
                    echo "" >> "$output_file"
                    echo "### Container: $c ###" >> "$output_file"
                    echo "$cmd" >> "$output_file"
                else
                    echo "# [ERROR] Failed to get command for $c" >> "$output_file"
                fi
            done
            
            echo -e "\n${GREEN}[SUCCESS] 导出完成！${NC}"
            echo -e "文件已保存至: ${YELLOW}$output_file${NC}"
            read -p "按任意键继续..."
        else
            # --- 单个查看模式 ---
            generate_command_screen "$input_name"
        fi
    done
}