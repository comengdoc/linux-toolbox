#!/bin/bash
function module_clean_docker() {
    echo -e "${RED}⚠️  警告：Docker 清理工具${NC}"
    echo "此功能将删除容器、网络，并可选删除镜像。"
    echo "----------------------------------------"
    echo "1) 🔍 模拟运行 (Dry-Run) - 仅列出将要删除的内容"
    echo "2) 💣 执行清理 (Execute) - 真的动手删除"
    echo "0) 返回主菜单"
    
    # [修复] 增加 < /dev/tty
    read -p "请选择模式 [1/2/0]: " MODE < /dev/tty

    if [ "$MODE" == "0" ]; then return; fi

    echo ">>> 正在扫描 Docker 资源..."
    CONTAINERS=$(docker ps -aq)
    VOLUMES=$(docker volume ls -qf dangling=true)
    NETWORKS=$(docker network ls --format "{{.Name}}" | grep -vE "^(bridge|host|none)$")

    if [ "$MODE" == "1" ]; then
        echo -e "\n${BLUE}=== [模拟] 即将删除的资源列表 ===${NC}"
        
        echo -e "${YELLOW}[容器]${NC}"
        if [ -n "$CONTAINERS" ]; then
            docker ps -a --format "table {{.ID}}\t{{.Names}}\t{{.Status}}"
        else
            echo "无容器。"
        fi

        echo -e "\n${YELLOW}[网络]${NC}"
        if [ -n "$NETWORKS" ]; then echo "$NETWORKS"; else echo "无自定义网络。"; fi

        echo -e "\n${YELLOW}[数据卷 (仅清理无主卷)]${NC}"
        if [ -n "$VOLUMES" ]; then echo "$VOLUMES"; else echo "无悬空卷。"; fi
        
        echo -e "\n${GREEN}模拟结束，未执行任何删除操作。${NC}"
        return
    fi

    if [ "$MODE" == "2" ]; then
        echo -e "${RED}!!! 最终确认 !!!${NC}"
        
        # [修复] 增加 < /dev/tty
        # [优化] 增加0退出
        read -p "输入 'yes' 确认立即清理 (输入 0 返回): " CONFIRM < /dev/tty
        if [ "$CONFIRM" == "0" ]; then return; fi
        if [ "$CONFIRM" != "yes" ]; then echo "操作取消。"; return; fi

        # [修复] 增加 < /dev/tty
        read -p "是否同时删除所有镜像？(y/n) [n]: " DEL_IMAGES < /dev/tty

        echo -e "\n${YELLOW}>>> 1. 删除容器...${NC}"
        if [ -n "$CONTAINERS" ]; then
            docker stop $CONTAINERS >/dev/null 2>&1
            docker rm $CONTAINERS
        else
            echo "跳过 (无容器)"
        fi

        echo -e "${YELLOW}>>> 2. 清理网络...${NC}"
        docker network prune -f >/dev/null 2>&1

        echo -e "${YELLOW}>>> 3. 清理数据卷...${NC}"
        docker volume prune -f >/dev/null 2>&1

        if [[ "$DEL_IMAGES" == "y" ]]; then
            echo -e "${YELLOW}>>> 4. 删除所有镜像...${NC}"
            docker rmi -f $(docker images -q) >/dev/null 2>&1
            echo "镜像已清空。"
        else
            echo -e "${YELLOW}>>> 4. 清理悬空镜像 (Dangling)...${NC}"
            docker image prune -f >/dev/null 2>&1
        fi

        echo -e "${GREEN}✅ 清理完成。${NC}"
        echo -e "当前磁盘空间占用:"
        docker system df
    fi
}