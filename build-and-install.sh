#!/bin/bash
# MacAssistant 构建和安装脚本

set -e

echo "🤖 MacAssistant 构建安装程序"
echo "=============================="
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

PROJECT_DIR="/Volumes/ExpansionDock/Code/mac-assistant"
APP_NAME="MacAssistant"
BUNDLE_ID="com.konka.macassistant"
BUILD_CONFIG="release"

# 检查并终止正在运行的应用
log_info "检查正在运行的应用..."
if pgrep -x "$APP_NAME" > /dev/null; then
    log_warn "发现正在运行的 $APP_NAME，正在终止..."
    killall "$APP_NAME" 2>/dev/null || true
    sleep 2
fi

# 进入项目目录
cd "$PROJECT_DIR/mac-app/MacAssistant"

# 清理旧构建
log_info "清理旧构建..."
rm -rf .build/$BUILD_CONFIG
swift package clean

# 构建 Release 版本
log_info "构建 Release 版本..."
swift build -c $BUILD_CONFIG

# 检查构建结果
EXECUTABLE_PATH=".build/arm64-apple-macosx/$BUILD_CONFIG/$APP_NAME"
if [ ! -f "$EXECUTABLE_PATH" ]; then
    log_error "构建失败：未找到可执行文件"
    exit 1
fi

log_success "✓ 构建成功"

# 创建 .app Bundle
log_info "创建 .app Bundle..."

APP_BUNDLE="$PROJECT_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

# 删除旧版本
if [ -d "$APP_BUNDLE" ]; then
    log_info "删除旧版本..."
    rm -rf "$APP_BUNDLE"
fi

# 创建目录结构
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# 复制可执行文件
cp "$EXECUTABLE_PATH" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

# 复制资源文件
if [ -d "MacAssistant/Resources" ]; then
    cp -R MacAssistant/Resources/* "$RESOURCES_DIR/" 2>/dev/null || true
fi

# 创建 Info.plist
cat > "$CONTENTS_DIR/Info.plist" << 'PLIST_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>MacAssistant</string>
    <key>CFBundleIdentifier</key>
    <string>com.konka.macassistant</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>MacAssistant</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    <key>NSAccessibilityUsageDescription</key>
    <string>MacAssistant 需要辅助功能权限来执行自动化操作</string>
    <key>NSCameraUsageDescription</key>
    <string>MacAssistant 需要相机权限来进行视觉分析</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>MacAssistant 需要麦克风权限来进行语音交互</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>MacAssistant 需要屏幕录制权限来进行截图分析</string>
</dict>
</plist>
PLIST_EOF

log_success "✓ .app Bundle 创建完成"

# 安装到 /Applications
log_info "安装到 /Applications..."

if [ -d "/Applications/$APP_NAME.app" ]; then
    log_warn "发现旧版本，正在替换..."
    rm -rf "/Applications/$APP_NAME.app"
fi

cp -R "$APP_BUNDLE" "/Applications/"
rm -rf "$APP_BUNDLE"

log_success "✓ 安装完成: /Applications/$APP_NAME.app"

# 验证安装
if [ -d "/Applications/$APP_NAME.app" ]; then
    log_success "✓ 应用已安装"
    
    # 显示应用信息
    APP_SIZE=$(du -sh "/Applications/$APP_NAME.app" | cut -f1)
    log_info "应用大小: $APP_SIZE"
    
    echo ""
    echo "=============================="
    log_success "🎉 MacAssistant 安装成功!"
    echo ""
    echo "启动方式:"
    echo "  1. 在启动台中找到 MacAssistant 点击启动"
    echo "  2. 或在终端运行: open /Applications/MacAssistant.app"
    echo ""
    echo "快捷键:"
    echo "  ⌘ ⇧ Space  - 打开/关闭面板"
    echo "  ⌘ ⇧ 1      - 截图并询问 AI"
    echo "  ⌘ ⇧ V      - 询问剪贴板内容"
    echo ""
    echo "=============================="
else
    log_error "安装失败"
    exit 1
fi
