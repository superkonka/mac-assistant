#!/bin/bash
# Mac Assistant 配置验证脚本

echo "🔍 Mac Assistant 配置验证"
echo "==========================="
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ERRORS=0
WARNINGS=0

check_file() {
    if [ -f "$1" ]; then
        echo "✅ $2"
        return 0
    else
        echo "❌ $2 - 文件不存在: $1"
        ((ERRORS++))
        return 1
    fi
}

check_dir() {
    if [ -d "$1" ]; then
        echo "✅ $2"
        return 0
    else
        echo "❌ $2 - 目录不存在: $1"
        ((ERRORS++))
        return 1
    fi
}

echo "📂 检查项目结构..."
check_dir "$PROJECT_ROOT/openclaw-core" "OpenClaw Core 目录"
check_dir "$PROJECT_ROOT/mac-app/MacAssistant/MacAssistant" "Mac App 源代码目录"
check_file "$PROJECT_ROOT/mac-app/MacAssistant/MacAssistant.xcodeproj/project.pbxproj" "Xcode 项目文件"

echo ""
echo "📜 检查构建脚本..."
check_file "$PROJECT_ROOT/build/bundle_openclaw.sh" "OpenClaw 打包脚本"
check_file "$PROJECT_ROOT/build/build_dmg.sh" "DMG 构建脚本"

# 检查脚本权限
echo ""
echo "🔐 检查脚本权限..."
for script in "$PROJECT_ROOT/build/bundle_openclaw.sh" "$PROJECT_ROOT/build/build_dmg.sh"; do
    if [ -x "$script" ]; then
        echo "✅ $(basename $script) 有执行权限"
    else
        echo "⚠️  $(basename $script) 缺少执行权限，正在修复..."
        chmod +x "$script"
        echo "   已修复"
        ((WARNINGS++))
    fi
done

echo ""
echo "📦 检查新实现文件..."
check_file "$PROJECT_ROOT/mac-app/MacAssistant/MacAssistant/Services/DependencyManager.swift" "DependencyManager.swift"
check_file "$PROJECT_ROOT/mac-app/MacAssistant/MacAssistant/Views/Onboarding/OnboardingView.swift" "OnboardingView.swift"

echo ""
echo "🦞 检查 OpenClaw 资源..."
if [ -f "$PROJECT_ROOT/mac-app/MacAssistant/MacAssistant/Resources/openclaw" ]; then
    echo "✅ OpenClaw 已打包在 Resources 中"
    ls -lh "$PROJECT_ROOT/mac-app/MacAssistant/MacAssistant/Resources/openclaw" | awk '{print "   大小: " $5}'
else
    echo "⚠️  OpenClaw 未打包"
    echo "   运行 ./build/bundle_openclaw.sh 进行打包"
    ((WARNINGS++))
fi

echo ""
echo "🔧 检查 Node.js 和 pkg..."
if command -v node &> /dev/null; then
    NODE_VERSION=$(node --version)
    echo "✅ Node.js 已安装: $NODE_VERSION"
else
    echo "❌ Node.js 未安装"
    echo "   请安装 Node.js 20+：brew install node"
    ((ERRORS++))
fi

if command -v pkg &> /dev/null; then
    echo "✅ pkg 已安装"
else
    echo "⚠️  pkg 未安装 (用于打包 OpenClaw)"
    echo "   安装: npm install -g pkg"
    ((WARNINGS++))
fi

echo ""
echo "🍎 检查 Xcode..."
if command -v xcodebuild &> /dev/null; then
    XCODE_VERSION=$(xcodebuild -version | head -1)
    echo "✅ $XCODE_VERSION"
else
    echo "❌ Xcode 命令行工具未安装"
    echo "   运行: xcode-select --install"
    ((ERRORS++))
fi

echo ""
echo "📝 检查文档..."
check_file "$PROJECT_ROOT/docs/OUT_OF_BOX_EXPERIENCE.md" "开箱即用文档"
check_file "$PROJECT_ROOT/docs/XCODE_SETUP.md" "Xcode 配置文档"

echo ""
echo "==========================="
if [ $ERRORS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
    echo "🎉 所有检查通过！可以开始构建。"
    echo ""
    echo "下一步:"
    echo "  ./build/build_dmg.sh"
    exit 0
elif [ $ERRORS -eq 0 ]; then
    echo "⚠️  有 $WARNINGS 个警告，但可以继续。"
    echo ""
    echo "建议先运行:"
    echo "  ./build/bundle_openclaw.sh"
    exit 0
else
    echo "❌ 有 $ERRORS 个错误，$WARNINGS 个警告"
    echo ""
    echo "请修复上述错误后再试。"
    exit 1
fi
