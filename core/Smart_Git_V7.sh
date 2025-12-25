#!/bin/bash

# ================= 默认配置 =================
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

# ================= [函数] 获取 Token =================
function get_token() {
    local check_dir="$1"
    local token_path="${check_dir}/${TOKEN_FILE}"
    
    # 1. 优先读取当前目录或目标目录的文件
    if [ -f "$token_path" ]; then
        chmod 600 "$token_path"
        cat "$token_path"
        return
    elif [ -f "./$TOKEN_FILE" ]; then
        chmod 600 "./$TOKEN_FILE"
        cat "./$TOKEN_FILE"
        return
    fi

    # 2. 交互式输入
    echo -e "${YELLOW}>>> 未检测到本地 Token 文件${NC}" >&2
    echo -e "${YELLOW}>>> 请输入 GitHub Token (仅用于当前操作，将保存到本地):${NC}" >&2
    
    read -r -p "Token: " INPUT_TOKEN
    
    if [ -z "$INPUT_TOKEN" ]; then
        echo -e "${RED}❌ Token 不能为空${NC}" >&2
        exit 1
    fi
    
    echo "$INPUT_TOKEN"
}

# ================= [函数] 路径清洗 =================
function clean_path() {
    local path="$1"
    # 去除首尾的双引号和单引号（处理终端拖拽路径的情况）
    path="${path%\"}"
    path="${path#\"}"
    path="${path%\'}"
    path="${path#\'}"
    echo "$path"
}

# ================= 主菜单 =================
clear
echo -e "${CYAN}=== Git 智能助手 V7 (稳定版) ===${NC}"
echo -e "${GREEN}[1] 🛠️  管理/同步现有项目 (默认: ${DEFAULT_REPO_NAME})${NC}"
echo -e "${GREEN}[2] 📤  发布本地文件夹为新仓库 (Init & Push)${NC}"
echo -e "${CYAN}========================${NC}"
read -p "请选择模式 [默认1]: " MODE_CHOICE
MODE_CHOICE=${MODE_CHOICE:-1}

# =======================================================
#  模式 2: 上传新项目 (发布模式)
# =======================================================
if [[ "$MODE_CHOICE" == "2" ]]; then
    echo -e "\n${CYAN}>>> 进入新项目发布模式${NC}"
    
    # 1. 获取并清洗路径
    read -e -p "请输入本地文件夹路径 (支持拖拽): " RAW_DIR
    LOCAL_DIR=$(clean_path "$RAW_DIR")
    
    if [ ! -d "$LOCAL_DIR" ]; then
        echo -e "${RED}❌ 目录不存在: $LOCAL_DIR${NC}"; exit 1
    fi
    
    cd "$LOCAL_DIR" || exit
    echo -e "${YELLOW}👉 当前工作目录: $(pwd)${NC}"

    # 2. 获取 Token
    GITHUB_TOKEN=$(get_token "$(pwd)")
    if [ -z "$GITHUB_TOKEN" ]; then echo -e "${RED}❌ Token 无效${NC}"; exit 1; fi

    # 3. 命名项目
    DIR_NAME=$(basename "$(pwd)")
    read -p "请输入新仓库名称 [默认: ${DIR_NAME}]: " NEW_REPO_NAME
    NEW_REPO_NAME=${NEW_REPO_NAME:-$DIR_NAME}
    
    read -p "请输入 GitHub 用户名 [默认: ${DEFAULT_GITHUB_USER}]: " NEW_USER
    NEW_USER=${NEW_USER:-$DEFAULT_GITHUB_USER}

    # 4. API 建库 (增强错误处理)
    echo -e "${YELLOW}☁️  正在 GitHub 创建仓库 '${NEW_REPO_NAME}' ...${NC}"
    
    API_RESPONSE=$(curl -s -w "\n%{http_code}" -H "Authorization: token ${GITHUB_TOKEN}" \
        -d "{\"name\":\"${NEW_REPO_NAME}\", \"private\": false}" \
        "https://api.github.com/user/repos")

    HTTP_CODE=$(echo "$API_RESPONSE" | tail -n1)
    RESPONSE_BODY=$(echo "$API_RESPONSE" | sed '$d')

    if [[ "$HTTP_CODE" == "201" ]]; then
        echo -e "${GREEN}✅ 远程仓库创建成功!${NC}"
    elif echo "$RESPONSE_BODY" | grep -q "name already exists"; then
        echo -e "${YELLOW}⚠️  远程仓库已存在，尝试直接关联...${NC}"
    elif [[ "$HTTP_CODE" == "401" ]]; then
        echo -e "${RED}❌ 鉴权失败 (HTTP 401)。请检查 Token 是否有效。${NC}"
        exit 1
    else
        echo -e "${RED}❌ 创建失败 (HTTP $HTTP_CODE)${NC}"
        echo "API 返回: $RESPONSE_BODY"
        read -p "是否强制继续尝试本地推送? (y/n): " force_continue
        if [[ "$force_continue" != "y" ]]; then exit 1; fi
    fi

    # 5. 初始化 Git
    if [ ! -d ".git" ]; then
        git init
        git branch -M main
        echo -e "${YELLOW}⚙️  已初始化 Git 仓库${NC}"
    fi

    # 6. 安全配置 Token 与 Ignore
    if ! grep -q "$TOKEN_FILE" .gitignore 2>/dev/null; then 
        echo "$TOKEN_FILE" >> .gitignore
        echo -e "${YELLOW}🛡️  Token文件已加入 .gitignore${NC}"
    fi
    echo "$GITHUB_TOKEN" > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"

    # 7. 关联与推送
    REMOTE_URL="https://${GITHUB_TOKEN}@github.com/${NEW_USER}/${NEW_REPO_NAME}.git"
    git remote remove origin 2>/dev/null
    git remote add origin "$REMOTE_URL"

    echo -e "${YELLOW}📦 正在执行初次推送...${NC}"
    git add .
    git commit -m "Initial commit via Smart Git V7" >/dev/null 2>&1
    
    if git push -u origin main; then
        echo -e "\n${GREEN}🎉 发布成功: https://github.com/${NEW_USER}/${NEW_REPO_NAME}${NC}"
    else
        echo -e "\n${RED}❌ 推送失败。请检查网络或 Token 权限 (需勾选 repo 权限)。${NC}"
    fi
    exit 0
