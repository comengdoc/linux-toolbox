#!/bin/bash
function module_1panel() {
    while true; do
        clear
        echo -e "${GREEN}=========================================${NC}"
        echo -e "       📦 服务器面板 & 代理工具安装"
        echo -e "${GREEN}=========================================${NC}"
        echo -e "1. 安装/更新 1Panel 面板 (v2)"
        echo -e "2. 安装/管理 ShellCrash (Juewuy版)"
        echo -e "3. 安装/管理 SB-Shell (Sing-Box)"
        echo -e "-----------------------------------------"
        echo -e "0. 返回主菜单"
        echo -e "${GREEN}=========================================${NC}"
        
        # 修改提示范围 [0-3]
        read -p "请选择操作 [0-3]: " sub_choice < /dev/tty

        case "$sub_choice" in
            1)
                echo -e "\n${YELLOW}>>> 正在启动 1Panel 安装程序...${NC}"
                if ! command -v curl &> /dev/null; then
                    echo -e "${YELLOW}未找到 curl，正在安装...${NC}"
                    apt-get update -qq && apt-get install -y -qq curl
                fi
                
                # 保持原有的输入重定向修复
                bash <(curl -sSL https://resource.fit2cloud.com/1panel/package/v2/quick_start.sh) < /dev/tty
                
                echo -e "\n${GREEN}按回车键返回...${NC}"
                read -r < /dev/tty
                ;;
            2)
                echo -e "\n${YELLOW}>>> 正在启动 ShellCrash 安装程序...${NC}"
                
                export url='https://testingcf.jsdelivr.net/gh/juewuy/ShellCrash@master' && \
                wget -q --no-check-certificate -O /tmp/install.sh $url/install.sh && \
                bash /tmp/install.sh < /dev/tty && \
                . /etc/profile &> /dev/null
                
                echo -e "\n${GREEN}ShellCrash 脚本执行完毕。${NC}"
                echo -e "按回车键返回..."
                read -r < /dev/tty
                ;;
            3)
                # === 新增 SB-Shell 安装选项 ===
                echo -e "\n${YELLOW}>>> 正在启动 SB-Shell 安装程序...${NC}"
                
                # 同样加上 < /dev/tty 确保脚本内的菜单交互正常
                bash <(curl -sL https://raw.githubusercontent.com/comengdoc/sb-shell/main/install.sh) < /dev/tty
                
                echo -e "\n${GREEN}SB-Shell 脚本执行完毕。${NC}"
                echo -e "按回车键返回..."
                read -r < /dev/tty
                ;;
            0)
                return 0
                ;;
            *)
                echo -e "${RED}无效选项，请重新选择。${NC}"
                sleep 1
                ;;
        esac
    done
}