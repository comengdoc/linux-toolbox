#!/bin/bash
function module_mount_cleaner() {
    # 1. [绝对禁止] 删除的系统关键路径 (包含其子目录)
    local CRITICAL_SYS_DIRS=(
        "/" "/boot" "/dev" "/proc" "/sys" "/bin" "/sbin" "/usr" "/lib" "/lib64" 
        "/run" "/var/run" "/var/lib/docker"
    )

    # 2. [保护本身] 但允许删除子目录的路径
    local PROTECTED_ROOTS=(
        "/root" "/home" "/opt" "/etc" "/var" "/mnt" "/media" "/tmp"
    )

    clear
    echo -e "${RED}====================================================${NC}"
    echo -e "${RED}   ☢️  Docker 挂载数据清理工具 (增强安全版) ☢️${NC}"
    echo -e "${RED}====================================================${NC}"
    echo -e "${YELLOW}功能：扫描容器挂载的 Bind Mounts 并清理宿主机文件。${NC}"
    echo -e "${YELLOW}安全机制：自动忽略 .sock 文件及系统关键目录。${NC}"
    echo
    echo "1) 开始扫描"
    echo "0) 返回主菜单"
    
    # [新增] 增加 0 返回选项
    read -p "请选择: " START_OPT < /dev/tty
    if [[ "$START_OPT" == "0" ]]; then return; fi

    if ! docker info > /dev/null 2>&1; then
        echo -e "${RED}错误：无法连接到 Docker 守护进程。${NC}"
        return 1
    fi

    echo -e "${BLUE}>>> 正在扫描所有容器的挂载点...${NC}"
    
    TEMP_LIST="/tmp/docker_mounts_delete.list"
    SKIP_LOG="/tmp/docker_mounts_skip.log"
    > "$TEMP_LIST"
    > "$SKIP_LOG"

    CONTAINERS=$(docker ps -aq)
    if [ -z "$CONTAINERS" ]; then
        echo -e "${GREEN}未发现任何容器。${NC}"; return
    fi

    for container in $CONTAINERS; do
        NAME=$(docker inspect --format '{{.Name}}' "$container" | sed 's/\///')
        MOUNTS=$(docker inspect --format '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}{{println}}{{end}}{{end}}' "$container")
        
        if [ -n "$MOUNTS" ]; then
            echo "$MOUNTS" | while read -r path; do
                if [ -z "$path" ]; then continue; fi

                SHOULD_SKIP=0
                SKIP_REASON=""

                if [[ "$path" == *".sock" ]]; then
                    SHOULD_SKIP=1
                    SKIP_REASON="Socket 通信文件"
                fi

                if [ $SHOULD_SKIP -eq 0 ]; then
                    for sys_dir in "${CRITICAL_SYS_DIRS[@]}"; do
                        if [[ "$path" == "$sys_dir" ]] || [[ "$path" == "$sys_dir/"* ]]; then
                            SHOULD_SKIP=1
                            SKIP_REASON="系统关键路径 ($sys_dir)"
                            break
                        fi
                    done
                fi

                if [ $SHOULD_SKIP -eq 0 ]; then
                    for root_dir in "${PROTECTED_ROOTS[@]}"; do
                        clean_path=${path%/}
                        clean_root=${root_dir%/}
                        if [[ "$clean_path" == "$clean_root" ]]; then
                            SHOULD_SKIP=1
                            SKIP_REASON="受保护的根目录 (仅允许删子文件夹)"
                            break
                        fi
                    done
                fi

                if [ $SHOULD_SKIP -eq 1 ]; then
                    echo "[$NAME] $path ($SKIP_REASON)" >> "$SKIP_LOG"
                else
                    echo "$path|$NAME" >> "$TEMP_LIST"
                fi
            done
        fi
    done

    if [ -s "$SKIP_LOG" ]; then
        echo -e "\n${CYAN}=== 🛡️  已自动安全跳过 (不会删除) ===${NC}"
        cat "$SKIP_LOG" | awk '{printf "  %-30s %s\n", $1, $2 " " $3}'
    fi

    if [ ! -s "$TEMP_LIST" ]; then
        echo -e "\n${GREEN}✅ 扫描完成：没有发现需要清理的数据目录。${NC}"
        rm -f "$TEMP_LIST" "$SKIP_LOG"
        return
    fi

    echo -e "\n${RED}=== 🗑️  以下目录/文件将被永久删除 ===${NC}"
    echo "--------------------------------------------------------"
    printf "%-45s %-20s\n" "宿主机路径" "来源容器"
    echo "--------------------------------------------------------"
    sort -u "$TEMP_LIST" | while IFS='|' read -r path name; do
        if [ -e "$path" ]; then
            printf "${RED}%-45s${NC} %-20s\n" "$path" "$name"
        else
            printf "${YELLOW}%-45s${NC} %-20s (已不存在)\n" "$path" "$name"
        fi
    done
    echo "--------------------------------------------------------"

    echo -e "\n${RED}!!! 最终确认 !!!${NC}"
    echo "上述 ${RED}红色路径${NC} 内的所有数据将丢失且无法恢复。"
    echo -e "若要继续，请输入大写的 ${RED}DELETE${NC} (输入 0 或其他内容取消):"
    
    # [修复] 增加 < /dev/tty
    read -p "请输入: " CONFIRM < /dev/tty

    if [ "$CONFIRM" == "DELETE" ]; then
        echo -e "\n${BLUE}>>> 开始执行清理...${NC}"
        awk -F'|' '{print $1}' "$TEMP_LIST" | sort -u | while read -r target; do
            if [ -e "$target" ]; then
                echo -e "正在删除: $target"
                rm -rf "$target"
            fi
        done
        echo -e "${GREEN}✅ 清理完成！${NC}"
    else
        echo -e "${GREEN}❌ 操作已取消，未删除任何文件。${NC}"
    fi

    rm -f "$TEMP_LIST" "$SKIP_LOG"
}