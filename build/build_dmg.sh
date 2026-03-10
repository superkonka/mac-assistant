#!/bin/bash
# Mac Assistant DMG 构建脚本
# 包含 OpenClaw 打包和完整的开箱即用体验

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/build"
DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData"
APP_NAME="MacAssistant"
DMG_NAME="MacAssistant"
VERSION="$(date +%Y.%m.%d)"

echo "🎨 Mac Assistant DMG 构建脚本"
echo "==============================="
echo ""

# 颜色
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 步骤 1: 打包 OpenClaw
log_info "步骤 1/5: 打包 OpenClaw CLI..."
cd "$PROJECT_ROOT"
if [ -f "$BUILD_DIR/bundle_openclaw.sh" ]; then
    chmod +x "$BUILD_DIR/bundle_openclaw.sh"
    "$BUILD_DIR/bundle_openclaw.sh"
    if [ $? -eq 0 ]; then
        log_success "OpenClaw 打包完成"
    else
        log_error "OpenClaw 打包失败"
        exit 1
    fi
else
    log_error "找不到 bundle_openclaw.sh 脚本"
    exit 1
fi

# 步骤 2: 检查 Xcode 项目
log_info "步骤 2/5: 检查 Xcode 项目..."
XCODE_PROJECT="$PROJECT_ROOT/mac-app/MacAssistant/MacAssistant.xcodeproj"
if [ ! -d "$XCODE_PROJECT" ]; then
    log_error "找不到 Xcode 项目: $XCODE_PROJECT"
    exit 1
fi
log_success "找到 Xcode 项目"

# 步骤 3: 构建应用
log_info "步骤 3/5: 构建 Mac Assistant..."
cd "$PROJECT_ROOT/mac-app/MacAssistant"

# 清理之前的构建
rm -rf "$DERIVED_DATA/MacAssistant-*"

# 构建
xcodebuild \
    -project "$XCODE_PROJECT" \
    -scheme MacAssistant \
    -configuration Release \
    -destination "platform=macOS" \
    BUILD_DIR="$BUILD_DIR/products" \
    clean build

if [ $? -ne 0 ]; then
    log_error "Xcode 构建失败"
    exit 1
fi

# 找到构建产物
APP_PATH="$BUILD_DIR/products/Release/$APP_NAME.app"
if [ ! -d "$APP_PATH" ]; then
    # 尝试其他路径
    APP_PATH=$(find "$BUILD_DIR/products" -name "$APP_NAME.app" -type d 2>/dev/null | head -1)
fi

if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
    log_error "找不到构建产物 $APP_NAME.app"
    exit 1
fi

log_success "应用构建完成: $APP_PATH"

# 步骤 4: 验证应用
log_info "步骤 4/5: 验证应用..."

# 检查是否包含 OpenClaw
if [ -f "$APP_PATH/Contents/Resources/openclaw" ]; then
    log_success "✓ OpenClaw 已包含在应用中"
    ls -lh "$APP_PATH/Contents/Resources/openclaw"
else
    log_warn "⚠ OpenClaw 未找到在 Resources 中，尝试复制..."
    if [ -f "$PROJECT_ROOT/mac-app/MacAssistant/MacAssistant/Resources/openclaw" ]; then
        cp "$PROJECT_ROOT/mac-app/MacAssistant/MacAssistant/Resources/openclaw" "$APP_PATH/Contents/Resources/"
        chmod +x "$APP_PATH/Contents/Resources/openclaw"
        log_success "✓ OpenClaw 已复制到应用包"
    else
        log_error "✗ 找不到 OpenClaw 可执行文件"
        exit 1
    fi
fi

# 检查签名
if codesign -dv "$APP_PATH" 2>&1 | grep -q "Signature"; then
    log_success "✓ 应用已签名"
else
    log_warn "⚠ 应用未签名，可能影响分发"
fi

# 步骤 5: 创建 DMG
log_info "步骤 5/5: 创建 DMG..."

DMG_TEMP="$BUILD_DIR/dmg_temp"
DMG_FILE="$BUILD_DIR/${DMG_NAME}-${VERSION}.dmg"

# 清理并创建临时目录
rm -rf "$DMG_TEMP"
rm -f "$DMG_FILE"
mkdir -p "$DMG_TEMP"

# 复制应用
cp -R "$APP_PATH" "$DMG_TEMP/"

# 创建 Applications 快捷链接
ln -s /Applications "$DMG_TEMP/Applications"

# 创建 .DS_Store 和背景图（可选）
# mkdir -p "$DMG_TEMP/.background"
# cp "$BUILD_DIR/dmg_background.png" "$DMG_TEMP/.background/" 2>/dev/null || true

# 创建 README
cat > "$DMG_TEMP/使用说明-请先读我.txt" << 'EOF'
Mac Assistant 安装说明
========================

1. 将 MacAssistant.app 拖到 Applications 文件夹

2. 首次打开如果遇到"已损坏"提示，在终端执行：
   
   xattr -cr /Applications/MacAssistant.app
   
   然后重新打开应用即可。

3. 配置 AI：
   - 打开应用后配置你的 Moonshot 或 OpenAI API Key
   - 或安装 Kimi CLI 使用本地模型

快捷键：
- ⌘⇧Space - 打开/关闭面板
- ⌘⇧1     - 截图询问 AI
- ⌘⇧V     - 询问剪贴板内容

需要帮助? 查看菜单栏中的"帮助"菜单
EOF

# 创建 DMG
hdiutil create \
    -volname "$DMG_NAME" \
    -srcfolder "$DMG_TEMP" \
    -ov \
    -format UDZO \
    "$DMG_FILE"

if [ $? -eq 0 ] && [ -f "$DMG_FILE" ]; then
    log_success "DMG 创建成功!"
    echo ""
    echo "文件信息:"
    ls -lh "$DMG_FILE"
    echo ""
    echo "MD5: $(md5 -q "$DMG_FILE")"
else
    log_error "DMG 创建失败"
    exit 1
fi

# 清理
rm -rf "$DMG_TEMP"

echo ""
echo "==============================="
log_success "🎉 构建完成!"
echo ""
echo "输出文件:"
echo "  $DMG_FILE"
echo ""
echo "安装说明:"
echo "  1. 双击 DMG 文件挂载"
echo "  2. 将 MacAssistant.app 拖到 Applications"
echo "  3. 首次打开会自动配置环境"
echo ""
echo "==============================="
