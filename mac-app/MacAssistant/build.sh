#!/bin/bash

# MacAssistant 构建脚本

set -e

echo "🔨 开始构建 MacAssistant..."

# 进入项目目录
cd "$(dirname "$0")"

# 检查 xcodebuild 是否可用
if ! command -v xcodebuild &> /dev/null; then
    echo "❌ 错误: 需要安装 Xcode Command Line Tools"
    echo "运行: xcode-select --install"
    exit 1
fi

# 创建 build 目录
mkdir -p build

# 生成 Xcode 项目（如果没有）
if [ ! -d "MacAssistant.xcodeproj" ]; then
    echo "📁 创建 Xcode 项目..."
    
    # 使用 swift package 生成 Xcode 项目
    if command -v swift &> /dev/null; then
        swift package generate-xcodeproj 2>/dev/null || true
    fi
fi

# 构建应用
echo "🔨 构建应用..."
xcodebuild \
    -project MacAssistant.xcodeproj \
    -scheme MacAssistant \
    -configuration Release \
    -derivedDataPath build/DerivedData \
    -archivePath build/MacAssistant.xcarchive \
    archive \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    2>&1 | tee build/build.log

# 导出应用
echo "📦 导出应用..."

# 归档产物固定在 xcarchive 中，避免误拿到旧的 build/MacAssistant.app
APP_PATH="build/MacAssistant.xcarchive/Products/Applications/MacAssistant.app"

if [ -z "$APP_PATH" ]; then
    echo "❌ 构建失败，未找到 .app 文件"
    echo "查看 build/build.log 了解详情"
    exit 1
fi

echo "✅ 构建成功!"
echo "📍 应用位置: $APP_PATH"

# 复制到输出目录
OUTPUT_APP_PATH="build/MacAssistant.app"
rm -rf "$OUTPUT_APP_PATH"
ditto "$APP_PATH" "$OUTPUT_APP_PATH"

echo ""
echo "🎉 构建完成!"
echo "📍 应用: $(pwd)/$OUTPUT_APP_PATH"
echo ""
echo "安装方式:"
echo "  1. 将 build/MacAssistant.app 拖到 Applications 文件夹，替换旧版本"
echo "  2. 或在终端运行: ditto build/MacAssistant.app /Applications/MacAssistant.app"
