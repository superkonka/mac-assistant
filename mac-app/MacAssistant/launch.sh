#!/bin/bash

# MacAssistant 启动脚本

echo "🚀 启动 MacAssistant..."

# 检查应用是否存在
if [ ! -d "/Applications/MacAssistant.app" ]; then
    echo "❌ 错误: 应用未安装在 /Applications"
    exit 1
fi

# 启动应用
open /Applications/MacAssistant.app

echo "✅ MacAssistant 已启动"
echo ""
echo "📍 使用方式:"
echo "  - 查看状态栏的 🧠 图标"
echo "  - 点击图标打开菜单"
echo "  - 选择 '查看日志' 查看运行日志"
echo ""
