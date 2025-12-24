#!/bin/bash

# ================= 默认配置 =================
# 你可以在这里修改你最常用的默认值，回车即用
DEFAULT_GITHUB_USER="comengdoc"
DEFAULT_REPO_NAME="linux-toolbox"
TOKEN_FILE=".gh_token"
SCRIPT_NAME=$(basename "$0")
# ===========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ================= [模块 0] 动态配置与初始化 =================

echo -e "${CYAN}=== Git 智能助手配置 ===${NC}"

# 1. 获取项目名称 (支持自定义)
read -p "请输入仓库名称 [默认: ${DEFAULT_REPO_NAME}]: " INPUT_REPO
REPO_NAME=${INPUT_REPO:-$DEFAULT_REPO_NAME}

# 2. 获取用户名 (支持自定义)
read -p "请输入 GitHub 用户 [默认: ${DEFAULT_GITHUB_USER}]: " INPUT_USER
GITHUB_USER=${INPUT_USER:-$DEFAULT_GITHUB_USER}

# 3. 设定工作目录：当前脚本所在目录 + 仓库名
BASE_DIR=$(pwd)
WORK_DIR="${BASE_DIR}/${REPO_NAME}"

echo -e "${YELLOW}👉 目标仓库: ${GITHUB_USER}/${REPO_NAME}${NC}"
echo -e "${YELLOW}👉 本地路径: ${WORK_DIR}${NC}"
echo -e "${CYAN}========================${NC}\n"

# 4. 检查目录与克隆
if [ ! -d "$WORK_DIR" ]; then
    echo -e "${YELLOW}⚠️  本地未检测到目录: ${WORK_DIR}${NC}"
    read -p "是否要从 GitHub 克隆? (y/n): " clone_choice
    
    if [[ "$clone_choice" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}>>> 请输入 GitHub Token (明文输入，回车确认):${NC}"
        read -r -p "Token: " CLONE_TOKEN
        
        if [ -z "$CLONE_TOKEN" ]; then
            echo -e "${RED}❌ Token 不能为空${NC}"; exit 1
        fi

        echo -e "${YELLOW}⏳ 正在克隆...${NC}"
        git clone "https://${CLONE_TOKEN}@github.com/${GITHUB_USER}/${REPO_NAME}.git" "$WORK_DIR"
        
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✅ 克隆成功！${NC}"
            # 保存 Token
            echo "$CLONE_TOKEN" > "${WORK_DIR}/${TOKEN_FILE}"
            chmod 600 "${WORK_DIR}/${TOKEN_FILE}"
        else
            echo -e "${RED}❌ 克隆失败，请检查网络或拼写${NC}"; exit 1
        fi
    else
        echo -e "${RED}❌ 取消操作${NC}"; exit 1
    fi
fi

# 5. 进入目录
cd "$WORK_DIR" || { echo -e "${RED}❌ 无法进入目录${NC}"; exit 1; }

# 6. 配置用户信息 & Token & Ignore
if [ -z "$(git config user.email)" ]; then
    git config user.email "${GITHUB_USER}@users.noreply.github.com"
    git config user.name "${GITHUB_USER}"
fi

# 确保 .gitignore 处理正确
if [ -f .gitignore ] && [ -s .gitignore ] && [ "$(tail -c1 .gitignore | wc -l)" -eq 0 ]; then
    echo "" >> .gitignore
fi
if ! grep -q "$TOKEN_FILE" .gitignore 2>/dev/null; then echo "$TOKEN_FILE" >> .gitignore; fi

# 读取或请求 Token
if [ -f "$TOKEN_FILE" ]; then
    chmod 600 "$TOKEN_FILE"
    GITHUB_TOKEN=$(cat "$TOKEN_FILE")
else
    echo -e "${YELLOW}>>> 未检测到已存 Token，请输入:${NC}"
    read -r -p "Token: " GITHUB_TOKEN
    [ -z "$GITHUB_TOKEN" ] && { echo -e "${RED}Token 不能为空${NC}"; exit 1; }
    echo "$GITHUB_TOKEN" > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"
fi

# 刷新远程地址 (适配可能变更的项目或Token)
git remote set-url origin "https://${GITHUB_TOKEN}@github.com/${GITHUB_USER}/${REPO_NAME}.git"

# ================= [模块 1] 状态扫描 =================
echo -e "${YELLOW}>>> 正在同步云端状态...${NC}"
CURRENT_BRANCH=$(git branch --show-current)
[ -z "$CURRENT_BRANCH" ] && CURRENT_BRANCH="main"

git pull origin "$CURRENT_BRANCH" --rebase >/dev/null 2>&1

mapfile -t change_list < <(git status --short)
UNPUSHED=$(git log origin/"$CURRENT_BRANCH".."$CURRENT_BRANCH" --oneline 2>/dev/null)
HAS_CHANGES=false

echo -e "${CYAN}================ 变动文件列表 =================${NC}"

declare -a file_paths
file_paths=() # 初始化数组

if [ ${#change_list[@]} -gt 0 ]; then
    HAS_CHANGES=true
    i=1
    for item in "${change_list[@]}"; do
        status=${item:0:2}
        filepath=${item:3}
        if [[ "$filepath" == "$SCRIPT_NAME" ]]; then continue; fi
        
        case "$status" in
            " M") icon="📝" ;;
            "??") icon="🆕" ;;
            " D") icon="🗑️" ;;
            *)    icon="⚠️" ;;
        esac
        echo -e "[$i] $icon $filepath"
        file_paths[$i]="$filepath"
        ((i++))
    done
