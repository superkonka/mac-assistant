# MacAssistant 轻量级架构

> 目标：应用层做薄，Heavy Lifting 下沉到 OpenClaw Core

## 架构原则

```
应用层 = UI + 配置 + 状态展示
运行时 = OpenClaw Core (Agent 执行/Skill 运行/LLM 调用)
```

## 目录结构

```
MacAssistant/
├── App/
│   └── MacAssistantApp.swift          # 应用入口
├── UI/                                # SwiftUI 视图层
│   ├── Chat/
│   ├── Agent/
│   ├── Skill/
│   └── Common/
├── Gateway/                           # OpenClaw 网关
│   ├── GatewayClient.swift            # 统一客户端
│   └── Models.swift                   # 网关数据模型
├── Registry/                          # 轻量级注册表
│   ├── AgentRegistry.swift            # Agent 配置管理
│   └── SkillRegistry.swift            # Skill 清单管理
├── Services/                          # 系统服务
│   ├── RequestScheduler.swift         # 请求调度
│   └── Preferences.swift              # 偏好设置
└── Models/                            # 共享模型
    └── SharedModels.swift
```

## 关键设计

### Agent 配置层
```swift
// 应用层只存储配置，不执行
struct AgentConfiguration: Codable {
    let id: String
    let name: String
    let provider: ProviderConfig
    let capabilities: [Capability]
    // 实际执行由 OpenClaw Core 处理
}
```

### Skill 声明层
```swift
// 应用层只展示清单，不执行
struct SkillManifest: Codable {
    let id: String
    let name: String
    let requiredCapabilities: [Capability]
    // 实际执行由 OpenClaw Core 处理
}
```

### GatewayClient 统一接口
```swift
// 所有请求通过 WebSocket 发往 OpenClaw
actor GatewayClient {
    func send(_ request: GatewayRequest) async -> MessageStream
    func listAgents() async -> [AgentInfo]
    func listSkills() async -> [SkillInfo]
}
```

## 数据流

```
用户输入 → ChatViewModel → GatewayClient → OpenClaw Gateway → LLM
                 ↑                           ↓
            UI 更新 ← 流式响应 ← WebSocket ←──┘
```

## 状态: Phase 1 & 2 完成 ✅

### Phase 1: 轻量级架构基础
- ✅ 删除重复编排逻辑
- ✅ 重构 AgentSystem (轻量级配置)
- ✅ 重构 SkillSystem (声明式清单)
- ✅ 构建通过

### Phase 2: Gateway 协议对接
- ✅ 使用 OpenClawKit 的 GatewayChannelActor
- ✅ 利用现有的 OpenClawGatewayClient 进行通信
- ✅ 项目已集成 OpenClaw Gateway 协议 v3

## 架构确认

```
MacAssistant 应用层:
├── UI (SwiftUI) - ChatView, TaskSessionTabsView
├── Registry/ (轻量级配置层)
│   ├── AgentRegistry.swift    ✅ 声明式 Agent 配置
│   └── SkillRegistry.swift    ✅ 声明式 Skill 清单
└── Services/
    └── OpenClawGatewayClient  ✅ OpenClawKit 提供

OpenClaw Core Runtime:
├── Gateway (WebSocket ws://127.0.0.1:18889)
├── Agent 执行引擎
├── Skill 运行时
└── LLM 网关
```

## 状态: Phase 3 完成 ✅

### Phase 3: Skill 浏览器 UI
- ✅ SkillBrowserView - 网格展示所有 Skills
- ✅ 分类筛选 (文本/代码/视觉/推理等)
- ✅ 搜索功能
- ✅ Skill 详情弹窗
- ✅ 与轻量级 SkillRegistry 集成

### 新增组件

| 组件 | 路径 | 职责 |
|-----|------|-----|
| SkillBrowserView | UI/SkillBrowser/ | 主浏览器界面 |
| SkillCard | UI/SkillBrowser/ | Skill 卡片组件 |
| SkillDetailView | UI/SkillBrowser/ | 详情弹窗 |
| CapabilityBadge | UI/SkillBrowser/ | 能力标签组件 |
| FlowLayout | UI/SkillBrowser/ | 流式布局容器 |

## 架构总览

```
MacAssistant/
├── Registry/                    # 轻量级配置层
│   ├── AgentRegistry.swift      ✅ Agent 配置 + CapabilityTag
│   └── SkillRegistry.swift      ✅ Skill 清单
├── UI/
│   ├── SkillBrowser/            ✅ Phase 3 新增
│   │   └── SkillBrowserView.swift
│   └── Chat/                    # 现有聊天界面
│       └── ChatView.swift
└── Services/
    └── OpenClawGatewayClient    # OpenClawKit 提供
```

## 数据流

```
SkillBrowserView → SkillRegistry → 展示内置 Skills
                          ↓
                    OpenClawGatewayClient
                          ↓
              OpenClaw Gateway (WebSocket)
```

## 下一步

- Phase 4: 端到端测试与性能优化
