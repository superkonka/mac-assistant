# MacAssistant Agent 架构设计 v2.0

## 愿景
软件具备**自我思考和成长能力**，自动发现不支持的能力并通过 Agent/Skill 系统解决，而非手动迭代开发。

## 核心概念

### 1. Agent - 智能体
每个 Agent 是独立的 AI 实例，具备：
- **独立配置**: 自己的 LLM Provider、API Key、系统提示词
- **独立工作区**: 隔离的状态、记忆、工具
- **特定能力**: 代码分析、图片理解、文档处理等

### 2. Skill - 技能
Agent 可调用的工具能力：
- **系统工具**: 截图、文件操作、网络请求
- **第三方服务**: GitHub、Futu API、搜索引擎
- **AI 能力**: 图片分析(OCR)、语音识别、代码生成

### 3. Router - 路由
自动将用户请求路由到最适合的 Agent。

---

## 当前 OpenClaw 能力评估

| 能力 | OpenClaw 支持 | 状态 |
|------|---------------|------|
| 多 Agent 管理 | ✅ `openclaw agents add/list/delete` | 可用 |
| Agent 独立配置 | ✅ `~/.openclaw/agents/{id}/` | 可用 |
| Skills 系统 | ✅ `openclaw skills list/check` | 可用 |
| 多 Provider | ✅ `models.providers` | 可用 |
| Auth 配置 | ✅ `auth-profiles.json` | 可用 |
| Subagents | ✅ `agents.defaults.subagents` | 可用 |
| Routing | ✅ `openclaw agents bind` | 可用 |

**结论**: OpenClaw 已具备完整 Agent 架构能力！MacAssistant 需要完善框架来使用这些能力。

---

## MacAssistant v2.0 架构设计

### 架构图

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         MacAssistant v2.0                               │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐                  │
│  │   UI Layer  │    │ AgentStore  │    │  SkillStore │                  │
│  │             │    │             │    │             │                  │
│  │ • ChatView  │◄──►│ • AgentList │    │ • SkillList │                  │
│  │ • AgentMgr  │    │ • Config    │◄──►│ • Registry  │                  │
│  │ • Settings  │    │ • Selector  │    │ • Discovery │                  │
│  └──────┬──────┘    └──────┬──────┘    └──────┬──────┘                  │
│         │                  │                  │                         │
│         └──────────────────┼──────────────────┘                         │
│                            ▼                                             │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │                    AgentOrchestrator                            │    │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────┐ │    │
│  │  │  Intent     │  │   Router    │  │    CapabilityDiscovery  │ │    │
│  │  │  Analyzer   │──►   Engine    │──►    (自我思考/成长)      │ │    │
│  │  │             │  │             │  │                         │ │    │
│  │  │ "分析图片"  │  │ 图片请求───► │  │ • 检查图片分析能力      │ │    │
│  │  │             │  │ VisionAgent │  │ • 发现无此能力          │ │    │
│  │  └─────────────┘  └─────────────┘  │ • 提议创建 VisionAgent  │ │    │
│  │                                     │ • 引导用户配置          │ │    │
│  │                                     └─────────────────────────┘ │    │
│  └─────────────────────────────────────────────────────────────────┘    │
│                            │                                             │
│                            ▼                                             │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │                    OpenClaw Integration                         │    │
│  │                                                                  │    │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────┐ │    │
│  │  │  Core Agent │  │ VisionAgent │  │   DocumentAgent         │ │    │
│  │  │ (Kimi/Ollama)│  │ (GPT-4V)    │  │   (Claude)              │ │    │
│  │  │             │  │             │  │                         │ │    │
│  │  │ Provider:   │  │ Provider:   │  │ Provider:               │ │    │
│  │  │ ollama      │  │ openai      │  │ anthropic               │ │    │
│  │  │ Model:      │  │ Model:      │  │ Model:                  │ │    │
│  │  │ kimi-local  │  │ gpt-4o      │  │ claude-opus             │ │    │
│  │  │             │  │ Capability: │  │ Capability:             │ │    │
│  │  │ Skills:     │  │ • Image     │  │ • PDF解析               │ │    │
│  │  │ • System    │  │ • OCR       │  │ • 文档总结              │ │    │
│  │  │ • File      │  │ • Chart     │  │ • 知识提取              │ │    │
│  │  └─────────────┘  └─────────────┘  └─────────────────────────┘ │    │
│  │                                                                  │    │
│  │  存储: ~/.openclaw/agents/{agent_id}/                           │    │
│  │  • agent.json     - Agent 配置                                  │    │
│  │  • auth-profiles.json - API Key                                 │    │
│  │  • workspace/     - 工作区                                      │    │
│  │                                                                  │    │
│  └─────────────────────────────────────────────────────────────────┘    │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 核心组件设计

### 1. AgentOrchestrator - 智能编排器

