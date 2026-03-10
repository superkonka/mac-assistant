#!/bin/bash
# MacAssistant 一键重启脚本

echo "🚀 MacAssistant 重启脚本"
echo "=========================="

# 1. 关闭当前运行的应用
echo "1️⃣ 关闭当前运行的 MacAssistant..."
pkill -f "MacAssistant" 2>/dev/null
sleep 1

# 2. 进入项目目录
cd /Users/konka/code/mac-assistant/mac-app/MacAssistant

# 3. Clean Build
echo "2️⃣ 清理构建缓存..."
xcodebuild clean -project MacAssistant.xcodeproj -scheme MacAssistant -quiet

# 4. 构建
echo "3️⃣ 开始构建..."
xcodebuild build -project MacAssistant.xcodeproj -scheme MacAssistant -configuration Debug -quiet

if [ $? -eq 0 ]; then
    echo "✅ 构建成功"
    
    # 5. 运行应用
    echo "4️⃣ 启动应用..."
    open build/Debug/MacAssistant.app
    
    echo ""
    echo "=========================="
    echo "✅ MacAssistant 已启动"
    echo "=========================="
else
    echo ""
    echo "=========================="
    echo "❌ 构建失败"
    echo "=========================="
    exit 1
fi
