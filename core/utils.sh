#!/bin/bash
# ==================================================
# 基础工具模块 - v3.2 (智能同步版)
# ==================================================

# --- 1. 全局颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- 2. 全局变量 ---
# 默认导出 GH_PROXY，供子模块直接使用
export GH_PROXY=""

# --- 3. 通用日志函数 (让代码更简洁) ---
function log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

function log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

function log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

function log_step() {
    echo -e "${BLUE}>>> $1${NC}"
}

# --- 4. 权限检查 ---
function check_root() {
    if [ "$(id -u)" != "0" ]; then
       log_error "必须使用 root 权限运行此脚本。"
       exit 1
    fi
}

# --- 5. 代理智能同步 (核心优化) ---
# 作用: 自动接收 main.sh 传来的 PROXY_PREFIX，不再重复询问用户
function sync_proxy_config() {
    local parent_proxy="$1"
    
    if [ -n "$parent_proxy" ]; then
        GH_PROXY="$parent_proxy"
        # 很多子脚本习惯用 export 的变量
        export GH_PROXY
        # 仅在调试模式或 verbose 模式下显示，平时静默
        # log_info "已自动同步 GitHub 代理: $GH_PROXY"
    else
        GH_PROXY=""
        export GH_PROXY
    fi
}

# --- 6. 手动代理配置 (仅在需要时调用) ---
# 保留此函数，供“网络设置”菜单单独调用，初始化时不自动调用
function configure_proxy_interactive() {
    local DEFAULT_PROXY="https://gh-proxy.com/"
    
    clear
    echo -e "${BLUE}====================================================${NC}"
    echo -e "       🌐 GitHub 加速代理配置 (Proxy Setup)"
    echo -e "${BLUE}====================================================${NC}"
    echo -e "当前生效代理: ${GREEN}${GH_PROXY:-直连}${NC}"
    echo -e "默认推荐代理: ${GREEN}${DEFAULT_PROXY}${NC}"
    echo "----------------------------------------------------"
    
    read -p "请输入新代理 (回车维持原状，输入 'n' 清空): " USER_INPUT < /dev/tty

    if [ -z "$USER_INPUT" ]; then
        # 如果当前为空且用户回车，则使用默认；如果当前有值，则保持
        if [ -z "$GH_PROXY" ]; then
            GH_PROXY="$DEFAULT_PROXY"
        fi
        log_info "保持/使用代理: ${GH_PROXY}"
    elif [[ "$USER_INPUT" == "n" || "$USER_INPUT" == "N" ]]; then
        GH_PROXY=""
        log_warn "已切换为直连模式"
    else
        if [[ "$USER_INPUT" != */ ]]; then
            GH_PROXY="${USER_INPUT}/"
        else
            GH_PROXY="$USER_INPUT"
        fi
        log_info "已设置自定义代理: ${GH_PROXY}"
    fi
    export GH_PROXY
    sleep 1
}