fi

# =======================================================
#  模式 1: 管理现有项目 (维护模式)
# =======================================================

echo -e "\n${CYAN}=== 项目管理模式 ===${NC}"

# 1. 基础信息配置
read -p "请输入仓库名称 [默认: ${DEFAULT_REPO_NAME}]: " INPUT_REPO
REPO_NAME=${INPUT_REPO:-$DEFAULT_REPO_NAME}

read -p "请输入 GitHub 用户 [默认: ${DEFAULT_GITHUB_USER}]: " INPUT_USER
GITHUB_USER=${INPUT_USER:-$DEFAULT_GITHUB_USER}

BASE_DIR=$(pwd)
WORK_DIR="${BASE_DIR}/${REPO_NAME}"

echo -e "${YELLOW}👉 本地路径: ${WORK_DIR}${NC}"

# 2. 克隆逻辑
if [ ! -d "$WORK_DIR" ]; then
    echo -e "${YELLOW}⚠️  目录不存在，准备克隆...${NC}"
    read -p "确认克隆 ${GITHUB_USER}/${REPO_NAME}? (y/n): " clone_confirm
    if [[ "$clone_confirm" != "y" ]]; then echo "取消操作"; exit 0; fi

    echo -e "${YELLOW}>>> 请输入 Token (第一次需手动输入):${NC}"
    read -r -p "Token: " CLONE_TOKEN
    [ -z "$CLONE_TOKEN" ] && exit 1

    git clone "https://${CLONE_TOKEN}@github.com/${GITHUB_USER}/${REPO_NAME}.git" "$WORK_DIR"
    if [ $? -eq 0 ]; then
        echo "$CLONE_TOKEN" > "${WORK_DIR}/${TOKEN_FILE}"
        chmod 600 "${WORK_DIR}/${TOKEN_FILE}"
        echo -e "${GREEN}✅ 克隆完成${NC}"
    else
        echo -e "${RED}❌ 克隆失败${NC}"; exit 1
    fi
fi

cd "$WORK_DIR" || exit 1

