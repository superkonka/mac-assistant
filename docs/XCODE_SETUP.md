# Xcode 项目配置指南

配置 Mac Assistant Xcode 项目以支持开箱即用体验。

## 1. 添加 OpenClaw 到 Resources

### 方法 A：自动（推荐）

运行打包脚本会自动复制：

```bash
./build/bundle_openclaw.sh
```

### 方法 B：手动

1. 在 Finder 中找到 `mac-app/MacAssistant/MacAssistant/Resources/`
2. 将打包后的 `openclaw` 文件拖入该目录
3. 在 Xcode 中，确保文件出现在项目的 Resources 组中

## 2. 配置 Build Phases

### 添加资源复制阶段

1. 在 Xcode 中选择项目 → Targets → MacAssistant
2. 选择 **Build Phases** 标签
3. 展开 **Copy Bundle Resources**
4. 确保 `openclaw` 文件在列表中

### 添加执行权限（可选）

如果需要确保权限，可以添加 Run Script 阶段：

1. 点击 **+** → **New Run Script Phase**
2. 命名为 "Fix OpenClaw Permissions"
3. 添加脚本：

```bash
# 确保 OpenClaw 有执行权限
OPENCLAW_PATH="${BUILT_PRODUCTS_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/openclaw"
if [ -f "$OPENCLAW_PATH" ]; then
    chmod +x "$OPENCLAW_PATH"
fi
```

## 3. 启用辅助可执行文件（推荐）

为了让 OpenClaw 可以作为辅助可执行文件运行：

1. 在 **Build Settings** 中搜索 `LD_RUNPATH_SEARCH_PATHS`
2. 确保包含 `@executable_path/../Frameworks`

## 4. 代码签名配置

### 开发版本

使用自动签名即可：

1. **Signing & Capabilities**
2. 勾选 **Automatically manage signing**
3. 选择你的 Team

### 分发版本

对于 DMG 分发：

1. 使用 **Developer ID Application** 证书签名
2. 运行公证：

```bash
# 签名
 codesign --force --options runtime --sign "Developer ID Application: Your Name" MacAssistant.app

# 公证
xcrun notarytool submit MacAssistant.dmg --apple-id your@email.com --team-id TEAM_ID --wait
```

## 5. Sandboxing 配置

如果需要启用 Sandbox：

1. **Signing & Capabilities**
2. 添加 **App Sandbox**
3. 勾选以下权限：
   - ✅ **Network: Incoming/Outgoing connections**（AI 通信）
   - ✅ **File Access: User Selected File**（文件上传）
   - ✅ **File Access: Downloads**（下载文件）

## 6. 测试配置

构建并运行后，验证：

```bash
# 1. 检查 OpenClaw 是否在 Bundle 中
ls -la /Applications/MacAssistant.app/Contents/Resources/openclaw

# 2. 测试运行
/Applications/MacAssistant.app/Contents/Resources/openclaw --version
```

## 7. 常见问题

### OpenClaw 未找到

**错误**：`BundledNotFound`

**解决**：
1. 检查 `openclaw` 是否在 Resources 目录
2. 检查 Xcode 中的 **Target Membership**

### 权限被拒绝

**错误**：`Permission denied`

**解决**：
1. 确保 `openclaw` 有执行权限：`chmod +x openclaw`
2. 在 Xcode 中检查文件的权限设置

### 架构不匹配

**错误**：`Bad CPU type in executable`

**解决**：
- 在 M1/M2 Mac 上打包时，确保使用 `node20-macos-arm64` 目标
- 在 Intel Mac 上打包时，使用 `node20-macos-x64` 目标
- 或者构建 Universal Binary（需要同时打包两种架构）

## 8. 调试技巧

### 查看 Bundle 内容

```bash
# 查看应用包内容
ls -la MacAssistant.app/Contents/

# 查看 Resources
ls -la MacAssistant.app/Contents/Resources/

# 查看执行文件
file MacAssistant.app/Contents/Resources/openclaw
```

### 运行时日志

```bash
# 查看应用日志
tail -f ~/Documents/MacAssistant/Logs/mac-assistant-current.log

# 查看 Gateway 日志
cat ~/.openclaw-macassistant-wrapper/gateway.log
```

### 重置首次启动

测试引导流程时需要重置：

```bash
# 删除 Agent 配置
rm -rf ~/Library/Containers/com.yourcompany.MacAssistant/Data/Library/Preferences/

# 或者删除所有应用数据
rm -rf ~/Library/Application\ Support/MacAssistant
rm -rf ~/.openclaw-macassistant-wrapper
```