负责**意图分析**、**路由决策**和**能力发现**。

```swift
class AgentOrchestrator: ObservableObject {
    // 意图分析
    func analyzeIntent(_ userInput: String) -> Intent {
        // 使用 Core Agent 分析用户意图
        // 返回: .chat, .imageAnalysis, .codeReview, .documentProcess
    }
    
    // 路由决策
    func route(_ intent: Intent) -> Agent {
        // 根据意图选择最适合的 Agent
        // 如果没有匹配的 Agent，触发 CapabilityDiscovery
    }
    
    // 能力发现 (自我成长)
    func discoverCapability(for intent: Intent) -> CapabilityGap {
        // 检查当前 Agents 是否满足需求
        // 发现能力缺口，提议创建新 Agent
    }
}
```

### 2. CapabilityDiscovery - 能力发现

软件自我思考如何解决不支持的能力。

```swift
enum CapabilityGap {
    case missingVision      // 缺少图片分析
    case missingDocument    // 缺少文档处理
    case missingVoice       // 缺少语音能力
    
    var solution: Solution {
        switch self {
        case .missingVision:
            return Solution(
                name: "创建 VisionAgent",
                description: "需要 GPT-4V 或 Claude 3 等多模态模型",
                steps: [
                    .checkAvailableProviders,           // 检查可用 Provider
                    .requestAPIKey(provider: .openai), // 请求用户输入 API Key
                    .createAgent(config: visionConfig),// 创建 Agent
                    .testAgent,                        // 测试 Agent
                    .mountAgent                        // 挂载到系统
                ]
            )
        }
    }
}
```

### 3. AgentStore - Agent 管理

管理所有 Agent 的生命周期。

```swift
class AgentStore: ObservableObject {
    @Published var agents: [Agent] = []
    @Published var activeAgent: Agent?
    
    // 创建 Agent
    func createAgent(config: AgentConfig) async throws -> Agent {
        // 1. 调用 openclaw agents add <id>
        // 2. 配置 models.providers
        // 3. 配置 auth-profiles.json
        // 4. 测试连接
        // 5. 添加到列表
    }
    
    // 切换 Agent
    func switchToAgent(_ agent: Agent) {
        // 更新 activeAgent
        // 通知 UI 更新
    }
    
    // 获取 Agent 能力
    func capabilities(of agent: Agent) -> [Capability] {
        // 读取 Agent 的 skills 和配置
    }
}
```

### 4. AgentConfigurationView - Agent 配置界面

引导用户配置新的 Agent。

```swift
struct AgentConfigurationView: View {
    let gap: CapabilityGap
    
    var body: some View {
        VStack {
            // 步骤指示器
            StepperView(steps: [
                "选择 Provider",
                "配置 API Key",
                "测试连接",
                "完成"
            ], currentStep: $currentStep)
            
            // 根据步骤显示不同内容
            switch currentStep {
            case 0:
                ProviderSelectionView(
                    providers: [.openai, .anthropic, .google],
                    onSelect: { provider in
                        // 显示该 provider 需要的配置
                    }
                )
            case 1:
                APIKeyInputView(
                    provider: selectedProvider,
                    onSubmit: { key in
                        // 验证 key 有效性
                    }
                )
            case 2:
                TestConnectionView(
                    onTest: {
                        // 测试 Agent 连接
                    }
                )
            case 3:
                CompletionView(
                    onMount: {
                        // 挂载 Agent
                    }
                )
            }
        }
    }
}
```

---

## 用户流程设计

### 场景 1: 用户请求图片分析

```
用户: "分析这张截图"

系统:
1. AgentOrchestrator.analyzeIntent() → .imageAnalysis
2. AgentOrchestrator.route(.imageAnalysis) 
   → 发现无 VisionAgent
3. AgentOrchestrator.discoverCapability(.imageAnalysis)
   → 显示引导界面:
   
   ┌─────────────────────────────────────┐
   │  🔍 发现新需求                       │
   │                                     │
   │  您需要图片分析能力，但当前未配置    │
   │  支持图片分析的 Agent。              │
   │                                     │
   │  💡 解决方案：                       │
   │  创建 VisionAgent，支持：            │
   │  • 图片内容描述                      │
   │  • 文字识别 (OCR)                    │
   │  • 图表分析                          │
   │                                     │
   │  [了解更多]  [立即配置]  [跳过]      │
   └─────────────────────────────────────┘

4. 用户点击 [立即配置]
   → 显示 AgentConfigurationView
   
   步骤1: 选择 Provider
   ┌─────────────────────────────────────┐
   │  选择图片分析模型提供商              │
   │                                     │
   │  ○ OpenAI (GPT-4V)                  │
   │    能力强，需要 API Key              │
   │                                     │
   │  ○ Anthropic (Claude 3)             │
   │    速度快，需要 API Key              │
   │                                     │
   │  ○ Google (Gemini)                  │
   │    免费额度多，需要 API Key          │
   │                                     │
   │  [上一步]  [下一步]                  │
   └─────────────────────────────────────┘

5. 用户选择 OpenAI，输入 API Key
   → 系统自动验证 key
   → 创建 ~/.openclaw/agents/vision-agent/
   → 配置 models.providers.openai
   → 配置 auth-profiles.json

6. 测试 Agent
   → 发送测试图片
   → 验证响应正常

7. 挂载完成
   → Agent 添加到 AgentStore
   → 显示在 AgentList
   → 路由规则自动绑定

8. 自动重试原请求
   → 截图保存到桌面
   → 调用 VisionAgent 分析
   → 返回结果
```

