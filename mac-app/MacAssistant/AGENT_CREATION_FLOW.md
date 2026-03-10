# Agent 创建流程设计

## 概述

MacAssistant 支持两种 Agent 创建方式：

1. **对话引导创建**（默认）- 在聊天中完成
2. **向导创建**（备选）- 弹窗式配置

## 对话引导创建流程

### 触发条件

当用户执行需要特定能力的操作（如截图）时，如果当前 Agent 不支持该能力：

```
用户截图 → 检测能力缺口 → 对话引导创建
```

### 流程步骤

#### Step 1: 选择提供商
系统显示推荐的 AI 提供商：

```
💡 检测到您需要 **视觉理解** 能力

我可以帮您创建一个支持此能力的 Agent。

请选择 AI 提供商：

1️⃣ **OpenAI** (GPT-4o)
   最强视觉理解能力，支持图文分析
   
2️⃣ **Anthropic** (Claude 3 Opus)
   精准的视觉识别，文档分析能力强
   
3️⃣ **Moonshot** (Kimi K2.5) ⭐ 推荐
   国内可用，支持图片和超长上下文
   
4️⃣ **Google** (Gemini Pro Vision)
   多模态能力强，免费额度多

请回复数字 (1-4) 选择
```

#### Step 2: 输入 API Key
用户选择提供商后，提示输入 API Key：

```
🔑 请输入 OpenAI 的 API Key

格式: sk-...

获取地址: https://platform.openai.com/api-keys

您的 API Key 将安全存储在本地。
```

#### Step 3: 选择模型
默认使用推荐模型，用户可选择其他：

```
🎯 请选择模型（直接回车使用推荐）：

1. gpt-4o ⭐ 推荐
2. gpt-4o-mini
3. gpt-4-turbo

回复数字或直接输入模型名称。
```

#### Step 4: 测试与创建
系统自动测试连接并创建 Agent：

```
🧪 正在测试连接...

提供商: OpenAI
模型: gpt-4o

✅ Agent 创建成功！

👁️ OpenAI Vision 已就绪
• 提供商: OpenAI
• 模型: gpt-4o
• 能力: 文本对话, 代码分析, 图片分析, 视觉理解, 长上下文

已自动切换到此 Agent。

现在可以重新发送您的图片分析请求了！
```

## 模型配置（2025 最新）

### OpenAI
- `gpt-4o` - 旗舰多模态（推荐）
- `gpt-4o-mini` - 轻量快速
- `gpt-4-turbo` - 4 Turbo
- `o3-mini` - 推理模型

### Anthropic
- `claude-opus-4` - 最强性能（推荐）
- `claude-sonnet-4` - 平衡性能
- `claude-haiku-3.5` - 快速轻量

### Moonshot
- `kimi-k2.5` - 最新多模态（推荐）
- `kimi-k2-32k` - 32k 上下文
- `kimi-k2` - K2 基础版

### Google
- `gemini-2.0-flash` - 最新多模态（推荐）
- `gemini-2.0-flash-thinking` - 推理增强
- `gemini-1.5-pro` - 1.5 Pro

## 关键代码文件

### 核心服务

| 文件 | 职责 |
|------|------|
| `AgentCreationSkill.swift` | 对话引导创建流程 |
| `AgentOrchestrator.swift` | 意图分析、路由决策 |
| `AgentStore.swift` | Agent CRUD、OpenClaw 同步 |
| `CommandRunner.swift` | 主命令处理器 |

### 数据模型

| 文件 | 职责 |
|------|------|
| `AgentModels.swift` | Agent、Provider、Capability 定义 |

### UI

| 文件 | 职责 |
|------|------|
| `ChatView.swift` | 主聊天界面 |
| `AgentListView.swift` | Agent 列表管理 |
| `AgentConfigurationWizard.swift` | 弹窗向导（备选） |

## 使用 Skill 模式

Agent 创建作为 Skill 实现：

```swift
class AgentCreationSkill {
    enum CreationState {
        case idle
        case selectingProvider(gap: CapabilityGap)
        case inputtingAPIKey(provider: ProviderType, gap: CapabilityGap)
        case selectingModel(provider: ProviderType, apiKey: String, gap: CapabilityGap)
        case testing(...)
    }
    
    func initiateCreation(for gap: CapabilityGap, in runner: CommandRunner)
    func handleInput(_ input: String, runner: CommandRunner) async
}
```

## 与 OpenClaw 集成

创建 Agent 时自动同步到 OpenClaw 配置：

```
~/.openclaw/
├── openclaw.json          # 主配置（模型路由）
└── agents/
    └── {agent-id}/
        └── auth-profile.json  # 认证配置
```

## 后续优化方向

1. **自动模型推荐** - 根据使用场景自动选择最优模型
2. **一键升级** - 检测旧模型并提示升级
3. **批量导入** - 支持从配置文件批量创建 Agents
4. **社区模板** - 提供常用 Agent 配置模板
