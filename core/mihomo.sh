#!/bin/bash

# =========================================================
# Mihomo 一键安装脚本 (修复菜单跳过 Bug 版)
# 适用设备: 斐讯N1, NanoPi R5C 等 ARM 架构设备
# =========================================================

# 定义颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

function module_mihomo() {
    # 定义路径
    AUTO_DIR="/tmp/mihomo"          # 自动下载缓存路径
    MANUAL_DIR="/root/mihomo"       # 手动上传路径
    CONF_DIR="/etc/mihomo"          # 配置文件路径
    BIN_PATH="/usr/local/bin/mihomo" # 二进制文件路径

    # ==================== 0. 内核优化函数 (旁路由必须) ====================
    optimize_sysctl() {
        echo -e "${BLUE}>>> 正在应用系统内核优化 (开启IP转发/BBR)...${NC}"
        cat > /etc/sysctl.d/99-mihomo-optimized.conf <<EOF
# 开启 IPv4/IPv6 转发 (旁路由核心)
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
# 开启 BBR 拥塞控制
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
# 增大文件监听数 (防止报错)
fs.inotify.max_user_watches=524288
EOF
        sysctl --system >/dev/null 2>&1
        echo -e "${GREEN}✅ 内核参数优化完成${NC}"
    }

    # ==================== 1. 服务配置函数 (核心修改) ====================
    setup_service() {
        echo -e "${BLUE}>>> 配置 Systemd 服务...${NC}"
        mkdir -p "$CONF_DIR"
        
        # --- 配置文件处理 ---
        if [ ! -f "$CONF_DIR/config.yaml" ]; then
             if [ -f "$AUTO_DIR/config.yaml" ]; then
                 cp "$AUTO_DIR/config.yaml" "$CONF_DIR/config.yaml"
                 echo -e "${GREEN}✅ 已应用仓库中的 config.yaml${NC}"
             elif [ -f "$MANUAL_DIR/config.yaml" ]; then
                 cp "$MANUAL_DIR/config.yaml" "$CONF_DIR/config.yaml"
                 echo -e "${GREEN}✅ 已应用本地 config.yaml${NC}"
             else
                 echo -e "${YELLOW}⚠️ 未检测到配置文件，生成空配置...${NC}"
                 touch "$CONF_DIR/config.yaml"
                 echo -e "${RED}⚠️ 请注意：你需要自行编辑 $CONF_DIR/config.yaml 填入订阅信息！${NC}"
             fi
        fi

        # --- Service 文件生成 (包含 TimeSync/GOGC/IP转发 优化) ---
        cat > /etc/systemd/system/mihomo.service <<EOF
[Unit]
Description=mihomo Daemon, Another Clash Kernel.
# 【关键】等待时间同步，防止 N1/R5C 断电重启后时间错误导致节点 SSL 握手失败
After=network-online.target time-sync.target
Wants=network-online.target time-sync.target

[Service]
Type=simple
# 资源限制
LimitNPROC=500
LimitNOFILE=1000000

# 【关键】内存优化：限制 Go 垃圾回收频率，防止小内存设备爆内存
Environment="GOGC=20"

# 必要的网络权限
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE CAP_SYS_TIME CAP_SYS_PTRACE CAP_DAC_READ_SEARCH CAP_DAC_OVERRIDE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE CAP_SYS_TIME CAP_SYS_PTRACE CAP_DAC_READ_SEARCH CAP_DAC_OVERRIDE

# 崩溃自动重启
Restart=always
RestartSec=5

# 【关键】旁路由核心：启动前强制开启 IP 转发
ExecStartPre=/bin/bash -c 'echo 1 > /proc/sys/net/ipv4/ip_forward'

# 【关键】网络检测：循环等待默认路由就绪
ExecStartPre=/bin/bash -c 'for i in {1..20}; do if ip route show default | grep -q "default"; then echo "Network ready"; exit 0; fi; sleep 1; done; echo "Network not ready"; exit 1'

# 启动命令
ExecStart=$BIN_PATH -d $CONF_DIR

# 重载与日志
ExecReload=/bin/kill -HUP \$MAINPID
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
        echo -e "${GREEN}✅ 已生成优化版服务配置${NC}"

        systemctl daemon-reload
        systemctl enable mihomo
        echo -e "${GREEN}✅ 服务已配置并设置为开机自启${NC}"
    }

    # ==================== 2. 在线下载安装 ====================
    install_online() {
        echo -e "${BLUE}>>> 正在检测系统架构...${NC}"
        local ARCH=$(uname -m)
        local MIHOMO_ARCH=""
        case "$ARCH" in
            x86_64) MIHOMO_ARCH="amd64" ;;
            aarch64) MIHOMO_ARCH="arm64" ;;
            armv7l) MIHOMO_ARCH="armv7" ;;
            *) echo -e "${RED}不支持的架构: $ARCH${NC}"; return 1 ;;
        esac

        echo -e "${BLUE}>>> 正在获取 Mihomo 版本信息...${NC}"
        # 这里 curl 没问题，不需要改
        LATEST_VER=$(curl -s -m 5 https://api.github.com/repos/MetaCubeX/mihomo/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        
        if [ -z "$LATEST_VER" ]; then
            # 【修复点 1】增加 < /dev/tty
            read -p "获取失败，请输入欲安装的版本号 (例如 v1.18.5): " LATEST_VER < /dev/tty
            if [ -z "$LATEST_VER" ]; then echo "❌ 未输入版本号"; return 1; fi
        fi
        
        # 兼容 main.sh 传过来的代理设置 (如果有)
        local proxy_prefix="${PROXY_PREFIX:-https://ghproxy.net/}"
        TARGET_URL="https://github.com/MetaCubeX/mihomo/releases/download/${LATEST_VER}/mihomo-linux-${MIHOMO_ARCH}-${LATEST_VER}.gz"
        PROXY_URL="${proxy_prefix}${TARGET_URL}"
        
        echo -e "正在下载: ${GREEN}${PROXY_URL}${NC}"
        rm -f /tmp/mihomo.gz
        curl -L -o /tmp/mihomo.gz "$PROXY_URL" --progress-bar

        if [ ! -s /tmp/mihomo.gz ]; then
            echo -e "${RED}❌ 下载失败。${NC}"
            return 1
        fi

        gzip -d /tmp/mihomo.gz
        mv /tmp/mihomo "$BIN_PATH"
        chmod 755 "$BIN_PATH"
        
        echo -e "${GREEN}✅ Mihomo 已在线安装完毕${NC}"
        optimize_sysctl
        setup_service
    }

    # ==================== 3. 仓库/本地安装 ====================
    install_local() {
        echo -e "${GREEN}=== 仓库/本地 部署模式 ===${NC}"
        local SOURCE_FILE=""

        # 1. 优先检查自动下载目录
        if [ -f "$AUTO_DIR/mihomo" ]; then
            echo -e "${GREEN}🎉 检测到 GitHub 仓库文件 (/tmp/mihomo)${NC}"
            SOURCE_FILE="$AUTO_DIR/mihomo"
        # 2. 其次检查手动上传目录
        elif [ -f "$MANUAL_DIR/mihomo" ]; then
             echo -e "${YELLOW}检测到本地上传文件 (/root/mihomo)${NC}"
             SOURCE_FILE="$MANUAL_DIR/mihomo"
        else
            echo -e "${RED}❌ 未检测到安装文件！${NC}"
            echo "请选择："
            echo "1. 我现在去上传到 $MANUAL_DIR，然后按回车"
            echo "2. 放弃"
            # 【修复点 2】增加 < /dev/tty
            read -p "选择: " choice < /dev/tty
            if [ "$choice" == "1" ]; then
                mkdir -p "$MANUAL_DIR"
                # 【修复点 3】增加 < /dev/tty
                read -p "上传完成后，请按回车继续..." < /dev/tty
                if [ -f "$MANUAL_DIR/mihomo" ]; then
                    SOURCE_FILE="$MANUAL_DIR/mihomo"
                else
                    echo -e "${RED}还是没找到，退出。${NC}"
                    return 1
                fi
            else
                return 1
            fi
        fi

        echo -e "正在安装核心文件..."
        cp "$SOURCE_FILE" "$BIN_PATH"
        chmod 755 "$BIN_PATH"
        
        if "$BIN_PATH" -v >/dev/null 2>&1; then
            echo -e "${GREEN}✅ 核心文件安装成功: $("$BIN_PATH" -v)${NC}"
        else
            echo -e "${RED}❌ 文件无法运行 (架构错误或文件损坏)${NC}"
            return 1
        fi

        optimize_sysctl
        setup_service
    }

    # ==================== 4. 卸载函数 ====================
    uninstall_mihomo() {
        echo -e "${RED}⚠️  警告：准备卸载 Mihomo${NC}"
        # 【修复点 4】增加 < /dev/tty
        read -p "确认要卸载吗？(y/N): " confirm < /dev/tty
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then echo "已取消"; return; fi

        systemctl stop mihomo 2>/dev/null
        systemctl disable mihomo 2>/dev/null
        rm -f "$BIN_PATH"
        rm -f /etc/systemd/system/mihomo.service
        rm -f /etc/sysctl.d/99-mihomo-optimized.conf
        systemctl daemon-reload

        if [ -d "$CONF_DIR" ]; then
            # 【修复点 5】增加 < /dev/tty
            read -p "是否保留配置文件? [y/N]: " keep_conf < /dev/tty
            if [[ ! "$keep_conf" =~ ^[Yy]$ ]]; then
                rm -rf "$CONF_DIR"
                echo "配置目录已删除。"
            fi
        fi
        echo -e "${GREEN}✅ 卸载完成。${NC}"
    }

    # ==================== 菜单逻辑 ====================
    echo -e "${GREEN}=== Mihomo 安装向导 (旁路由优化版) ===${NC}"
    echo "1. 手动应用内核优化 (Sysctl)"
    echo "2. 在线安装 (下载官方最新版)"
    echo "3. 部署仓库版本 (推荐！使用本地/仓库文件)"
    echo "4. 服务管理 (启动/停止/日志)"
    echo -e "${RED}5. 卸载 Mihomo${NC}"
    echo "0. 返回主菜单"
    
    # 【修复点 6 - 关键】增加 < /dev/tty，防止菜单秒退
    read -p "请选择: " OPT < /dev/tty

    case "$OPT" in
        1) optimize_sysctl ;;
        2) install_online ;;
        3) install_local ;;
        4)
            echo "1) 启动  2) 停止  3) 重启  4) 查看日志"
            # 【修复点 7】增加 < /dev/tty
            read -p "操作: " S_OPT < /dev/tty
            case $S_OPT in
                1) systemctl start mihomo; echo "已启动" ;;
                2) systemctl stop mihomo; echo "已停止" ;;
                3) systemctl restart mihomo; echo "已重启" ;;
                4) systemctl status mihomo --no-pager ;;
            esac
            ;;
        5) uninstall_mihomo ;;
        0) return ;;
        *) echo "无效选择" ;;
    esac
}