else
    echo -e "   (当前暂无文件变动)"
fi

if [ -n "$UNPUSHED" ]; then
    echo -e "${YELLOW}⚠️  检测到有本地 Commit 尚未推送到云端${NC}"
    HAS_CHANGES=true
fi
echo -e "${CYAN}===============================================${NC}"

# ================= [模块 2] 主菜单 =================
if [ "$HAS_CHANGES" = true ]; then
    echo -e "[a] 📦 上传所有变动 (Standard Push)"
else
    echo -e "${GREEN}✨ 仓库很干净。${NC}"
fi

echo -e "${RED}[f] 🚀 强制推送模式 (Force Push Pro)${NC}" 
echo -e "[q] 🚪 退出脚本"
echo -e "${CYAN}===============================================${NC}"

read -p "请输入选项: " choice
# 如果有变动默认a，没变动默认f
if [ -z "$choice" ]; then
    if [ "$HAS_CHANGES" = true ]; then choice="a"; else choice="f"; fi
fi

# ================= [模块 3] 逻辑分支 =================

# --- 分支 A: 强制推送 (加强验证版) ---
if [[ "$choice" == "f" ]]; then
    echo -e "\n${RED}>>> !!! 警告：即将进行强制推送 !!!${NC}"
    echo -e "${RED}>>> 这将覆盖云端历史。${NC}"
    echo -e "${GREEN}[1] 🌍 强制推送所有 (Force All)${NC}"
    echo -e "${GREEN}[2] 📂 指定文件强推 (Fix File Timestamp)${NC}"
    read -p "选择模式 (默认1): " force_mode
    force_mode=${force_mode:-1}

    # ============ ⚠️ 确认环节 ============
    echo -e "${YELLOW}为了防止误操作，请输入 'yes' 确认强制推送:${NC}"
    read -p "确认吗? " confirm_input
    if [[ "$confirm_input" != "yes" ]]; then
        echo -e "${RED}❌ 确认失败，已取消操作。${NC}"
        exit 1
    fi
    # ====================================
    
    if [ "$force_mode" == "1" ]; then
        git add .
        TARGET_MSG="Force Update All: $(date +'%Y-%m-%d %H:%M:%S')"
        git commit --allow-empty -m "$TARGET_MSG" >/dev/null 2>&1
        echo -e "${YELLOW}📦 正在执行 Force Push...${NC}"
        git push origin "$CURRENT_BRANCH" --force

    elif [ "$force_mode" == "2" ]; then
        mapfile -t all_files < <(git ls-files --cached --others --exclude-standard)
        echo -e "${CYAN}--- 文件列表 ---${NC}"
        j=1; declare -a force_paths
        for f in "${all_files[@]}"; do
            if [[ "$f" == "$SCRIPT_NAME" || "$f" == "$TOKEN_FILE" ]]; then continue; fi
            echo -e "[$j] 📄 $f"
            force_paths[$j]="$f"
            ((j++))
        done
        read -p "选择文件编号: " f_idx
        if [ -n "${force_paths[$f_idx]}" ]; then
            TARGET="${force_paths[$f_idx]}"
            git add "$TARGET"
            git commit --allow-empty -m "Force Update: $TARGET" >/dev/null 2>&1
            echo -e "${YELLOW}📦 正在强制推送 $TARGET ...${NC}"
            git push origin "$CURRENT_BRANCH" --force
        else
            echo -e "${RED}❌ 无效选择${NC}"; exit 1
        fi
    fi

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ 强制推送成功！${NC}"
    else
        echo -e "${RED}❌ 失败！${NC}"
    fi

# --- 分支 B: 标准推送 ---
elif [[ "$choice" =~ ^[Aa]$ ]]; then
    if [ "$HAS_CHANGES" = false ]; then echo -e "${YELLOW}没有需要提交的变动${NC}"; exit 0; fi
    git add .
    echo -e "${YELLOW}>>> 提交说明 (回车默认):${NC}"
    read -p "Msg: " USER_MSG
    MSG=${USER_MSG:-"Update all changes"}
    git commit -m "$MSG"
    
    echo -e "${YELLOW}>>> 正在推送...${NC}"
    git push origin "$CURRENT_BRANCH"

# --- 分支 C: 单文件标准推送 ---
elif [[ "$choice" =~ ^[0-9]+$ ]]; then
    if [ -n "${file_paths[$choice]}" ]; then
        FILE="${file_paths[$choice]}"
        git add "$FILE"
        git commit -m "Update $FILE"
        echo -e "${YELLOW}>>> 正在推送 $FILE ...${NC}"
        git push origin "$CURRENT_BRANCH"
    else
        echo -e "${RED}❌ 无效编号${NC}"
        exit 1
    fi

elif [[ "$choice" == "q" ]]; then
    echo "Bye!"
    exit 0
else
    echo -e "${RED}❌ 无效输入${NC}"
fi