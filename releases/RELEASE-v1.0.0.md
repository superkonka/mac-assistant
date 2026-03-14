# MacAssistant v1.0.0 Release

## 版本信息
- **版本号**: v1.0.0
- **构建时间**: 2026-03-14
- **分支**: `feat/agent-skill-modular`
- **Git Commit**: `3619359`

## 下载

由于 GitHub 文件大小限制（100MB），DMG 文件无法直接提交到仓库。

### 构建方式
如需本地构建，请执行：

```bash
cd mac-app/MacAssistant
xcodebuild -project MacAssistant.xcodeproj -scheme MacAssistant -configuration Release build

# 创建 DMG
hdiutil create -volname "MacAssistant" \
  -srcfolder ~/Library/Developer/Xcode/DerivedData/*/Build/Products/Release/MacAssistant.app \
  -ov -format UDZO MacAssistant-v1.0.0.dmg
```

### 应用信息
- **大小**: 808 MB (App) / 362 MB (DMG)
- **架构**: Universal (x86_64 + arm64)
- **最低系统**: macOS 15.0+
- **签名**: Ad-hoc

## 功能亮点

### 🏗️ 轻量化架构
- App 层仅负责 UI + 配置
- 执行逻辑委托给 OpenClaw Core
- Registry 层做配置桥梁

### 📋 子任务管理工作流
- 独立入口，按状态分组
- 支持滑动删除
- 详情 Sheet 查看

### 🤖 复杂任务自动拆分
- 自动识别创建/分析/批处理/文档类任务
- 异步执行，不阻塞主会话
- 携带主会话上下文

### 🎯 Planner（秘书）评估
- 子任务完成后自动评估
- 决策类型：[完成]/[继续]/[确认]
- 自动创建工作流链条

### ⏰ 时间自动补全
- 所有用户输入附加当前时间
- 格式：2026年03月14日 10:30（星期五）

## 安装说明

1. 下载 DMG 文件
2. 双击挂载
3. 将 MacAssistant.app 拖到 Applications 文件夹
4. 首次运行执行：`xattr -cr /Applications/MacAssistant.app`

## 已知问题

- 需要 Apple Developer ID 证书进行正式签名
- 首次运行需要手动解除隔离属性

## 相关链接

- [架构说明](../ARCHITECTURE.md)
- [主分支](../tree/main)
- [功能分支](../tree/feat/agent-skill-modular)
