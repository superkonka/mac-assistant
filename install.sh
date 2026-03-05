#!/bin/bash
# Mac Assistant 完整安装脚本

set -e

echo "🤖 Mac Assistant 安装程序"
echo "=========================="
echo ""

# 颜色
color_green='\033[0;32m'
color_red='\033[0;31m'
color_yellow='\033[1;33m'
color_blue='\033[0;34m'
color_nc='\033[0m'

log_info() {
    echo -e "${color_blue}[INFO]${color_nc} $1"
}

log_success() {
    echo -e "${color_green}[SUCCESS]${color_nc} $1"
}

log_warn() {
    echo -e "${color_yellow}[WARN]${color_nc} $1"
}

log_error() {
    echo -e "${color_red}[ERROR]${color_nc} $1"
}

PROJECT_DIR="$HOME/code/mac-assistant"

# 检查系统
log_info "检查系统环境..."

if [[ "$OSTYPE" != "darwin"* ]]; then
    log_error "此程序仅支持 macOS"
    exit 1
fi

log_success "✓ macOS 系统"

# 检查依赖
log_info "检查依赖..."

if ! command -v python3 &> /dev/null; then
    log_error "需要先安装 Python3"
    log_info "建议: brew install python3"
    exit 1
fi

PYTHON_VERSION=$(python3 --version 2>&1 | awk '{print $2}')
log_success "✓ Python $PYTHON_VERSION"

if ! command -v pip3 &> /dev/null; then
    log_error "需要先安装 pip3"
    exit 1
fi

log_success "✓ pip3"

# 检查 Xcode 命令行工具
if ! command -v xcode-select &> /dev/null; then
    log_warn "⚠️  未安装 Xcode 命令行工具"
    log_info "运行: xcode-select --install"
fi

# 创建项目目录
log_info "创建项目目录..."
mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR"

# 设置后端
log_info ""
log_info "📦 设置后端服务..."

if [ ! -d "backend/.venv" ]; then
    log_info "创建 Python 虚拟环境..."
    cd backend
    python3 -m venv .venv
    cd ..
fi

log_info "安装 Python 依赖..."
cd backend
source .venv/bin/activate
pip install -q --upgrade pip
pip install -q -r requirements.txt
cd ..

log_success "✓ 后端设置完成"

# 安装守护进程
log_info ""
log_info "🔧 安装后台守护进程..."

cd daemon
chmod +x service-manager.sh

# 安装并启动服务
./service-manager.sh install

log_success "✓ 守护进程安装完成"
cd ..

# 检查服务状态
log_info ""
log_info "检查服务状态..."
sleep 2

if curl -s http://127.0.0.1:8765/health >/dev/null 2>&1; then
    log_success "✓ 后台服务运行正常"
else
    log_warn "⚠️  服务可能需要几秒钟启动"
fi

# 检查可选依赖
log_info ""
log_info "🔍 检查可选依赖..."

if command -v openclaw &> /dev/null; then
    log_success "✓ OpenClaw 已安装"
else
    log_warn "⚠️  OpenClaw 未安装 (可选)"
    log_info "  安装: https://github.com/openclaw/openclaw"
fi

if command -v kimi &> /dev/null; then
    log_success "✓ Kimi CLI 已安装"
else
    log_warn "⚠️  Kimi CLI 未安装 (可选)"
    log_info "  安装: pip install kimi-cli"
fi

# 完成
echo ""
echo "=========================="
log_success "🎉 Mac Assistant 安装完成!"
echo ""
echo "使用方式:"
echo ""
echo "1. 启动 Mac App:"
echo "   open mac-app/MacAssistant/MacAssistant.xcodeproj"
echo "   用 Xcode 编译运行"
echo ""
echo "2. 管理后台服务:"
echo "   cd ~/code/mac-assistant/daemon"
echo "   ./service-manager.sh {start|stop|restart|status|logs}"
echo ""
echo "3. 快捷键:"
echo "   ⌘ ⇧ Space  - 打开/关闭面板"
echo "   ⌘ ⇧ 1      - 截图并询问 AI"
echo "   ⌘ ⇧ V      - 询问剪贴板内容"
echo ""
echo "4. 查看日志:"
echo "   tail -f ~/code/mac-assistant/daemon/backend.log"
echo ""
echo "=========================="
