# Mac Assistant 用户指南

欢迎使用 Mac Assistant！本指南帮助你快速上手。

## 🚀 快速开始

### 1. 安装应用

1. 下载 `MacAssistant.dmg`
2. 双击挂载 DMG
3. 将 `MacAssistant.app` 拖到 **Applications** 文件夹
4. 从启动台或 Applications 打开应用

### 2. 首次配置

首次打开时会自动进入配置向导：

#### 步骤 1：欢迎
- 点击「开始设置」

#### 步骤 2：准备环境
- 应用会自动安装 OpenClaw 引擎
- 等待安装完成（约 10-30 秒）

#### 步骤 3：配置 AI
- 选择 AI 服务提供商（推荐 Moonshot）
- 输入 API Key
- 点击「测试连接」验证
- 点击「完成配置」

#### 步骤 4：开始使用
- 点击「开始使用」进入主界面

### 3. 获取 API Key

#### Moonshot（推荐）
1. 访问 [platform.moonshot.cn](https://platform.moonshot.cn)
2. 注册/登录账号
3. 进入「API Key 管理」
4. 创建新的 API Key
5. 复制 Key 到配置向导

#### OpenAI
1. 访问 [platform.openai.com](https://platform.openai.com)
2. 进入 API Keys 页面
3. 创建新的 Secret Key

#### Anthropic (Claude)
1. 访问 [console.anthropic.com](https://console.anthropic.com)
2. 获取 API Key

## 💬 使用功能

### 基本聊天
- 在输入框输入问题，按回车发送
- 支持 Markdown 格式

### 截图询问
- **快捷键**：`⌘⇧1`
- 或点击输入框下方的「截图」按钮
- 自动截取屏幕并询问 AI

### 剪贴板询问
- **快捷键**：`⌘⇧V`
- 或点击「剪贴板」按钮
- 询问剪贴板中的文本内容

### 快速访问
- 点击菜单栏的 **🤖** 图标
- 或使用快捷键 `⌘⇧Space`

## 🛠️ 常用命令

在聊天中输入以下命令：

| 命令 | 功能 |
|------|------|
| `/app 打开 Safari` | 打开应用程序 |
| `/app 退出 Chrome` | 退出应用程序 |
| `/app 查看 状态` | 查看应用运行状态 |
| `/截图` | 截图并询问 AI |
| `/剪贴板` | 询问剪贴板内容 |
| `/搜索 关键词` | 网页搜索 |
| `/系统` | 查看系统信息 |
| `/文件 路径` | 分析文件内容 |
| `/git` | 查看 Git 状态 |

## 🔄 管理 AI Agents

### 添加新 Agent
1. 点击主界面顶部的 **+** 按钮
2. 选择 AI 提供商
3. 配置 API Key 和模型参数
4. 保存

### 切换 Agent
1. 点击当前 Agent 名称（顶部蓝色按钮）
2. 选择要使用的 Agent

### 设置默认 Agent
1. 打开 Agent 列表
2. 右键点击 Agent
3. 选择「设为默认」

## 📊 查看日志

### 应用日志
- 菜单栏：点击 **🤖** → 「📋 查看日志」
- 或直接打开：`~/Documents/MacAssistant/Logs/`

### Gateway 日志
```bash
cat ~/.openclaw-macassistant-wrapper/gateway.log
```

## ⚙️ 高级配置

### 修改 OpenClaw 配置
配置文件位置：
```
~/.openclaw-macassistant-wrapper/openclaw.json
```

### 重置配置
如需完全重置：

```bash
# 删除应用数据
rm -rf ~/Library/Application\ Support/MacAssistant
rm -rf ~/.openclaw-macassistant-wrapper

# 重新打开应用，会再次进入配置向导
```

## ❓ 常见问题

### Q: 首次启动卡在"准备环境"

**A**: 
1. 检查网络连接
2. 查看日志：`~/Documents/MacAssistant/Logs/`
3. 尝试重启应用

### Q: API Key 无效

**A**:
1. 确认 Key 格式正确（Moonshot 以 `sk-` 开头）
2. 检查 Key 是否已激活
3. 确认账户有余额

### Q: 截图功能不工作

**A**:
1. 检查屏幕录制权限：
   - 系统设置 → 隐私与安全 → 屏幕录制
   - 确保 MacAssistant 已勾选
2. 重启应用

### Q: 如何更新应用？

**A**:
1. 下载最新版 DMG
2. 拖入 Applications 覆盖旧版本
3. 配置会自动保留

### Q: 可以离线使用吗？

**A**:
- OpenClaw 引擎：可以（已本地安装）
- AI 功能：需要联网调用 API

### Q: 数据隐私如何保障？

**A**:
- API Key 仅存储在本地 Keychain
- 聊天记录存储在本地
- 图片分析直接上传到 AI 提供商

## 🆘 获取帮助

1. **查看日志**：菜单栏 → 📋 查看日志
2. **重启应用**：菜单栏 → 退出，重新打开
3. **重置配置**：删除 `~/.openclaw-macassistant-wrapper/`

## 📝 快捷键总结

| 快捷键 | 功能 |
|--------|------|
| `⌘⇧Space` | 打开/关闭主窗口 |
| `⌘⇧1` | 截图询问 |
| `⌘⇧V` | 剪贴板询问 |
| `⌘L` | 查看日志 |
| `⌘Q` | 退出应用 |

## 🎉 享受 Mac Assistant！

如果遇到问题或有建议，欢迎反馈。
