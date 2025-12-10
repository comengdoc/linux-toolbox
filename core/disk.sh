#!/bin/bash
function module_disk_manager() {
    # 增强版依赖检查
    check_dependency() {
        if ! command -v parted &> /dev/null; then
            echo -e "${YELLOW}提示：未找到 parted 工具，正在尝试自动安装...${NC}"
            if command -v apt-get &> /dev/null; then
                apt-get update && apt-get install -y parted
            elif command -v yum &> /dev/null; then
                yum install -y parted
            elif command -v dnf &> /dev/null; then
                dnf install -y parted
            elif command -v pacman &> /dev/null; then
                pacman -Sy --noconfirm parted
            elif command -v apk &> /dev/null; then
                apk add parted
            else
                echo -e "${RED}错误：无法自动安装 parted。请手动安装后重试。${NC}"
                return 1
            fi
        fi
    }
    check_dependency || return 1

    # 辅助函数：安全备份并写入 fstab
    backup_fstab() {
        cp /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"
        echo "已备份原 fstab 文件。"
    }

    while true; do
        echo -e "\n========================================"
        echo -e "   磁盘管理菜单 (Ultimate安全版)"
        echo -e "========================================"
        echo "1) 查看磁盘和分区"
        echo "2) 分区磁盘 (自动/手动)"
        echo "3) 格式化分区"
        echo "4) 挂载分区 (智能写入 fstab)"
        echo "5) 卸载分区 (安全清理 fstab)"
        echo -e "${BLUE}6) 管理 SWAP (虚拟内存)${NC}"
        echo "0) 返回主菜单"
        echo -e "========================================"
        read -p "请输入选项编号: " choice

        case $choice in
            1)
                echo -e "\n--- 当前磁盘结构 ---"
                lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,LABEL,UUID -e 7,11
                ;;
            2)
                echo -e "\n--- 分区磁盘 ---"
                echo -e "${YELLOW}注意：仅列出物理磁盘，不包含 loop/ram 设备。${NC}"
                mapfile -t disks < <(lsblk -dnrpo NAME,TYPE | awk '$2=="disk" {print $1}')

                if [[ ${#disks[@]} -eq 0 ]]; then
                    echo "未发现可用磁盘。"
                    continue
                fi

                for i in "${!disks[@]}"; do
                    is_mounted=$(lsblk "${disks[$i]}" -no MOUNTPOINT | grep -v "^$")
                    status=""
                    [[ -n "$is_mounted" ]] && status="${RED}[存在挂载]${NC}"
                    echo -e "$((i+1))) ${disks[$i]}"
                done
                
                read -p "请选择要分区的磁盘 (输入0返回): " idx
                [[ "$idx" == "0" ]] && continue
                if ! [[ "$idx" =~ ^[0-9]+$ ]] || [[ "$idx" -gt "${#disks[@]}" ]]; then
                    echo "无效编号。"
                    continue
                fi
                disk="${disks[$((idx-1))]}"

                if lsblk "$disk" -no MOUNTPOINT | grep -q -v "^$"; then
                    echo -e "${RED}错误：磁盘 $disk 或其分区正被挂载使用中。${NC}"
                    echo "请先卸载相关分区（使用菜单选项 5）后再进行操作。"
                    continue
                fi

                echo -e "\n请选择分区方式："
                echo "1) 整盘一个分区 (清空数据)"
                echo "2) 自定义多个分区 (清空数据)"
                echo "3) 进入 fdisk 手动分区"
                echo "0) 返回"
                read -p "请输入编号: " mode
                [[ "$mode" == "0" ]] && continue

                if [[ "$mode" == "1" ]]; then
                    echo -e "${RED}⚠️  警告：将清空 $disk 所有数据并创建一个完整分区！${NC}"
                    read -p "确认请输入 YES (输入其他取消): " confirm
                    if [[ "$confirm" == "YES" ]]; then
                        parted --script "$disk" mklabel gpt
                        parted --script "$disk" mkpart primary ext4 0% 100%
                        partprobe "$disk" && sleep 1
                        echo -e "${GREEN}成功：已在 $disk 上创建一个完整分区。${NC}"
                    else
                        echo "操作已取消。"
                    fi
                elif [[ "$mode" == "2" ]]; then
                    echo -e "${RED}⚠️  警告：将清空 $disk 所有数据并重新分区！${NC}"
                    read -p "确认请输入 YES (输入其他取消): " confirm
                    if [[ "$confirm" == "YES" ]]; then
                        parted --script "$disk" mklabel gpt
                        read -p "请输入要创建的分区数量 (输入0返回): " num_parts
                        [[ "$num_parts" == "0" ]] && continue
                        
                        start=0
                        total_size_bytes=$(lsblk -bno SIZE "$disk" | head -n1)
                        total_gb=$((total_size_bytes / 1073741824))

                        echo "磁盘总大小约为: ${total_gb} GB"

                        for ((i=1; i<=num_parts; i++)); do
                            if [[ $i -lt $num_parts ]]; then
                                read -p "请输入第 $i 个分区大小 (单位 GB, 输入0返回): " size
                                [[ "$size" == "0" ]] && continue 2
                                end=$((start + size))
                                echo "创建分区 $i: ${start}GB - ${end}GB"
                                parted --script "$disk" mkpart primary ext4 "${start}GB" "${end}GB"
                                start=$end
                            else
                                echo "最后一个分区将自动分配剩余容量 (${start}GB - 100%)"
                                parted --script "$disk" mkpart primary ext4 "${start}GB" 100%
                            fi
                        done
                        partprobe "$disk" && sleep 2
                        lsblk "$disk"
                    else
                        echo "操作已取消。"
                    fi
                elif [[ "$mode" == "3" ]]; then
                    fdisk "$disk"
                    partprobe "$disk"
                fi
                ;;
            3)
                echo -e "\n--- 格式化分区 ---"
                mapfile -t devices < <(lsblk -nrpo NAME,TYPE,MOUNTPOINT | awk '$2=="part" {print $1 " " $3}')
                
                if [[ ${#devices[@]} -eq 0 ]]; then
                    echo "未发现分区。"
                    continue
                fi

                display_devs=()
                real_devs=()
                for line in "${devices[@]}"; do
                    dev=$(echo "$line" | awk '{print $1}')
                    mnt=$(echo "$line" | awk '{print $2}')
                    if [[ -n "$mnt" ]]; then
                        display_devs+=("$dev ${RED}(已挂载: $mnt)${NC}")
                    else
                        display_devs+=("$dev")
                    fi
                    real_devs+=("$dev")
                done

                for i in "${!display_devs[@]}"; do
                    echo -e "$((i+1))) ${display_devs[$i]}"
                done

                read -p "请输入要格式化的分区编号 (输入0返回): " idx
                [[ "$idx" == "0" ]] && continue
                if ! [[ "$idx" =~ ^[0-9]+$ ]] || [[ "$idx" -gt "${#real_devs[@]}" ]]; then
                    echo "无效编号。"
                    continue
                fi

                dev="${real_devs[$((idx-1))]}"

                if lsblk -no MOUNTPOINT "$dev" | grep -q -v "^$"; then
                    echo -e "${RED}错误：该分区已挂载，禁止格式化！请先卸载。${NC}"
                    continue
                fi

                read -p "请输入文件系统类型 (ext4/xfs/vfat, 默认 ext4): " fs
                fs=${fs:-ext4}
                
                echo -e "${RED}⚠️  严重警告：即将格式化 $dev ($fs)，所有数据将丢失！${NC}"
                read -p "确认请输入 YES (输入其他取消): " confirm
                if [[ "$confirm" == "YES" ]]; then
                    echo "正在格式化..."
                    if mkfs.$fs "$dev"; then
                        echo -e "${GREEN}成功：已将 $dev 格式化为 $fs${NC}"
                        partprobe
                    else
                        echo -e "${RED}格式化失败！${NC}"
                    fi
                fi
                ;;
            4)
                echo -e "\n--- 挂载分区 ---"
                mapfile -t devices < <(lsblk -nrpo NAME,TYPE,MOUNTPOINT | awk '$2=="part" {print $1 " " $3}')
                
                display_devs=()
                real_devs=()
                for line in "${devices[@]}"; do
                    dev=$(echo "$line" | awk '{print $1}')
                    mnt=$(echo "$line" | awk '{print $2}')
                    if [[ -n "$mnt" ]]; then
                        display_devs+=("$dev ${GREEN}(已挂载: $mnt)${NC}")
                    else
                        display_devs+=("$dev")
                    fi
                    real_devs+=("$dev")
                done

                for i in "${!display_devs[@]}"; do
                    echo -e "$((i+1))) ${display_devs[$i]}"
                done

                read -p "请输入编号: " idx
                [[ "$idx" == "0" ]] && continue
                if ! [[ "$idx" =~ ^[0-9]+$ ]] || [[ "$idx" -gt "${#real_devs[@]}" ]]; then
                    echo "无效编号。"
                    continue
                fi
                dev="${real_devs[$((idx-1))]}"

                cur_mnt=$(lsblk -no MOUNTPOINT "$dev")
                if [[ -n "$cur_mnt" ]]; then
                    echo -e "${YELLOW}该分区已挂载于: $cur_mnt${NC}"
                fi

                label=$(lsblk -no LABEL "$dev")
                uuid=$(blkid -s UUID -o value "$dev")
                
                if [[ -z "$uuid" ]]; then
                    echo -e "${RED}错误：无法获取该分区的 UUID，可能未格式化。${NC}"
                    continue
                fi

                if [[ -n "$label" ]]; then
                    recommended="/mnt/$label"
                else
                    recommended="/mnt/uuid-${uuid:0:8}"
                fi

                read -p "请输入挂载点目录 (默认: $recommended): " dir
                dir=${dir:-$recommended}

                mkdir -p "$dir"
                if mount "$dev" "$dir"; then
                    echo -e "${GREEN}成功挂载 $dev 到 $dir${NC}"
                else
                    echo -e "${RED}挂载失败！${NC}"
                    continue
                fi

                echo "是否配置开机自动挂载 (/etc/fstab)？"
                echo "1) 是 (智能添加，含 nofail)"
                echo "2) 否"
                read -p "请输入编号: " auto

                if [[ "$auto" == "1" ]]; then
                    if grep -q "UUID=$uuid" /etc/fstab; then
                        echo -e "${YELLOW}警告：/etc/fstab 中已存在该 UUID 的配置，跳过写入。${NC}"
                    else
                        fs=$(lsblk -no FSTYPE "$dev")
                        backup_fstab
                        echo "UUID=$uuid   $dir   $fs   defaults,nofail   0   2" >> /etc/fstab
                        echo -e "${GREEN}已成功写入 /etc/fstab。${NC}"
                    fi
                fi
                ;;
            5)
                echo -e "\n--- 卸载分区 ---"
                mapfile -t devices < <(lsblk -nrpo NAME,MOUNTPOINT | awk '$2 != "" && $2 != "/" && $2 != "[SWAP]" {print $1 " " $2}')
                
                if [[ ${#devices[@]} -eq 0 ]]; then
                    echo "没有可卸载的数据分区。"
                    continue
                fi

                for i in "${!devices[@]}"; do
                    echo "$((i+1))) ${devices[$i]}"
                done
                
                read -p "请输入编号: " idx
                [[ "$idx" == "0" ]] && continue
                if ! [[ "$idx" =~ ^[0-9]+$ ]] || [[ "$idx" -gt "${#devices[@]}" ]]; then
                    echo "无效编号。"
                    continue
                fi

                line="${devices[$((idx-1))]}"
                dev=$(echo "$line" | awk '{print $1}')
                dir=$(echo "$line" | awk '{print $2}')

                if umount "$dir"; then
                    echo -e "${GREEN}已卸载 $dev ($dir)${NC}"
                    
                    uuid=$(blkid -s UUID -o value "$dev")
                    if [[ -n "$uuid" ]]; then
                        if grep -q "$uuid" /etc/fstab; then
                            read -p "发现 fstab 中存在配置，是否删除？(YES/NO): " del_fstab
                            if [[ "$del_fstab" == "YES" ]]; then
                                backup_fstab
                                tmp_fstab=$(mktemp)
                                if grep -v "UUID=$uuid" /etc/fstab > "$tmp_fstab"; then
                                    cat "$tmp_fstab" > /etc/fstab
                                    echo -e "${GREEN}已安全更新 /etc/fstab。${NC}"
                                else
                                    echo -e "${RED}临时文件写入失败，未修改 fstab。${NC}"
                                fi
                                rm -f "$tmp_fstab"
                            fi
                        fi
                    fi

                    read -p "是否删除空的挂载点目录 $dir? (YES/NO): " deldir
                    if [[ "$deldir" == "YES" ]]; then
                        rmdir "$dir" 2>/dev/null && echo "已删除目录 $dir" || echo -e "${YELLOW}目录非空，已保留。${NC}"
                    fi
                else
                    echo -e "${RED}卸载失败！文件正被占用。${NC}"
                fi
                ;;
            6)
                echo -e "\n--- 管理 SWAP (虚拟内存) ---"
                echo "1) 创建/启用 SWAP 文件"
                echo "2) 关闭/删除 SWAP 文件"
                echo "0) 返回"
                read -p "请输入选项: " swap_op

                if [[ "$swap_op" == "1" ]]; then
                    echo -e "${YELLOW}提示：通常建议大小为物理内存的 1-2 倍。${NC}"
                    read -p "请输入 SWAP 大小 (单位 MB，例如 2048): " swap_size
                    if [[ ! "$swap_size" =~ ^[0-9]+$ ]]; then echo "无效数字"; continue; fi
                    
                    swap_file="/swapfile"
                    if [[ -f "$swap_file" ]]; then 
                        echo -e "${RED}错误：$swap_file 已存在。请先删除旧的 SWAP。${NC}"
                        continue 
                    fi
                    
                    echo "正在分配空间 (这可能需要几秒钟)..."
                    if ! fallocate -l "${swap_size}M" "$swap_file" 2>/dev/null; then
                        dd if=/dev/zero of="$swap_file" bs=1M count="$swap_size"
                    fi
                    
                    chmod 600 "$swap_file"
                    if mkswap "$swap_file" && swapon "$swap_file"; then
                        echo -e "${GREEN}SWAP 启用成功！${NC}"
                        backup_fstab
                        if ! grep -q "$swap_file" /etc/fstab; then
                            echo "$swap_file   none    swap    sw    0   0" >> /etc/fstab
                            echo "已添加至开机自启。"
                        fi
                    else
                        echo -e "${RED}SWAP 启用失败，正在回滚...${NC}"
                        rm -f "$swap_file"
                    fi

                elif [[ "$swap_op" == "2" ]]; then
                    swap_file="/swapfile"
                    if ! grep -q "$swap_file" /proc/swaps && [ ! -f "$swap_file" ]; then
                         echo "未检测到标准 /swapfile。"
                         continue
                    fi
                    
                    echo "正在关闭 SWAP..."
                    swapoff "$swap_file" 2>/dev/null
                    rm -f "$swap_file"
                    
                    if grep -q "$swap_file" /etc/fstab; then
                        backup_fstab
                        tmp_fstab=$(mktemp)
                        if grep -v "$swap_file" /etc/fstab > "$tmp_fstab"; then
                            cat "$tmp_fstab" > /etc/fstab
                            echo -e "${GREEN}SWAP 已彻底删除并清理配置。${NC}"
                        fi
                        rm -f "$tmp_fstab"
                    else
                        echo -e "${GREEN}SWAP 文件已删除。${NC}"
                    fi
                fi
                ;;
            0)
                return 0
                ;;
            *)
                echo "无效选项。"
                ;;
        esac
    done
}