# 3. 环境与 Token 刷新
if [ -z "$(git config user.email)" ]; then
    git config user.email "${GITHUB_USER}@users.noreply.github.com"
    git config user.name "${GITHUB_USER}"
fi

# 确保 ignore 存在
touch .gitignore
if ! grep -q "$TOKEN_FILE" .gitignore; then echo "$TOKEN_FILE" >> .gitignore; fi

# 读取 Token
if [ -f "$TOKEN_FILE" ]; then
    chmod 600 "$TOKEN_FILE"
    GITHUB_TOKEN=$(cat "$TOKEN_FILE")
else
    # 补救措施：如果文件丢了，再问一次
    GITHUB_TOKEN=$(get_token "$(pwd)")
    echo "$GITHUB_TOKEN" > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"
fi

# 刷新 Remote URL (确保 Token 是最新的)
git remote set-url origin "https://${GITHUB_TOKEN}@github.com/${GITHUB_USER}/${REPO_NAME}.git"


# ================= [模块] 智能同步 (稳定性核心优化) =================
echo -e "${YELLOW}🔄 正在同步云端变动 (Pull --rebase)...${NC}"

CURRENT_BRANCH=$(git branch --show-current)
[ -z "$CURRENT_BRANCH" ] && CURRENT_BRANCH="main"

# 捕获 Pull 输出，同时允许错误信息显示
PULL_OUTPUT=$(git pull origin "$CURRENT_BRANCH" --rebase 2>&1)
PULL_EXIT_CODE=$?

if [ $PULL_EXIT_CODE -ne 0 ]; then
    echo -e "${RED}❌ 同步失败！检测到潜在冲突或网络问题。${NC}"
    echo -e "${CYAN}--- Git 输出 ---${NC}"
    echo "$PULL_OUTPUT"
    echo -e "${CYAN}----------------${NC}"
    
    # 检测是否因为冲突导致 Rebase 挂起
    if echo "$PULL_OUTPUT" | grep -q "conflict"; then
        echo -e "${RED}⚠️  检测到文件冲突！${NC}"
        echo -e "${YELLOW}正在自动中止 Rebase 以保护本地文件...${NC}"
        git rebase --abort 2>/dev/null
        echo -e "${RED}>>> 请手动解决冲突后再运行脚本。${NC}"
    else
        echo -e "${YELLOW}非冲突错误 (可能是网络原因)，继续尝试显示本地状态...${NC}"
    fi
    # 可以在这里 exit，或者允许用户尝试强制推送(如果不care云端)
    # 这里的逻辑是：如果Pull失败，很可能本地和云端不一致，继续执行常规Push会报错。
    # 但脚本允许 Force Push，所以我们不强制退出，只做警告。
    echo -e "${YELLOW}⚠️  警告：云端同步未成功完成，常规推送可能会失败。${NC}"
else
    if echo "$PULL_OUTPUT" | grep -q "Already up to date"; then
        : # Do nothing
    else
        echo -e "${GREEN}✅ 云端更新已同步至本地${NC}"
    fi
fi

# ================= [模块] 状态检测 =================
mapfile -t change_list < <(git status --short)
UNPUSHED=$(git log origin/"$CURRENT_BRANCH".."$CURRENT_BRANCH" --oneline 2>/dev/null)
HAS_CHANGES=false

echo -e "\n${CYAN}================ 变动概览 =================${NC}"
declare -a file_paths
file_paths=()

if [ ${#change_list[@]} -gt 0 ]; then
    HAS_CHANGES=true
    i=1
    for item in "${change_list[@]}"; do
        status=${item:0:2}
        filepath=${item:3}
        # 排除脚本自身
        if [[ "$filepath" == "$SCRIPT_NAME" ]]; then continue; fi
        
        case "$status" in
            " M") icon="📝" ;; # Modified
            "??") icon="🆕" ;; # Untracked
            " D") icon="🗑️" ;; # Deleted
            "A ") icon="➕" ;; # Added
            *)    icon="⚠️" ;;
        esac
        echo -e "[$i] $icon $filepath"
        file_paths[$i]="$filepath"
        ((i++))
    done
else
    echo -e "   (工作区干净)"
fi

if [ -n "$UNPUSHED" ]; then
    echo -e "${YELLOW}📦 有本地 Commit 等待推送${NC}"
    HAS_CHANGES=true
