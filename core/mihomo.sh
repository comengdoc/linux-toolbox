#!/bin/bash
function module_mihomo() {
    SRC_DIR="/root/mihomo"

    setup_service() {
        echo -e "${BLUE}>>> 配置 Systemd 服务...${NC}"
        mkdir -p /etc/mihomo
        
        if [ ! -f "/etc/mihomo/config.yaml" ]; then
             if [ -f "$SRC_DIR/config.yaml" ]; then
                 cp "$SRC_DIR/config.yaml" /etc/mihomo/config.yaml
                 echo -e "${GREEN}✅ 已复制本地 config.yaml${NC}"
             else
                 echo -e "${YELLOW}⚠️ 未检测到配置文件，正在生成默认空配置...${NC}"
                 touch /etc/mihomo/config.yaml
                 echo -e "${RED}⚠️ 请注意：你需要自行编辑 /etc/mihomo/config.yaml 填入订阅信息！${NC}"
             fi
        fi

        cat > /etc/systemd/system/mihomo.service <<EOF
[Unit]
Description=Mihomo Daemon
After=network.target

[Service]
Type=simple
Restart=always
ExecStart=/usr/local/bin/mihomo -d /etc/mihomo
User=root
LimitNOFILE=524288

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable mihomo
        echo -e "${GREEN}✅ 服务配置完成${NC}"
    }

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
            echo -e "${YELLOW}⚠️ 无法自动获取最新版本 (API连接超时)${NC}"
            read -p "请输入欲安装的版本号 (例如 v1.18.5): " LATEST_VER
            if [ -z "$LATEST_VER" ]; then echo "❌ 未输入版本号"; return 1; fi
        fi
        
        TARGET_URL="https://github.com/MetaCubeX/mihomo/releases/download/${LATEST_VER}/mihomo-linux-${MIHOMO_ARCH}-${LATEST_VER}.gz"
        PROXY_URL="${GH_PROXY}${TARGET_URL}"
        
        echo -e "目标版本: ${GREEN}${LATEST_VER}${NC}"
        echo -e "下载源: ${BLUE}${PROXY_URL}${NC}"
        echo -e "${YELLOW}>>> 开始下载...${NC}"
        
        rm -f /tmp/mihomo.gz
        curl -L -o /tmp/mihomo.gz "$PROXY_URL" --progress-bar

        if [ ! -s /tmp/mihomo.gz ]; then
            echo -e "${RED}❌ 下载失败或文件为空。请检查加速代理是否可用。${NC}"
            return 1
        fi

        echo -e "${YELLOW}>>> 安装中...${NC}"
        gzip -d /tmp/mihomo.gz
        mv /tmp/mihomo /usr/local/bin/mihomo
        chmod 755 /usr/local/bin/mihomo
        
        echo -e "${GREEN}✅ Mihomo 已安装到 /usr/local/bin/mihomo${NC}"
        /usr/local/bin/mihomo -v
        setup_service
    }

    install_manual() {
        echo -e "${GREEN}=== 手动离线安装模式 ===${NC}"
        echo -e "请确保你已将相关文件上传至目录: ${YELLOW}$SRC_DIR${NC}"
        mkdir -p "$SRC_DIR"
        read -p "文件准备好后，按回车继续..."

        if [ -f "$SRC_DIR/mihomo.gz" ]; then
            gzip -d -k "$SRC_DIR/mihomo.gz" > /dev/null 2>&1
        fi

        if [ -f "$SRC_DIR/mihomo" ]; then
            cp "$SRC_DIR/mihomo" /usr/local/bin/mihomo
            chmod 755 /usr/local/bin/mihomo
            echo -e "${GREEN}✅ 二进制文件安装成功${NC}"
            /usr/local/bin/mihomo -v
        else
            echo -e "${RED}❌ 未找到 mihomo 二进制文件${NC}"
            return 1
        fi
        setup_service
    }

    uninstall_mihomo() {
        echo -e "${RED}⚠️  警告：准备卸载 Mihomo${NC}"
        read -p "确认要卸载吗？(y/N): " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then echo "已取消"; return; fi

        if systemctl is-active --quiet mihomo; then
            echo "停止服务..."
            systemctl stop mihomo
            systemctl disable mihomo
        fi

        if [ -f "/usr/local/bin/mihomo" ]; then
            rm -f /usr/local/bin/mihomo
            echo "核心已删除。"
        fi

        if [ -f "/etc/systemd/system/mihomo.service" ]; then
            rm -f /etc/systemd/system/mihomo.service
            systemctl daemon-reload
            echo "服务文件已清理。"
        fi

        if [ -d "/etc/mihomo" ]; then
            echo -e "${YELLOW}检测到配置文件目录 (/etc/mihomo)${NC}"
            read -p "是否保留配置文件(订阅/规则)? [y/N] (默认删除): " keep_conf
            if [[ "$keep_conf" =~ ^[Yy]$ ]]; then
                echo -e "${GREEN}✅ 配置文件已保留。${NC}"
            else
                rm -rf /etc/mihomo
                echo -e "${RED}配置目录已删除。${NC}"
            fi
        fi

        rm -f /var/log/mihomo_install.log
        
        if pgrep -x mihomo >/dev/null; then
            echo -e "${RED}⚠️  警告：仍有 mihomo 进程在运行，请手动检查：pgrep -a mihomo${NC}"
        else
            echo -e "${GREEN}✅ 卸载流程完成。${NC}"
        fi
    }

    echo -e "${GREEN}=== Mihomo 安装向导 ===${NC}"
    echo "1. 仅安装内核优化 (Sysctl)"
    echo "2. 在线安装 (自动下载 + 国内加速)"
    echo "3. 手动安装 (本地上传文件)"
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
        3) install_manual ;;
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
