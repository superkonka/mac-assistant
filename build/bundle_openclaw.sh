#!/bin/bash
# 将 OpenClaw CLI 打包为独立可执行文件并放入 App Bundle

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OPENCLAW_CORE="$PROJECT_ROOT/openclaw-core"
BUILD_DIR="$SCRIPT_DIR/bundled"
RESOURCES_DIR="$PROJECT_ROOT/mac-app/MacAssistant/MacAssistant/Resources"

echo "🦞 OpenClaw Bundler"
echo "==================="
echo ""

# 检查 openclaw-core 是否存在
if [ ! -d "$OPENCLAW_CORE" ]; then
    echo "❌ openclaw-core 目录不存在: $OPENCLAW_CORE"
    exit 1
fi

# 创建构建目录
mkdir -p "$BUILD_DIR"
mkdir -p "$RESOURCES_DIR"

cd "$OPENCLAW_CORE"

# 检查是否已安装 pkg
if ! command -v pkg &> /dev/null; then
    echo "📦 安装 pkg 打包工具..."
    npm install -g pkg
fi

# 安装依赖
echo "📦 安装 OpenClaw 依赖..."
npm install

# 打包 OpenClaw
echo "🔨 打包 OpenClaw CLI..."

# 检测架构
ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
    TARGET="node18-macos-arm64"
    echo "   目标架构: Apple Silicon (arm64)"
else
    TARGET="node18-macos-x64"
    echo "   目标架构: Intel (x64)"
fi

# 打包
pkg openclaw.mjs --targets "$TARGET" --output "$BUILD_DIR/openclaw" --compress GZip

# 验证打包结果
if [ ! -f "$BUILD_DIR/openclaw" ]; then
    echo "❌ 打包失败"
    exit 1
fi

# 检查文件大小
FILE_SIZE=$(ls -lh "$BUILD_DIR/openclaw" | awk '{print $5}')
echo "✅ 打包成功: $BUILD_DIR/openclaw ($FILE_SIZE)"

# 测试可执行文件
echo "🧪 测试可执行文件..."
if "$BUILD_DIR/openclaw" --version; then
    echo "✅ 可执行文件测试通过"
else
    echo "⚠️  可执行文件测试失败，但继续复制"
fi

# 复制到 Resources
echo "📂 复制到 Resources 目录..."
cp "$BUILD_DIR/openclaw" "$RESOURCES_DIR/"

# 设置权限
chmod +x "$RESOURCES_DIR/openclaw"

echo "✅ OpenClaw 已成功打包到: $RESOURCES_DIR/openclaw"
echo ""
echo "文件信息:"
ls -lh "$RESOURCES_DIR/openclaw"
