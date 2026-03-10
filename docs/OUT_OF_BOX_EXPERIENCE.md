# Mac Assistant 开箱即用体验

本文档介绍如何实现用户下载 DMG 安装后即可直接使用，无需手动安装 OpenClaw 等依赖。

## 🎯 目标体验

1. 用户下载并安装 DMG
2. 首次打开应用
3. 自动检测并安装 OpenClaw 引擎
4. 引导配置 AI 模型（Moonshot/OpenAI 等）
5. 完成配置后即可使用全部功能

## 📦 构建流程

### 前置要求

- macOS 15+
- Xcode 16+
- Node.js 20+（用于打包 OpenClaw）
- `pkg` 工具：`npm install -g pkg`

### 一键构建 DMG

```bash
# 进入项目目录
cd mac-assistant

# 运行构建脚本
./build/build_dmg.sh
```

构建完成后，会在 `build/` 目录下生成 `MacAssistant-YYYY.MM.DD.dmg`。

### 手动构建步骤

如果不使用脚本，可以按以下步骤手动构建：

#### 1. 打包 OpenClaw CLI

```bash
# 进入 openclaw-core 目录
cd openclaw-core

# 安装依赖
npm install

# 打包为独立可执行文件
pkg openclaw.mjs \
    --targets node20-macos-arm64 \
    --output ../build/bundled/openclaw \
    --compress GZip

# 复制到 Resources
cp ../build/bundled/openclaw \
    ../mac-app/MacAssistant/MacAssistant/Resources/
```

#### 2. 构建 Xcode 项目

```bash
# 命令行构建
xcodebuild \
    -project mac-app/MacAssistant/MacAssistant.xcodeproj \
    -scheme MacAssistant \
    -configuration Release \
    build
```

或在 Xcode 中打开项目，选择 Product → Archive → Distribute App。

#### 3. 创建 DMG

使用 `create-dmg` 工具或 Disk Utility 手动创建。

## 🔧 技术实现

### 依赖管理 (DependencyManager)

`DependencyManager` 负责检测、安装和管理 OpenClaw CLI：

```swift
// 检查并确保 OpenClaw 可用
let openclawPath = try await DependencyManager.shared.ensureOpenClawAvailable()
```

**工作流程：**
1. 检查系统 PATH 中是否已有 openclaw
2. 检查 `~/.local/bin/openclaw` 是否存在
3. 从 App Bundle 复制到用户目录
4. 设置可执行权限

### 首次启动引导 (OnboardingView)

引导流程包含四个步骤：

1. **欢迎** - 介绍应用功能
2. **准备环境** - 自动安装 OpenClaw（显示进度）
3. **配置 AI** - 选择 Provider 并输入 API Key
4. **准备就绪** - 显示快速开始指南

### Gateway 启动流程

修改后的启动流程：

```
App 启动
    ↓
检测是否需要首次引导
    ↓
是 → 显示 OnboardingView
    ↓
安装 OpenClaw (DependencyManager)
    ↓
配置 AI Agent
    ↓
关闭引导 → 通知 AppDelegate
    ↓
启动 OpenClaw Gateway
    ↓
显示主窗口
```

## 📁 文件结构

```
mac-assistant/
├── build/
│   ├── bundle_openclaw.sh      # OpenClaw 打包脚本
│   ├── build_dmg.sh            # DMG 构建脚本
│   └── bundled/                # 打包后的二进制文件
├── mac-app/MacAssistant/MacAssistant/
│   ├── Resources/
│   │   └── openclaw            # 打包后的 OpenClaw CLI
│   ├── Services/
│   │   ├── DependencyManager.swift       # 依赖管理
│   │   └── OpenClawGatewayRuntimeManager.swift  # Gateway 管理
│   └── Views/Onboarding/
│       └── OnboardingView.swift # 引导界面
└── openclaw-core/              # OpenClaw 源码（子模块）
```

## 🔐 安全考虑

1. **Sandbox 兼容**：打包后的 OpenClaw 作为辅助可执行文件，符合 App Sandbox 要求
2. **用户授权**：首次安装时弹出授权提示（如需要辅助功能权限）
3. **API Key 安全**：用户输入的 API Key 仅存储在本地 Keychain

## 🐛 故障排查

### OpenClaw 安装失败

**现象**：引导界面显示"安装失败"

**可能原因**：
- 磁盘空间不足
- 权限问题
- 防病毒软件拦截

**解决方案**：
1. 检查 `~/.local/bin/` 目录权限
2. 尝试手动复制：`cp /Applications/MacAssistant.app/Contents/Resources/openclaw ~/.local/bin/`
3. 查看日志：`~/Documents/MacAssistant/Logs/mac-assistant-current.log`

### Gateway 启动失败

**现象**：配置完成后无法使用 AI 功能

**检查步骤**：
```bash
# 1. 检查 OpenClaw 是否可用
~/.local/bin/openclaw --version

# 2. 检查 Gateway 日志
cat ~/.openclaw-macassistant-wrapper/gateway.log

# 3. 手动启动 Gateway 测试
~/.local/bin/openclaw --profile macassistant-wrapper gateway run --allow-unconfigured --bind loopback --port 18889 --auth none
```

### API Key 无效

**现象**：配置完成后提示"API Key 无效"

**检查步骤**：
1. 确认 API Key 格式正确（通常以 `sk-` 开头）
2. 检查网络连接
3. 查看 Provider 控制台确认 Key 状态

## 📋 更新日志

### 2026.03.10
- 实现开箱即用体验
- 添加自动依赖安装
- 添加首次启动引导
- 集成 OpenClaw 打包流程

## 🚀 未来优化

1. **增量更新**：支持 OpenClaw 自动更新
2. **多架构支持**：同时打包 arm64 和 x86_64 版本
3. **签名和公证**：支持 Apple 公证，避免安全警告
4. **离线安装包**：完全离线可用的安装包
