#!/bin/bash
#
# Mac Assistant 重启脚本
# 停止当前运行的应用并重新启动最新构建版本
#

echo "🔄 正在重启 Mac Assistant..."

# 停止所有 MacAssistant 进程
echo "📍 停止当前运行的应用..."
pkill -9 MacAssistant 2>/dev/null || true
sleep 1

# 确保完全停止
if pgrep -x "MacAssistant" > /dev/null; then
    echo "强制停止中..."
    killall -9 MacAssistant 2>/dev/null || true
    sleep 1
fi

echo "✅ 已停止"
echo ""

# 进入项目目录
cd "$(dirname "$0")/../mac-app/MacAssistant" || exit 1

echo "🔨 正在构建..."

# 检查是否有 Xcode 命令行工具
if command -v xcodebuild &> /dev/null; then
    # 使用 Xcode 构建 .app 版本
    echo "使用 Xcode 构建..."
    xcodebuild -project MacAssistant.xcodeproj \
               -scheme MacAssistant \
               -configuration Debug \
               -derivedDataPath build/DerivedData \
               build
    
    if [ $? -eq 0 ]; then
        echo "✅ 构建成功"
        echo ""
        echo "🚀 启动应用..."
        open "build/DerivedData/Build/Products/Debug/MacAssistant.app"
    else
        echo "❌ Xcode 构建失败，尝试使用 Swift Package Manager..."
        swift build
        if [ $? -eq 0 ]; then
            echo "✅ SPM 构建成功"
            echo "🚀 启动应用..."
            .build/debug/MacAssistant &
        else
            echo "❌ 构建失败"
            exit 1
        fi
    fi
else
    # 使用 Swift Package Manager
    echo "使用 Swift Package Manager 构建..."
    swift build
    
    if [ $? -eq 0 ]; then
        echo "✅ 构建成功"
        echo ""
        echo "🚀 启动应用..."
        .build/debug/MacAssistant &
    else
        echo "❌ 构建失败"
        exit 1
    fi
fi

echo ""
echo "✅ 应用已启动"
echo ""
echo "📋 查看日志: tail -f ~/Documents/MacAssistant/Logs/mac-assistant-current.log"
