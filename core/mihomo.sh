#!/bin/bash

function module_mihomo() {
    # 定义两个源目录：
    # 1. 自动下载目录 (优先级高)
    AUTO_DIR="/tmp/mihomo"
    # 2. 手动上传目录 (备用)
    MANUAL_DIR="/root/mihomo"
    
    # 最终配置文件安装位置
    CONF_DIR="/etc/mihomo"
    BIN_PATH="/usr/local/bin/mihomo"

    # ==================== 服务配置函数 ====================
    setup_service() {
        echo -e "${BLUE}>>> 配置 Systemd 服务...${NC}"
        mkdir -p "$CONF_DIR"
        
        # 1. 处理配置文件 (config.yaml)
        if [ ! -f "$CONF_DIR/config.yaml" ]; then
             # 优先从 /tmp/mihomo 找
             if [ -f "$AUTO_DIR/config.yaml" ]; then
                 cp "$AUTO_DIR/config.yaml" "$CONF_DIR/config.yaml"
                 echo -e "${GREEN}✅ 已应用仓库中的 config.yaml${NC}"
             # 其次从 /root/mihomo 找
             elif [ -f "$MANUAL_DIR/config.yaml" ]; then
                 cp "$MANUAL_DIR/config.yaml" "$CONF_DIR/config.yaml"
                 echo -e "${GREEN}✅ 已应用本地 config.yaml${NC}"
             else
                 echo -e "${YELLOW}⚠️ 未检测到配置文件，生成空配置...${NC}"
                 touch "$CONF_DIR/config.yaml"
                 echo -e "${RED}⚠️ 请注意：你需要自行编辑 $CONF_DIR/config.yaml 填入订阅信息！${NC}"
             fi
        fi

        # 2. 处理服务文件 (mihomo.service)
        # 如果仓库里自带了 service 文件，直接用仓库的，这样你可以在 GitHub 上自定义启动参数
        if [ -f "$AUTO_DIR/mihomo.service" ]; then
            cp "$AUTO_DIR/mihomo.service" /etc/systemd/system/mihomo.service
            echo -e "${GREEN}✅ 已应用仓库中的 mihomo.service 服务配置${NC}"
        else
            # 否则生成默认的标准配置
            cat > /etc/systemd/system/mihomo.service <<EOF
[Unit]
Description=Mihomo Daemon
After=network.target

[Service]
Type=simple
Restart=always
ExecStart=$BIN_PATH -d $CONF_DIR
User=root
LimitNOFILE=524288

[Install]
WantedBy=multi-user.target
EOF
            echo -e "${GREEN}✅ 已生成默认服务配置${NC}"
        fi

        systemctl daemon-reload
        systemctl enable mihomo
        echo -e "${GREEN}✅ 服务配置完成${NC}"
    }

    # ==================== 在线下载安装 ====================
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
        LATEST_VER=$(curl -s -m 5 https://api.github.com/repos/MetaCubeX/mihomo/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        
        if [ -z "$LATEST_VER" ]; then
            read -p "获取失败，请输入欲安装的版本号 (例如 v1.18.5): " LATEST_VER
            if [ -z "$LATEST_VER" ]; then echo "❌ 未输入版本号"; return 1; fi
        fi
        
        # 使用 ghproxy 加速下载
        TARGET_URL="https://github.com/MetaCubeX/mihomo/releases/download/${LATEST_VER}/mihomo-linux-${MIHOMO_ARCH}-${LATEST_VER}.gz"
        PROXY_URL="https://ghproxy.net/${TARGET_URL}"
        
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
        setup_service
    }

    # ==================== 仓库/本地安装 (核心修改) ====================
    install_local() {
        echo -e "${GREEN}=== 仓库/本地 部署模式 ===${NC}"
        
        local SOURCE_FILE=""

        # 1. 优先检查 main.sh 刚刚自动下载的目录 (/tmp/mihomo)
        if [ -f "$AUTO_DIR/mihomo" ]; then
            echo -e "${GREEN}🎉 检测到 GitHub 仓库文件已自动下载 (/tmp/mihomo)${NC}"
            SOURCE_FILE="$AUTO_DIR/mihomo"
        
        # 2. 其次检查用户手动上传目录 (/root/mihomo)
        elif [ -f "$MANUAL_DIR/mihomo" ]; then
             echo -e "${YELLOW}检测到 /root/mihomo 下存在手动上传的文件${NC}"
             SOURCE_FILE="$MANUAL_DIR/mihomo"
        
        # 3. 都没有，提示用户
        else
            echo -e "${RED}❌ 未检测到安装文件！${NC}"
            echo "请选择："
            echo "1. 我现在去把文件上传到 $MANUAL_DIR，然后按回车"
            echo "2. 放弃"
            read -p "选择: " choice
            if [ "$choice" == "1" ]; then
                mkdir -p "$MANUAL_DIR"
                read -p "上传完成后，请按回车继续..."
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

        # 开始安装二进制文件
        echo -e "正在安装核心文件..."
        cp "$SOURCE_FILE" "$BIN_PATH"
        chmod 755 "$BIN_PATH"
        
        # 验证
        if "$BIN_PATH" -v >/dev/null 2>&1; then
            echo -e "${GREEN}✅ 核心文件安装成功: $("$BIN_PATH" -v)${NC}"
        else
            echo -e "${RED}❌ 安装的文件似乎无法运行 (可能是架构不对或文件损坏)${NC}"
            return 1
        fi

        # 配置服务和配置文件
        setup_service
    }

    uninstall_mihomo() {
        echo -e "${RED}⚠️  警告：准备卸载 Mihomo${NC}"
        read -p "确认要卸载吗？(y/N): " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then echo "已取消"; return; fi

        systemctl stop mihomo 2>/dev/null
        systemctl disable mihomo 2>/dev/null
        rm -f "$BIN_PATH"
        rm -f /etc/systemd/system/mihomo.service
        systemctl daemon-reload

        if [ -d "$CONF_DIR" ]; then
            read -p "是否保留配置文件? [y/N]: " keep_conf
            if [[ ! "$keep_conf" =~ ^[Yy]$ ]]; then
                rm -rf "$CONF_DIR"
                echo "配置目录已删除。"
            fi
        fi
        echo -e "${GREEN}✅ 卸载完成。${NC}"
    }

    echo -e "${GREEN}=== Mihomo 安装向导 ===${NC}"
    echo "1. 仅安装内核优化 (Sysctl)"
    echo "2. 在线安装 (下载官方最新版)"
    echo "3. 部署仓库版本 (推荐！使用你上传的文件)"
    echo "4. 服务管理 (启动/停止/日志)"
    echo -e "${RED}5. 卸载 Mihomo${NC}"
    read -p "请选择: " OPT

    case "$OPT" in
        1)
            cat > /etc/sysctl.d/99-mihomo-optimized.conf <<EOF
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
fs.inotify.max_user_watches=524288
EOF
            sysctl --system
            echo -e "${GREEN}✔ 优化完成${NC}"
            ;;
        2) install_online ;;
        3) install_local ;;
        4)
            echo "1) 启动  2) 停止  3) 重启  4) 查看日志"
            read -p "操作: " S_OPT
            case $S_OPT in
                1) systemctl start mihomo; echo "已启动" ;;
                2) systemctl stop mihomo; echo "已停止" ;;
                3) systemctl restart mihomo; echo "已重启" ;;
                4) systemctl status mihomo --no-pager ;;
            esac
            ;;
        5) uninstall_mihomo ;;
        *) echo "无效选择" ;;
    esac
}