#!/bin/bash
function module_docker_image_tool() {
    SCRIPT_DIR="$(pwd)"
    BACKUP_DIR="$SCRIPT_DIR/docker-image"
    mkdir -p "$BACKUP_DIR"

    if command -v pigz >/dev/null 2>&1; then
        ZIP_CMD="pigz"
        UNZIP_CMD="unpigz"
        echo -e "${GREEN}⚡ 检测到 pigz，已启用多线程加速模式！${NC}"
    else
        ZIP_CMD="gzip"
        UNZIP_CMD="gunzip"
        echo -e "${YELLOW}提示: 未检测到 pigz，使用单线程 gzip (速度较慢)。${NC}"
        echo -e "建议执行 ${GREEN}apt install pigz${NC} 以大幅提升速度。"
    fi

    HAS_PV=false
    if command -v pv >/dev/null 2>&1; then HAS_PV=true; else echo "⚠️ 提示: 未检测到 pv 工具，将不显示进度条"; fi

    trap 'echo -e "\n❌ 操作被中断..."; return 1' SIGINT

    backup_images() {
        echo ">>> 正在扫描镜像..."
        mapfile -t IMAGE_LIST < <(docker images --format "{{.Repository}}:{{.Tag}}|{{.ID}}|{{.Size}}|{{.CreatedAt}}" | grep -v "<none>" | sort -t "|" -k4,4r)

        if [ ${#IMAGE_LIST[@]} -eq 0 ]; then echo "❌ 未找到任何有效镜像。"; return; fi

        echo "No  镜像名称                           大小       创建时间"
        echo "------------------------------------------------------------------"
        IMAGES=(); INDEX=1
        for LINE in "${IMAGE_LIST[@]}"; do
            IFS='|' read -r NAME ID SIZE CREATED <<< "$LINE"
            printf "%2d) %-35s %-10s %-20s\n" "$INDEX" "${NAME:0:34}" "$SIZE" "${CREATED:0:19}"
            IMAGES+=("$NAME"); ((INDEX++))
        done
        echo "----------------------------------------"
        read -p "请输入备份编号 (空格分隔, 或 all): " SELECTION
        if [ -z "$SELECTION" ]; then return; fi

        SELECTED_IMAGES=()
        if [ "$SELECTION" == "all" ]; then SELECTED_IMAGES=("${IMAGES[@]}"); else
            for NUM in $SELECTION; do
                if [[ "$NUM" =~ ^[0-9]+$ ]] && [ "$NUM" -ge 1 ] && [ "$NUM" -le ${#IMAGES[@]} ]; then
                    SELECTED_IMAGES+=("${IMAGES[$((NUM-1))]}")
                fi
            done
        fi

        for IMAGE_NAME in "${SELECTED_IMAGES[@]}"; do
            SAFE_NAME=$(echo "$IMAGE_NAME" | tr '/:' '_')
            CURRENT_FILE="$BACKUP_DIR/${SAFE_NAME}.tar.gz"
            echo ">>> 正在备份: $IMAGE_NAME"
            
            if [ "$HAS_PV" = true ]; then
                RAW_SIZE=$(docker image inspect "$IMAGE_NAME" --format='{{.Size}}' 2>/dev/null || echo 0)
                docker save "$IMAGE_NAME" | pv -s "$RAW_SIZE" -N "Compressing" | $ZIP_CMD > "$CURRENT_FILE"
            else
                docker save "$IMAGE_NAME" | $ZIP_CMD > "$CURRENT_FILE"
            fi
            echo -e "✅ 备份成功: $CURRENT_FILE"
        done
    }

    restore_images() {
        echo ">>> 扫描目录: $BACKUP_DIR"
        shopt -s nullglob; FILES=("$BACKUP_DIR"/*.tar "$BACKUP_DIR"/*.tar.gz); shopt -u nullglob
        if [ ${#FILES[@]} -eq 0 ]; then echo "⚠️ 目录为空"; return; fi
        
        mapfile -t FILES < <(ls -1t "$BACKUP_DIR"/*.tar "$BACKUP_DIR"/*.tar.gz 2>/dev/null)
        INDEX=1
        echo "No  文件名"
        echo "----------------------------------------"
        for FILE in "${FILES[@]}"; do
            printf "%2d) %s\n" "$INDEX" "$(basename "$FILE")"
            ((INDEX++))
        done
        read -p "请输入恢复编号 (空格分隔, 或 all): " SELECTION
        if [ -z "$SELECTION" ]; then return; fi

        SELECTED_FILES=()
        if [ "$SELECTION" == "all" ]; then SELECTED_FILES=("${FILES[@]}"); else
            for NUM in $SELECTION; do
                if [[ "$NUM" =~ ^[0-9]+$ ]] && [ "$NUM" -ge 1 ] && [ "$NUM" -le ${#FILES[@]} ]; then
                    SELECTED_FILES+=("${FILES[$((NUM-1))]}")
                fi
            done
        fi

        for FILE in "${SELECTED_FILES[@]}"; do
            echo ">>> 正在恢复: $(basename "$FILE")"
            FILE_SIZE=$(stat -c%s "$FILE")
            
            if [[ "$FILE" == *.gz ]]; then
                if [ "$HAS_PV" = true ]; then
                    pv -s "$FILE_SIZE" -N "Decompressing" "$FILE" | $UNZIP_CMD | docker load
                else
                    $UNZIP_CMD -c "$FILE" | docker load
                fi
            else
                if [ "$HAS_PV" = true ]; then
                    pv -s "$FILE_SIZE" -N "Loading" "$FILE" | docker load
                else
                    docker load -i "$FILE"
                fi
            fi
        done
    }

    while true; do
        echo -e "\n=== Docker 镜像工具 (存放: $BACKUP_DIR) ==="
        echo "1) 备份镜像"
        echo "2) 恢复镜像"
        echo "3) 返回主菜单"
        read -p "请选择: " CHOICE
        case $CHOICE in
            1) backup_images ;;
            2) restore_images ;;
            3) trap - SIGINT; break ;;
            *) echo "输入无效" ;;
        esac
    done
}
