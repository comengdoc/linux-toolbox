#!/bin/bash
function module_restore_smart() {
    ensure_yq() {
        if ! command -v yq &> /dev/null; then
            echo -e "${YELLOW}>>> 检测到未安装 yq，正在下载轻量级解析器...${NC}"
            local arch=""
            case $(uname -m) in
                x86_64) arch="amd64" ;;
                aarch64) arch="arm64" ;;
                armv7l) arch="arm" ;;
                *) echo -e "${RED}不支持的架构${NC}"; return 1 ;;
            esac
            
            local TARGET_URL="https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${arch}"
            echo -e "下载源: ${BLUE}${GH_PROXY}${TARGET_URL}${NC}"
            
            curl -L "${GH_PROXY}${TARGET_URL}" -o /usr/local/bin/yq
            chmod +x /usr/local/bin/yq
            
            if command -v yq &> /dev/null; then
                echo -e "${GREEN}✅ yq 安装完成${NC}"
            else
                echo -e "${RED}❌ yq 安装失败，请检查网络。${NC}"
                return 1
            fi
        fi
    }

    echo -e "${BLUE}=== 智能恢复模式 (Smart Restore v3) ===${NC}"
    ensure_yq || return 1

    echo "请输入备份文件(.tar.gz) 的绝对路径。"
    read -e -p "路径: " BACKUP_FILE

    if [ -z "$BACKUP_FILE" ]; then echo -e "${RED}❌ 未输入路径${NC}"; return 1; fi
    if [ ! -f "$BACKUP_FILE" ]; then echo -e "${RED}❌ 找不到文件 $BACKUP_FILE${NC}"; return 1; fi

    echo -e "${BLUE}>>> 正在扫描备份包结构...${NC}"
    ANALYSIS_DIR="/tmp/restore_analysis_$(date +%s)"
    mkdir -p "$ANALYSIS_DIR"
    
    # [修复 1] 不使用通配符，而是先列出文件表，精确查找 yml 路径
    # tar -tf 列出内容，grep 找文件，head 取第一个匹配项
    TARGET_YML_PATH=$(tar -tf "$BACKUP_FILE" 2>/dev/null | grep "docker-compose.yml" | head -n 1)

    if [ -z "$TARGET_YML_PATH" ]; then
        echo -e "${RED}❌ 分析失败：备份包内未找到 docker-compose.yml 文件！${NC}"
        echo "请检查压缩包是否损坏或格式不正确。"
        rm -rf "$ANALYSIS_DIR"
        return 1
    else
        echo -e "已定位配置文件: ${GREEN}$TARGET_YML_PATH${NC}"
    fi

    # [修复 2] 精准解压该文件 (使用 -xf 自动识别压缩格式)
    tar -xf "$BACKUP_FILE" -C "$ANALYSIS_DIR" "$TARGET_YML_PATH" 2>/dev/null
    
    # 重新定位解压后的本地文件路径
    YML_FILE=$(find "$ANALYSIS_DIR" -name "docker-compose.yml" | head -n 1)

    if [ -z "$YML_FILE" ]; then
        echo -e "${RED}❌ 解压失败，无法读取配置文件。${NC}"
        rm -rf "$ANALYSIS_DIR"; return 1
    fi

    SERVICE_LIST=($(yq '.services | keys | .[]' "$YML_FILE"))
    
    if [ ${#SERVICE_LIST[@]} -eq 0 ]; then
        echo -e "${RED}❌ 解析失败：未找到服务列表或格式错误。${NC}"
        rm -rf "$ANALYSIS_DIR"; return 1
    fi

    echo -e "备份包含容器: "
    i=1
    for service in "${SERVICE_LIST[@]}"; do
        echo -e "  [${GREEN}$i${NC}] $service"
        let i++
    done

    echo -e "${YELLOW}模式选择：${NC}"
    echo "1) 🚀 恢复【全部】容器 (硬重置：清空旧环境)"
    echo "2) 🎯 恢复【指定】容器 (软覆盖：不删旧环境)"
    echo "3) 📂 仅解压数据 (不启动)"
    read -p "请选择 [1-3]: " MODE_OPT

    TARGET_SERVICES=""; CLEAN_ENV=false; DO_START=true

    case "$MODE_OPT" in
        1) CLEAN_ENV=true; TARGET_SERVICES="" ;;
        2)
            read -p "输入编号 (空格分隔, 或 all): " SELECTED_IDXS
            if [[ "$SELECTED_IDXS" == "all" || "$SELECTED_IDXS" == "a" ]]; then
                TARGET_SERVICES=""
            else
                for idx in $SELECTED_IDXS; do
                    real_idx=$((idx-1))
                    if [ $real_idx -ge 0 ] && [ $real_idx -lt ${#SERVICE_LIST[@]} ]; then
                        TARGET_SERVICES="$TARGET_SERVICES ${SERVICE_LIST[$real_idx]}"
                    fi
                done
                if [ -z "$TARGET_SERVICES" ]; then echo "未选择容器"; rm -rf "$ANALYSIS_DIR"; return 1; fi
            fi
            ;;
        3) DO_START=false ;;
        *) echo "无效选项"; rm -rf "$ANALYSIS_DIR"; return 1 ;;
    esac
    rm -rf "$ANALYSIS_DIR"

    if [ "$CLEAN_ENV" = true ]; then
        echo -e "\n${YELLOW}[1/4] 清理旧环境...${NC}"
        docker rm -f $(docker ps -aq) 2>/dev/null
        docker network prune -f 2>/dev/null
    fi

    echo -e "\n${YELLOW}[2/4] 解压数据...${NC}"
    # 解压所有文件到根目录
    tar -xf "$BACKUP_FILE" -C /

    # [修复 3] 自动权限修复逻辑 (这里就是你想要的自动化)
    echo -e "${BLUE}>>> 正在自动修复文件权限...${NC}"
    if [ -d "/data/docker" ]; then
        # 强制将 /data/docker 及其子目录的所有者改为 1000:1000
        # 1000 是绝大多数非 Root 容器 (如 openlist, lucky) 的默认用户 ID
        chown -R 1000:1000 /data/docker
        echo -e "${GREEN}✅ 已自动将 /data/docker 权限修正为 User:1000${NC}"
    fi

    echo -e "\n${YELLOW}[3/4] 准备配置...${NC}"
    # 重新在包里找一次 yml 路径用于覆盖系统配置
    # 注意：之前解压到了 /tmp/analysis 只是为了看，现在解压到了 / (根目录) 才是真的恢复
    # 我们直接去解压后的临时目录找，或者尝试从备份包里提取到 /root/docker_manage
    
    mkdir -p /root/docker_manage
    # 再次提取配置文件到目标目录
    tar -xf "$BACKUP_FILE" -C /root/docker_manage "$TARGET_YML_PATH" --strip-components=$(($(echo "$TARGET_YML_PATH" | grep -o "/" | wc -l))) 2>/dev/null
    # 如果 strip 失败，尝试粗暴复制
    if [ ! -f "/root/docker_manage/docker-compose.yml" ]; then
         # 尝试从刚才全量解压的路径找 (通常在 /tmp/docker_backup_work_xxxxx/...)
         RESTORED_YML=$(find /tmp -name "docker-compose.yml" | grep "docker_backup_work" | head -n 1)
         if [ -f "$RESTORED_YML" ]; then
             cp "$(dirname "$RESTORED_YML")"/.env /root/docker_manage/.env 2>/dev/null
             cp "$RESTORED_YML" /root/docker_manage/docker-compose.yml
         fi
    fi
    
    if [ -f "/root/docker_manage/docker-compose.yml" ]; then
        cd /root/docker_manage
        # 清理 external 网络标记防止报错
        sed -i '/external: true/d' docker-compose.yml; sed -i '/external:/d' docker-compose.yml 
    else
        echo -e "${RED}❌ 警告：配置文件恢复位置异常，但数据已解压。${NC}"
        echo "请手动检查 /tmp 下是否有 docker-compose.yml"
    fi

    if [ "$DO_START" = true ]; then
        echo -e "\n${YELLOW}[4/4] 启动容器...${NC}"
        if [ -z "$TARGET_SERVICES" ]; then CMD="docker compose up -d"; else CMD="docker compose up -d --force-recreate $TARGET_SERVICES"; fi
        if $CMD; then
            echo -e "${GREEN}🎉 恢复完成！权限已自动修正。${NC}"
            docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
        else
            echo -e "${RED}❌ 启动失败。请检查 docker compose 日志。${NC}"
        fi
    else
        echo -e "${GREEN}✅ 数据已解压并修复权限，未启动。${NC}"
    fi
    # 清理临时文件
    rm -rf /tmp/docker_backup_work_*
}
