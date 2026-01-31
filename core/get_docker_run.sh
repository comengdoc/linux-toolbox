#!/bin/bash
# 模块名称: Docker Run 命令导出工具
# 适配: main.sh v3.9+ (通过 run_safe 调用)

function docker_run_export() {
    # --- 1. 定义局部颜色 (避免污染全局) ---
    local GREEN='\033[0;32m'
    local BLUE='\033[0;34m'
    local RED='\033[0;31m'
    local NC='\033[0m'

    # --- 2. 内部函数定义 ---
    
    # 检查并构建镜像 (使用 local function 或直接定义)
    check_and_build_image() {
        # 使用单方括号 [ ] 以兼容更多 Shell 环境
        if [ -z "$(docker images -q runlike 2> /dev/null)" ]; then
            echo -e "${BLUE}[INFO] 未检测到 runlike 镜像，正在为您自动构建 (适配本机架构)...${NC}"
            
            # 动态生成 Dockerfile
            cat > Dockerfile.temp <<EOF
FROM python:3-alpine
RUN apk add --no-cache docker-cli
RUN python3 -m venv /app/venv
ENV PATH="/app/venv/bin:\$PATH"
RUN pip3 install runlike
ENTRYPOINT ["runlike"]
EOF

            # 构建镜像
            docker build -t runlike -f Dockerfile.temp .
            local build_status=$?
            rm Dockerfile.temp

            if [ $build_status -eq 0 ]; then
                echo -e "${GREEN}[SUCCESS] 镜像构建成功！${NC}"
            else
                echo -e "${RED}[ERROR] 镜像构建失败，请检查网络或 Docker 环境。${NC}"
                return 1
            fi
        else
            # 只有在需要调试时才显示这句，保持界面清爽
            # echo -e "${GREEN}[INFO] 镜像已就绪。${NC}"
            : 
        fi
    }

    generate_command() {
        local container_name=$1
        echo -e "\n${BLUE}====================================================${NC}"
        echo -e "${BLUE}容器名称: ${GREEN}$container_name${NC}"
        echo -e "${BLUE}====================================================${NC}"
        
        local cmd=$(docker run --rm -v /var/run/docker.sock:/var/run/docker.sock runlike -p "$container_name" 2>/dev/null)
        
        if [ -z "$cmd" ]; then
            echo -e "${RED}[ERROR] 无法获取信息，请确认容器名正确且正在运行。${NC}"
        else
            # 过滤杂讯
            echo "$cmd" | grep -vE 'com.docker.compose|--label|--hostname|--runtime|--workdir'
        fi
        echo "" 
    }

    # --- 3. 主逻辑执行 ---

    echo -e "${BLUE}=== Docker 启动命令反推工具 ===${NC}"

    # 执行检查，如果失败则返回主菜单
    check_and_build_image
    if [ $? -ne 0 ]; then return 1; fi

    # 列出容器
    echo -e "\n${BLUE}--- 当前正在运行的容器 ---${NC}"
    docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}"
    echo -e "${BLUE}---------------------------${NC}"

    # 交互循环
    while true; do
        echo -e "\n请输入容器名称 (直接回车返回主菜单，输入 ${GREEN}all${NC} 导出所有): "
        read -p "> " input_name

        if [ -z "$input_name" ]; then
            echo "正在返回主菜单..."
            break # 这里的 break 会跳出 while 循环，函数随之结束，返回 main.sh
        fi

        if [ "$input_name" == "all" ]; then
            local containers=$(docker ps --format "{{.Names}}")
            for c in $containers; do
                generate_command "$c"
            done
            # 全量导出后暂停一下，方便用户查看
            read -p "按任意键继续..."
        else
            generate_command "$input_name"
        fi
    done
}