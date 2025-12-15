# Modular Linux Toolbox

这是一个自动化重构的模块化系统管理脚本。

## 目录结构

- `main.sh`: 脚本入口，负责下载并加载模块。
- `core/`: 存放各个具体功能的脚本文件。

## 如何上传到 GitHub

1. 修改 `main.sh` 中的 `REPO_URL` 变量，将其中的 `YOUR_USERNAME/YOUR_REPO` 替换为你的真实信息。
2. 在本目录执行 git 命令上传。

## 如何使用

```bash
bash <(curl -s "https://raw.githubusercontent.com/comengdoc/linux-toolbox/main/main.sh?v=$(date +%s)")
``` 
