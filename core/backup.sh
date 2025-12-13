#!/bin/bash
function module_backup() {
    BACKUP_DIR="/root/backup_archive"
    # [修复] 临时目录改在 /root 下，防止被 exclude 规则误杀
    TEMP_YML_DIR="/root/.docker_backup_temp"
    DATE=$(date +%Y%m%d_%H%M%S)
    
    # 定义排除规则 (保持瘦身效果)
    IGNORE_PATHS=("/mnt/media" "/mnt/sda1" "/tmp" "/var/lib/docker")
    EXCLUDE_RULES=(
        "--exclude=*.so" "--exclude=*.dll" "--exclude=*.log"
        "--exclude=*/cache/*" "--exclude=*/logs/*" "--exclude=*/tmp/*"
        "--exclude=*.tar" "--exclude=*.gz" "--exclude=*.iso"
    )

    if ! command -v docker &> /dev/null; then echo "❌ 未安装 Docker"; return 1; fi
    mkdir -p "$BACKUP_DIR" "$TEMP_YML_DIR"

    # 检查 pigz
    if ! command -v pigz &> /dev/null; then
        echo -e "${YELLOW}>>> 尝试安装 pigz...${NC}"
        apt-get update -qq && apt-get install -y -qq pigz
    fi

    # 选择容器
    RAW_LIST=$(docker ps -a --format "{{.ID}}|{{.Names}}" | grep -v "docker-autocompose")
    if [ -z "$RAW_LIST" ]; then echo "❌ 无容器"; return 1; fi

    echo "📋 可备份容器："
    declare -a TARGET_IDS; declare -a TARGET_NAMES; INDEX=1
    while IFS='|' read -r cid cname; do
        echo "   [$INDEX] $cname"
        TARGET_IDS[$INDEX]=$cid; TARGET_NAMES[$INDEX]=$cname; ((INDEX++))
    done <<< "$RAW_LIST"
    
    # 【核心修复】增加 < /dev/tty 防止跳过
    read -p "输入编号 (空格分隔, 回车全选): " USER_CHOICE < /dev/tty
    
    if [[ -z "$USER_CHOICE" ]]; then
        CONTAINERS=$(docker ps -aq); ARCHIVE_NAME="backup_SLIM_${DATE}.tar.gz"
    else
        SELECTED_IDS=""
        for num in $USER_CHOICE; do SELECTED_IDS+="${TARGET_IDS[$num]} "; done
        CONTAINERS=$SELECTED_IDS; ARCHIVE_NAME="backup_Custom_SLIM_${DATE}.tar.gz"
    fi

    echo ">>> 生成配置文件..."
    # 拉取工具
    if [[ "$(docker images -q ghcr.io/red5d/docker-autocompose 2> /dev/null)" == "" ]]; then 
        docker pull ghcr.io/red5d/docker-autocompose
    fi
    
    # [修复] 生成到非 tmp 目录
    docker run --rm -v /var/run/docker.sock:/var/run/docker.sock ghcr.io/red5d/docker-autocompose $CONTAINERS > "$TEMP_YML_DIR/docker-compose.yml"

    # 修正特权容器参数
    for tool in "wg-easy" "tailscale"; do
        if grep -q "$tool" "$TEMP_YML_DIR/docker-compose.yml"; then
            sed -i "/image: .*$tool/a \    cap_add:\n      - NET_ADMIN\n      - SYS_MODULE" "$TEMP_YML_DIR/docker-compose.yml"
        fi
    done

    echo ">>> 扫描挂载数据..."
    # [修复] 这里的 BACKUP_PATHS 只放数据目录
    BACKUP_PATHS=() 
    RAW_MOUNTS=$(docker inspect --format='{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}{{println}}{{end}}{{end}}' $CONTAINERS | sort | uniq | grep -vE "^/var/run|^/sys|^/proc|^/dev")
    
    while IFS= read -r mount_path; do
        [ -z "$mount_path" ] && continue
        SKIP=0
        for ignore in "${IGNORE_PATHS[@]}"; do if [[ "$mount_path" == "$ignore"* ]]; then SKIP=1; break; fi; done
        if [ $SKIP -eq 0 ] && [ -e "$mount_path" ]; then 
            # 移除开头的 / 以防止 tar 警告
            BACKUP_PATHS+=("$mount_path")
        fi
    done <<< "$RAW_MOUNTS"

    echo -e "${YELLOW}>>> 停止容器...${NC}"
    docker stop $CONTAINERS > /dev/null
    
    echo ">>> 开始打包 (结构优化版)..."
    
    if command -v pigz >/dev/null; then
        tar "${EXCLUDE_RULES[@]}" --use-compress-program=pigz \
            -cvf "$BACKUP_DIR/$ARCHIVE_NAME" \
            -C "$TEMP_YML_DIR" docker-compose.yml \
            -C / "${BACKUP_PATHS[@]}" 2>/dev/null
    else
        tar "${EXCLUDE_RULES[@]}" -czvf "$BACKUP_DIR/$ARCHIVE_NAME" \
            -C "$TEMP_YML_DIR" docker-compose.yml \
            -C / "${BACKUP_PATHS[@]}" 2>/dev/null
    fi
    
    echo ">>> 恢复容器..."
    docker start $CONTAINERS > /dev/null
    
    # 清理临时文件
    rm -rf "$TEMP_YML_DIR"
    
    if [ -f "$BACKUP_DIR/$ARCHIVE_NAME" ]; then
        echo -e "${GREEN}✅ 备份成功！${NC}"
        echo -e "文件: ${GREEN}$BACKUP_DIR/$ARCHIVE_NAME${NC}"
        echo -e "大小: $(du -h "$BACKUP_DIR/$ARCHIVE_NAME" | awk '{print $1}')"
    else
        echo -e "${RED}❌ 备份失败，未生成文件。${NC}"
    fi
}