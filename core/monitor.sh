#!/bin/bash
function module_nic_monitor() {
    INTERVAL=2 # 默认刷新间隔

    # 捕捉 Ctrl+C 信号，以便从循环中退出而不退出主脚本
    trap 'echo -e "\n${YELLOW}正在停止监控并返回主菜单...${NC}"; return' SIGINT

    # 定义关联数组，用于存储上一次的字节数
    declare -A PREV_RX
    declare -A PREV_TX

    # 单位转换函数 (Bytes -> KB/s, MB/s)
    human_readable() {
        local bytes=$1
        if [[ $bytes -lt 1024 ]]; then
            echo "${bytes} B/s"
        elif [[ $bytes -lt 1048576 ]]; then
            echo "$((bytes / 1024)) KB/s"
        elif [[ $bytes -lt 1073741824 ]]; then
            echo "$((bytes / 1024 / 1024)) MB/s"
        else
            echo "$((bytes / 1024 / 1024 / 1024)) GB/s"
        fi
    }

    if command -v tput >/dev/null 2>&1; then has_tput=true; else has_tput=false; fi

    while true; do
        if $has_tput; then tput cup 0 0; else clear; fi

        echo "============================================================================"
        echo " 物理网卡全能监控 (刷新: ${INTERVAL}s) [按 '0' 或 Ctrl+C 返回主菜单]"
        echo "============================================================================"
        
        printf "%-16s %-10s %-10s %-8s %-12s %-12s\n" "Interface" "Speed" "Duplex" "Link" "Rx Rate" "Tx Rate"
        echo "----------------------------------------------------------------------------"

        for path in /sys/class/net/*; do
            iface=${path##*/}
            if [[ "$iface" == "lo" ]] || [[ ! -e "$path/device" ]]; then continue; fi

            if { read -r carrier < "$path/carrier"; } 2>/dev/null; then
                if [[ "$carrier" == "1" ]]; then link_status="\e[32mUp\e[0m"; is_up=true; else link_status="\e[31mDown\e[0m"; is_up=false; fi
            else
                link_status="\e[33mUnk\e[0m"; is_up=false
            fi

            if $is_up; then
                if { read -r speed_val < "$path/speed"; } 2>/dev/null; then
                     if [[ "$speed_val" == "-1" ]] || [[ -z "$speed_val" ]]; then
                         speed="Unknown"
                     elif [[ "$speed_val" -ge 1000 ]]; then
                         gb_part=$((speed_val / 1000))
                         dec_part=$(( (speed_val % 1000) / 100 ))
                         if [[ "$dec_part" -eq 0 ]]; then speed="${gb_part}Gb/s"; else speed="${gb_part}.${dec_part}Gb/s"; fi
                     else
                         speed="${speed_val}Mb/s"
                     fi
                else
                    speed="N/A"
                fi
                
                if { read -r duplex_val < "$path/duplex"; } 2>/dev/null; then duplex="$duplex_val"; else duplex="Unknown"; fi
            else
                speed="---"; duplex="---"
            fi

            curr_rx=$(cat "$path/statistics/rx_bytes" 2>/dev/null || echo 0)
            curr_tx=$(cat "$path/statistics/tx_bytes" 2>/dev/null || echo 0)

            if [[ -n "${PREV_RX[$iface]}" ]]; then
                diff_rx=$(( curr_rx - PREV_RX[$iface] ))
                diff_tx=$(( curr_tx - PREV_TX[$iface] ))
                [[ $diff_rx -lt 0 ]] && diff_rx=0
                [[ $diff_tx -lt 0 ]] && diff_tx=0
                rate_rx_bps=$(( diff_rx / INTERVAL ))
                rate_tx_bps=$(( diff_tx / INTERVAL ))
                rx_display=$(human_readable $rate_rx_bps)
                tx_display=$(human_readable $rate_tx_bps)
            else
                rx_display="Calc..."
                tx_display="Calc..."
            fi

            PREV_RX[$iface]=$curr_rx
            PREV_TX[$iface]=$curr_tx

            printf "%-16s %-10s %-10s %-8b %-12s %-12s \n" \
                "$iface" "$speed" "$duplex" "$link_status" "$rx_display" "$tx_display"
        done

        if $has_tput; then tput ed; else echo ""; fi
        
        # [核心优化] 使用带超时的 read 替代 sleep
        # 这样在等待间隔时，如果用户输入 0 可以立即响应并退出，无需死等
        # -t $INTERVAL: 等待超时时间等于刷新间隔
        # -n 1: 读取1个字符
        # -s: 不回显
        read -t "$INTERVAL" -n 1 -s -p "" KEY < /dev/tty
        if [[ "$KEY" == "0" ]]; then
            echo -e "\n${YELLOW}正在停止监控并返回...${NC}"
            break
        fi
    done
    # 恢复Trap (虽然 return 会跳出函数，但好习惯保持)
    trap - SIGINT
}