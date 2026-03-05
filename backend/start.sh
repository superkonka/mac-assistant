#!/bin/bash
# 启动 Mac Assistant 后端服务

cd "$(dirname "$0")"

# 检查虚拟环境
if [ ! -d ".venv" ]; then
    echo "创建虚拟环境..."
    python3 -m venv .venv
fi

# 激活虚拟环境
source .venv/bin/activate

# 安装依赖
echo "检查依赖..."
pip install -q -r requirements.txt

# 启动服务
echo "🚀 启动 Mac Assistant 服务..."
python3 main.py
