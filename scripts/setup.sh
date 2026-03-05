#!/bin/bash
# Mac Assistant 一键安装脚本

echo "🚀 Mac Assistant 安装程序"
echo "=========================="
echo ""

# 检查 Python
if ! command -v python3 &> /dev/null; then
    echo "❌ 需要先安装 Python3"
    echo "   建议: brew install python3"
    exit 1
fi

echo "✅ Python3 已安装"

# 检查 pip
if ! command -v pip3 &> /dev/null; then
    echo "❌ 需要先安装 pip3"
    exit 1
fi

echo "✅ pip3 已安装"

# 创建项目目录
PROJECT_DIR="$HOME/code/mac-assistant"
mkdir -p "$PROJECT_DIR"

cd "$PROJECT_DIR"

# 设置后端
echo ""
echo "📦 设置后端服务..."
cd backend

# 创建虚拟环境
if [ ! -d ".venv" ]; then
    echo "创建虚拟环境..."
    python3 -m venv .venv
fi

# 激活虚拟环境
source .venv/bin/activate

# 安装依赖
echo "安装依赖..."
pip install -r requirements.txt

echo "✅ 后端设置完成"

# 检查依赖项
echo ""
echo "🔍 检查可选依赖..."

# 检查 OpenClaw
if command -v openclaw &> /dev/null; then
    echo "✅ OpenClaw 已安装"
else
    echo "⚠️  OpenClaw 未安装 (可选)"
    echo "   安装: https://github.com/openclaw/openclaw"
fi

# 检查 Kimi CLI
if command -v kimi &> /dev/null; then
    echo "✅ Kimi CLI 已安装"
else
    echo "⚠️  Kimi CLI 未安装 (可选)"
    echo "   安装: pip install kimi-cli"
fi

echo ""
echo "=========================="
echo "✅ 安装完成!"
echo ""
echo "使用方式:"
echo "  1. 启动后端: cd ~/code/mac-assistant/backend && ./start.sh"
echo "  2. 打开 Xcode 项目: open ~/code/mac-assistant/mac-app/MacAssistant/MacAssistant.xcodeproj"
echo "  3. 构建并运行 Mac 应用"
echo ""
echo "快捷键:"
echo "  ⌘ ⇧ Space  - 打开面板"
echo "  ⌘ ⇧ 1      - 截图询问"
echo ""
