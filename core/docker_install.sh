#!/bin/bash
function module_docker_install() {
    detect_system() {
        ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
        case "$ARCH" in 
            amd64|x86_64) ARCH_TYPE="amd64" ;; 
            arm64|aarch64) ARCH_TYPE="arm64" ;; 
            armhf|armv7l) ARCH_TYPE="armhf" ;; 
            *) echo "不支持的架构: $ARCH"; return 1 ;; 
        esac

        if [ -f /etc/os-release ]; then 
            . /etc/os-release
            case "$ID" in
                ubuntu|linuxmint|elementary|pop) TARGET_OS="ubuntu" ;;
                debian|armbian|kali|raspbian|deepin|uos) TARGET_OS="debian" ;;
                *) TARGET_OS="debian" ;;
            esac
            
            VERSION_CODE=$VERSION_CODENAME
            if [ -z "$VERSION_CODE" ]; then
                if grep -q "Bookworm" /etc/os-release; then VERSION_CODE="bookworm";
                elif grep -q "Bullseye" /etc/os-release; then VERSION_CODE="bullseye";
                elif grep -q "Jammy" /etc/os-release; then VERSION_CODE="jammy";
                else VERSION_CODE="bookworm"; fi
            fi
        fi
    }

    uninstall_docker() {
        echo -e "${RED}⚠️  卸载 Docker 引擎${NC}"
        read -p "保留数据 (/var/lib/docker)? [y/N] " keep_data < /dev/tty
        systemctl stop docker >/dev/null 2>&1
        apt-mark unhold docker-ce docker-ce-cli >/dev/null 2>&1
        apt-get purge -y --allow-change-held-packages docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras
        apt-get autoremove -y
        rm -rf /etc/docker /var/run/docker.sock
        if [[ ! "$keep_data" =~ ^[Yy]$ ]]; then rm -rf /var/lib/docker; fi
        echo "Docker 已卸载。"
    }

    install_docker_core() {
        MODE=$1
        
        echo ">>> 清理旧环境并解除锁定..."
        apt-mark unhold docker-ce docker-ce-cli >/dev/null 2>&1
        
        for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do apt-get remove -y $pkg; done
        
        echo ">>> 配置依赖..."
        apt-get update; apt-get install -y ca-certificates curl gnupg
        mkdir -p /etc/apt/keyrings; rm -f /etc/apt/keyrings/docker.gpg
        
        echo ">>> 添加阿里云 Docker GPG 密钥..."
        curl -fsSL https://mirrors.aliyun.com/docker-ce/linux/${TARGET_OS}/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        
        # [修改 1] 强制修正 GPG 密钥权限，防止 apt 读取失败
        chmod a+r /etc/apt/keyrings/docker.gpg
        
        echo ">>> 添加软件源 (OS: $TARGET_OS / Code: $VERSION_CODE)..."
        echo "deb [arch=$ARCH_TYPE signed-by=/etc/apt/keyrings/docker.gpg] https://mirrors.aliyun.com/docker-ce/linux/${TARGET_OS} ${VERSION_CODE} stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
        apt-get update
        
        if [ "$MODE" == "select" ]; then
             echo -e "${YELLOW}>>> 正在获取可用 Docker 版本列表...${NC}"
             mapfile -t VERSION_LIST < <(apt-cache madison docker-ce | awk '{print $3}' | head -n 20)
             
             if [ ${#VERSION_LIST[@]} -eq 0 ]; then
                 echo -e "${RED}❌ 未找到可用版本，可能源不支持当前系统 ($TARGET_OS/$VERSION_CODE)。${NC}"
                 return 1
             else
                 echo "------------------------------------------------"
                 echo -e "No  版本号"
                 echo "------------------------------------------------"
                 for i in "${!VERSION_LIST[@]}"; do
                     printf "%2d) %s\n" "$((i+1))" "${VERSION_LIST[$i]}"
                 done
                 echo "------------------------------------------------"
                 
                 while true; do
                     read -p "请输入版本编号 (例如 1, 输入 0 返回): " SELECT_NUM < /dev/tty
                     
                     if [ "$SELECT_NUM" == "0" ]; then return; fi
                     
                     if [[ "$SELECT_NUM" =~ ^[0-9]+$ ]] && [ "$SELECT_NUM" -ge 1 ] && [ "$SELECT_NUM" -le ${#VERSION_LIST[@]} ]; then
                         VER_STR="${VERSION_LIST[$((SELECT_NUM-1))]}"
                         echo -e "✅ 已选择版本: ${GREEN}${VER_STR}${NC}"
                         break
                     else
                         echo -e "${RED}输入无效。${NC}"
                     fi
                 done
             fi

             if [ -n "$VER_STR" ]; then
                 apt-get install -y --allow-change-held-packages docker-ce="$VER_STR" docker-ce-cli="$VER_STR" containerd.io docker-compose-plugin
                 if [ $? -eq 0 ]; then apt-mark hold docker-ce docker-ce-cli; fi
             fi
        else
             echo ">>> 开始安装最新版本..."
             apt-get install -y --allow-change-held-packages docker-ce docker-ce-cli containerd.io docker-compose-plugin
        fi

        if ! command -v docker &> /dev/null; then
            echo -e "${RED}❌ 安装似乎失败了，请检查上方的错误信息。${NC}"
            return 1
        fi

        mkdir -p /etc/docker
        echo -e "\n${BLUE}>>> 🐳 Docker 镜像加速器配置${NC}"
        echo -e "${YELLOW}提示：由于国内网络原因，建议配置加速器。${NC}"
        echo "请输入加速器地址 (例如: https://xxxx.mirror.aliyuncs.com)"
        echo "如果不知道，直接回车将使用【默认公共源】。"
        
        read -p "地址: " USER_MIRROR < /dev/tty

        if [ -n "$USER_MIRROR" ]; then
            if [[ "$USER_MIRROR" != http* ]]; then USER_MIRROR="https://${USER_MIRROR}"; fi
            # [修改 2] 用户自定义在前，Daocloud 兜底
            MIRRORS="[\"$USER_MIRROR\", \"https://docker.m.daocloud.io\"]"
        else
            # [修改 2] 调整默认源顺序，优先使用南京大学源 (NJU)，移除不稳定源
            MIRRORS="[\"https://docker.nju.edu.cn\",\"https://docker.m.daocloud.io\"]"
        fi

        echo "应用配置..."
        cat > /etc/docker/daemon.json <<EOF
{
  "log-driver": "json-file",
  "log-opts": {"max-size": "100m"},
  "registry-mirrors": $MIRRORS
}
EOF
        systemctl enable docker; systemctl restart docker
        echo -e "${GREEN}🎉 Docker 安装与配置完成!${NC}"
        
        # [新增] 增加对网络/代理的额外提示
        echo -e "${YELLOW}💡 提示：如果镜像拉取仍失败，请检查网络或配置 HTTP 代理。${NC}"
        
        docker info | grep "Registry Mirrors" -A 3
    }

    detect_system
    echo -e "${GREEN}系统检测: $TARGET_OS ($VERSION_CODE) | 架构: $ARCH_TYPE${NC}"
    echo "1) 安装/更新 Docker (默认最新版)"
    echo "2) 安装指定版本 Docker (选择版本)"
    echo "3) 卸载 Docker"
    echo "0) 返回主菜单"
    
    read -p "选择: " ch < /dev/tty
    case $ch in 
        1) install_docker_core "latest" ;; 
        2) install_docker_core "select" ;; 
        3) uninstall_docker ;;
        0) return ;;
    esac
}