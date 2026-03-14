#!/bin/bash
set -e

echo "🚀 MacAssistant 安装脚本"
echo "=========================="

# 检查 Swift 版本
echo "📋 检查 Swift 版本..."
swift --version

# 清理旧构建
echo "🧹 清理旧构建..."
swift package clean 2>/dev/null || true
rm -rf build/MacAssistant.app

# 构建 Release 版本
echo "🔨 构建 Release 版本..."
swift build -c release

# 创建 .app bundle
echo "📦 创建 .app bundle..."
mkdir -p build/MacAssistant.app/Contents/MacOS
mkdir -p build/MacAssistant.app/Contents/Resources

# 复制二进制文件
cp .build/arm64-apple-macosx/release/MacAssistant build/MacAssistant.app/Contents/MacOS/

# 复制 Info.plist
cp MacAssistant/Info.plist build/MacAssistant.app/Contents/

# 复制资源文件（如果存在）
if [ -d "MacAssistant/Resources" ]; then
    cp -R MacAssistant/Resources/* build/MacAssistant.app/Contents/Resources/ 2>/dev/null || true
fi

echo "✅ 构建完成！"
echo ""
echo "📍 应用位置: $(pwd)/build/MacAssistant.app"
echo ""
echo "🎉 启动应用:"
echo "   open build/MacAssistant.app"
echo ""
echo "🔧 或者手动将应用拖到 Applications 文件夹"
