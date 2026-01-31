#!/bin/bash
# 模块名称: Docker Run 命令导出工具
# 适配: main.sh v3.9+ (通过 run_safe 调用)
# 更新: 增加了全量导出到 /root 文件功能

function docker_run_export() {
    # --- 1. 定义局部颜色 ---
    local GREEN='\033[0;32m'
    local BLUE='\033[0;34m'
    local RED='\033[0;31m'
    local YELLOW='\033[1;33m'
    local NC='\033[0m'

    # --- 2. 内部函数定义 ---
    
    # 检查并构建镜像
    check_and_build_image() {
        if [ -z "$(docker images -q runlike 2> /dev/null)" ]; then
            echo -e "${BLUE}[INFO] 未检测到 runlike 镜像，正在为您自动构建 (适配本机架构)...${NC}"
            cat > Dockerfile.temp <<EOF
FROM python:3-alpine
RUN apk add --no-cache docker-cli
RUN python3 -m venv /app/venv
ENV PATH="/app/venv/bin:\$PATH"
RUN pip3 install runlike
ENTRYPOINT ["runlike"]
EOF
            docker build -t runlike -f Dockerfile.temp .
            local build_status=$?
            rm Dockerfile.temp
            if [ $build_status -eq 0 ]; then
                echo -e "${GREEN}[SUCCESS] 镜像构建成功！${NC}"
            else
                echo -e "${RED}[ERROR] 镜像构建失败，请检查网络或 Docker 环境。${NC}"
                return 1
            fi
        fi
    }

    # 核心获取命令逻辑 (独立出来方便复用)
    get_clean_cmd() {
        local c_name=$1
        # 获取命令并过滤杂讯
        docker run --rm -v /var/run/docker.sock:/var/run/docker.sock runlike -p "$c_name" 2>/dev/null | grep -vE 'com.docker.compose|--label|--hostname|--runtime|--workdir'
    }

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

    echo -e "${BLUE}=== Docker 启动命令反推工具 ===${NC}"

    check_and_build_image
    if [ $? -ne 0 ]; then return 1; fi

    echo -e "\n${BLUE}--- 当前正在运行的容器 ---${NC}"
    docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}"
    echo -e "${BLUE}---------------------------${NC}"

    while true; do
        echo -e "\n请输入容器名称 (直接回车返回主菜单，输入 ${GREEN}all${NC} 导出所有): "
        read -p "> " input_name

        if [ -z "$input_name" ]; then
            echo "正在返回主菜单..."
            break
        fi

        if [ "$input_name" == "all" ]; then
            # --- [核心修改] 导出到文件的逻辑 ---
            
            # 1. 定义文件名 (格式: /root/docker_run_backup_年月日_时分秒.txt)
            local timestamp=$(date +%Y%m%d_%H%M%S)
            local output_file="/root/docker_run_backup_${timestamp}.txt"
            
            echo -e "\n${YELLOW}>>> 正在准备导出所有容器命令...${NC}"
            echo -e "${BLUE}>>> 目标文件: ${GREEN}$output_file${NC}"
            
            # 2. 写入文件头
            echo "# Docker Run Commands Backup" > "$output_file"
            echo "# Generated Time: $(date)" >> "$output_file"
            echo "# ----------------------------------------" >> "$output_file"
            
            # 3. 循环处理
            local containers=$(docker ps --format "{{.Names}}")
            for c in $containers; do
                echo -e "正在处理: ${GREEN}$c${NC} ..."
                
                # 获取命令
                local cmd=$(get_clean_cmd "$c")
                
                if [ -n "$cmd" ]; then
                    # 写入文件 (追加模式)
                    echo "" >> "$output_file"
                    echo "### Container: $c ###" >> "$output_file"
                    echo "$cmd" >> "$output_file"
                    echo "" >> "$output_file" # 空行分隔
                else
                    echo -e "${RED}[WARN] 获取 $c 失败${NC}"
                    echo "# [ERROR] Failed to get command for $c" >> "$output_file"
                fi
            done
            
            echo -e "\n${GREEN}[SUCCESS] 导出完成！${NC}"
            echo -e "文件已保存至: ${YELLOW}$output_file${NC}"
            echo -e "您可以使用 'cat $output_file' 查看内容。"
            
            read -p "按任意键继续..."
        else
            # 单个容器还是直接显示在屏幕上
            generate_command_screen "$input_name"
        fi
    done
}