fi
echo -e "${CYAN}===========================================${NC}"

# ================= [模块] 操作菜单 =================
if [ "$HAS_CHANGES" = true ]; then
    echo -e "[a] 🚀 推送所有变动 (Add + Commit + Push)"
else
    echo -e "${GREEN}✨ 暂无新变动${NC}"
fi

echo -e "${RED}[f] 🔥 强制推送 (Force Push) - 慎用${NC}" 
echo -e "[q] 🚪 退出"
echo -e "${CYAN}===========================================${NC}"

read -p "请输入选项: " choice
# 默认行为
if [ -z "$choice" ]; then
    if [ "$HAS_CHANGES" = true ]; then choice="a"; else choice="q"; fi
fi

# ================= [模块] 执行逻辑 =================
if [[ "$choice" == "f" ]]; then
    # --- 改进的强制推送警告 ---
    echo -e "\n${RED}>>> 🛑 高危操作警告 🛑 <<<${NC}"
    echo -e "${RED}强制推送(Force Push)会覆盖云端代码。${NC}"
    echo -e "${YELLOW}场景：1. 仅你一人开发 2. 修补之前的错误提交${NC}"
    echo -e "${YELLOW}切勿在团队协作仓库使用！${NC}"
    
    read -p "请输入 'yes' 确认覆盖云端: " confirm_input
    if [[ "$confirm_input" != "yes" ]]; then
        echo -e "${RED}已取消。${NC}"; exit 1
    fi
    
    echo -e "${GREEN}[1] 覆盖推送所有 (Force All)${NC}"
    echo -e "${GREEN}[2] 仅修复特定文件 (Fix Timestamp)${NC}"
    read -p "选择模式 [1]: " force_mode
    force_mode=${force_mode:-1}

    if [ "$force_mode" == "1" ]; then
        git add .
        git commit --allow-empty -m "Force Update: $(date +'%Y-%m-%d %H:%M:%S')" >/dev/null 2>&1
        echo -e "${YELLOW}🔥 正在强制覆盖云端...${NC}"
        git push origin "$CURRENT_BRANCH" --force
    elif [ "$force_mode" == "2" ]; then
        # ... (保留原有的单文件强推逻辑，适合特定场景) ...
        read -p "请输入要强推的文件名 (需完整路径): " TARGET_FILE
        if [ -f "$TARGET_FILE" ]; then
            git add "$TARGET_FILE"
            git commit --allow-empty -m "Force Update: $TARGET_FILE"
            git push origin "$CURRENT_BRANCH" --force
        else
            echo "文件不存在"; exit 1
        fi
    fi
    
    if [ $? -eq 0 ]; then echo -e "${GREEN}✅ 强制推送完成${NC}"; else echo -e "${RED}❌ 失败${NC}"; fi

elif [[ "$choice" =~ ^[Aa]$ ]]; then
    if [ "$HAS_CHANGES" = false ]; then echo "无需推送"; exit 0; fi
    
    git add .
    echo -e "${YELLOW}>>> 提交说明 (回车默认: Update):${NC}"
    read -p "Msg: " USER_MSG
    MSG=${USER_MSG:-"Update $(date +'%m-%d')"}
    
    git commit -m "$MSG"
    
    echo -e "${YELLOW}🚀 正在推送...${NC}"
    if git push origin "$CURRENT_BRANCH"; then
        echo -e "${GREEN}✅ 推送成功！${NC}"
    else
        echo -e "${RED}❌ 推送失败 (可能是云端有新变动，建议先尝试重启脚本进行同步)${NC}"
    fi

elif [[ "$choice" =~ ^[0-9]+$ ]]; then
    # 单文件推送逻辑
    if [ -n "${file_paths[$choice]}" ]; then
        FILE="${file_paths[$choice]}"
        git add "$FILE"
        git commit -m "Update $FILE"
        echo -e "${YELLOW}🚀 推送单文件: $FILE ...${NC}"
        git push origin "$CURRENT_BRANCH"
    else
        echo -e "${RED}❌ 无效编号${NC}"
    fi

elif [[ "$choice" == "q" ]]; then
    echo "Bye!"
    exit 0
fi