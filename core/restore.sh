#!/bin/bash

function module_restore_smart() {
    
    # === [增强版] 自动安装 yq 工具 ===
    ensure_yq() {
        # 1. 检测是否已安装且可用
        if command -v yq &> /dev/null && yq --version &> /dev/null; then
            return 0
        fi

        echo -e "${YELLOW}>>> 检测到未安装 yq 或文件损坏，正在下载解析器...${NC}"
        
        # 2. 清理可能损坏的旧文件
        rm -f /usr/local/bin/yq

        # 3. 架构检测
        local arch=""
        case $(uname -m) in
            x86_64) arch="amd64" ;;
            aarch64) arch="arm64" ;;
            armv7l) arch="arm" ;;
            *) echo -e "${RED}不支持的架构: $(uname -m)${NC}"; return 1 ;;
        esac
        
        local FILE_NAME="yq_linux_${arch}"
        
        # 4. 定义下载源列表 (优先镜像，失败自动切官方)
        local URL_LIST=(
            "https://github.8725206.xyz:16666/https://github.com/mikefarah/yq/releases/latest/download/${FILE_NAME}"
            "https://ghproxy.com/https://github.com/mikefarah/yq/releases/latest/download/${FILE_NAME}"
            "https://github.com/mikefarah/yq/releases/latest/download/${FILE_NAME}"
        )

        for url in "${URL_LIST[@]}"; do
            echo -e "尝试下载: ${BLUE}$url${NC}"
            # -L: 跟随重定向, -f: HTTP错误时不写入文件
            curl -L -f "$url" -o /usr/local/bin/yq
            
            if [ -f "/usr/local/bin/yq" ]; then
                chmod +x /usr/local/bin/yq
                # 5. 下载后立即验证
                if /usr/local/bin/yq --version &> /dev/null; then
                    echo -e "${GREEN}✅ yq 安装/修复成功！${NC}"
                    return 0
                else
                    echo -e "${RED}⚠️ 下载的文件无法运行，尝试下一个源...${NC}"
                    rm -f /usr/local/bin/yq
                fi
            else
                echo -e "${YELLOW}下载失败 (HTTP Error)，尝试下一个源...${NC}"
            fi
        done

        echo -e "${RED}❌ 所有源均下载失败，请检查网络连接。${NC}"
        return 1
    }

    echo -e "${BLUE}=== 智能恢复模式 (Smart Restore v3) ===${NC}"
    
    # 调用增强版安装函数
    ensure_yq || return 1

    echo "请输入备份文件(.tar.gz) 的绝对路径。"
    read -e -p "路径: " BACKUP_FILE

    if [ -z "$BACKUP_FILE" ]; then echo -e "${RED}❌ 未输入路径${NC}"; return 1; fi
    if [ ! -f "$BACKUP_FILE" ]; then echo -e "${RED}❌ 找不到文件 $BACKUP_FILE${NC}"; return 1; fi

    echo -e "${BLUE}>>> 正在扫描备份包结构...${NC}"
    ANALYSIS_DIR="/tmp/restore_analysis_$(date +%s)"
    mkdir -p "$ANALYSIS_DIR"
    
    # 精确查找 yml 路径
    TARGET_YML_PATH=$(tar -tf "$BACKUP_FILE" 2>/dev/null | grep "docker-compose.yml" | head -n 1)

    if [ -z "$TARGET_YML_PATH" ]; then
        echo -e "${RED}❌ 分析失败：备份包内未找到 docker-compose.yml 文件！${NC}"
        echo "请检查压缩包是否损坏或格式不正确。"
        rm -rf "$ANALYSIS_DIR"
        return 1
    else
        echo -e "已定位配置文件: ${GREEN}$TARGET_YML_PATH${NC}"
    fi

    # 解压配置文件用于分析
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

    # 自动权限修复逻辑
    echo -e "${BLUE}>>> 正在自动修复文件权限...${NC}"
    if [ -d "/data/docker" ]; then
        chown -R 1000:1000 /data/docker
        echo -e "${GREEN}✅ 已自动将 /data/docker 权限修正为 User:1000${NC}"
    fi

    echo -e "\n${YELLOW}[3/4] 准备配置...${NC}"
    
    mkdir -p /root/docker_manage
    # 提取配置文件
    tar -xf "$BACKUP_FILE" -C /root/docker_manage "$TARGET_YML_PATH" --strip-components=$(($(echo "$TARGET_YML_PATH" | grep -o "/" | wc -l))) 2>/dev/null
    
    # 容错处理
    if [ ! -f "/root/docker_manage/docker-compose.yml" ]; then
         RESTORED_YML=$(find /tmp -name "docker-compose.yml" | grep "docker_backup_work" | head -n 1)
         if [ -f "$RESTORED_YML" ]; then
             cp "$(dirname "$RESTORED_YML")"/.env /root/docker_manage/.env 2>/dev/null
             cp "$RESTORED_YML" /root/docker_manage/docker-compose.yml
         fi
    fi
    
    if [ -f "/root/docker_manage/docker-compose.yml" ]; then
        cd /root/docker_manage
        # 清理 external 网络标记
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