### 场景 2: 手动切换 Agent

```
用户: "/agent vision"

系统:
1. 解析命令，识别 agent 切换意图
2. AgentStore.switchToAgent(.vision)
3. 显示当前 Agent 变更:
   "已切换到 VisionAgent (GPT-4V)"
4. 后续对话使用该 Agent

用户: "分析代码"

系统:
1. AgentOrchestrator 识别代码分析意图
2. 自动路由到 CodeAgent (如果存在)
3. 或提示创建 CodeAgent
```

---

## 技术实现路径

### 阶段 1: AgentStore 框架 (1-2 周)

1. **Agent 模型定义**
   ```swift
   struct Agent: Identifiable, Codable {
       let id: String
       let name: String
       let emoji: String
       let provider: Provider
       let model: String
       let capabilities: [Capability]
       let isActive: Bool
   }
   ```

2. **OpenClaw Agent 管理封装**
   ```swift
   class OpenClawAgentManager {
       func createAgent(config: AgentConfig) async throws
       func deleteAgent(id: String) async throws
       func listAgents() async -> [Agent]
       func configureProvider(_ provider: Provider, apiKey: String) async throws
   }
   ```

3. **AgentList UI**
   - 显示所有 Agents
   - 切换按钮
   - 配置入口

### 阶段 2: CapabilityDiscovery (2-3 周)

1. **意图分类器**
   - 使用 Core Agent 分析意图
   - 匹配到 Capability 类型

2. **缺口检测**
   - 检查是否有 Agent 支持该 Capability
   - 生成解决方案

3. **引导界面**
   - 步骤化配置流程
   - API Key 安全输入
   - 测试验证

### 阶段 3: AgentOrchestrator (2-3 周)

1. **智能路由**
   - 基于意图的 Agent 选择
   - 多 Agent 协作

2. **上下文传递**
   - 跨 Agent 对话历史
   - 共享记忆

3. **自我学习**
   - 记录用户偏好
   - 优化路由决策

---

## OpenClaw 配置示例

### 创建 Vision Agent

```bash
# 1. 创建 Agent
openclaw agents add vision-agent

# 2. 配置 Provider
cat > ~/.openclaw/agents/vision-agent/agent/config.json << 'EOF'
{
  "models": {
    "providers": {
      "openai": {
        "api": "openai",
        "apiKey": "${OPENAI_API_KEY}",
        "models": [
          {
            "id": "gpt-4o",
            "name": "GPT-4o Vision",
            "input": ["text", "image"]
          }
        ]
      }
    }
  },
  "agent": {
    "model": "openai/gpt-4o",
    "systemPrompt": "你是一个专业的图片分析助手..."
  }
}
EOF

# 3. 配置 Auth
cat > ~/.openclaw/agents/vision-agent/agent/auth-profiles.json << 'EOF'
{
  "version": 1,
  "profiles": {
    "openai-primary": {
      "type": "api_key",
      "provider": "openai",
      "key": "sk-..."
    }
  }
}
EOF

# 4. 绑定路由 (图片相关请求路由到 vision-agent)
openclaw agents bind vision-agent --pattern "*图片*" --pattern "*截图*" --pattern "*分析*"
```

---

## 总结

### OpenClaw 已具备的能力
- ✅ 多 Agent 管理
- ✅ 独立 Agent 配置
- ✅ Skills 系统
- ✅ 多 Provider 支持
- ✅ Auth 管理
- ✅ Subagents
- ✅ Routing

### MacAssistant 需要实现的
1. **AgentStore**: Agent 生命周期管理 UI
2. **CapabilityDiscovery**: 能力缺口检测和引导
3. **AgentOrchestrator**: 智能路由和编排
4. **配置界面**: 步骤化 Agent 创建流程

### 最终用户体验
```
用户: "分析这张图片"
系统: "需要图片分析能力，正在为您配置 VisionAgent..."
      "[配置进度条]"
      "✅ VisionAgent 已就绪"
      "[图片分析结果...]"
```

软件具备**自我思考**和**自我成长**能力，不再依赖开发者手动迭代！
