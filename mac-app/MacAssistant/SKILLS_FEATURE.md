# Skills 功能

## 概述

MacAssistant 新增了 **Skills（技能）** 系统，提供一键式 AI 能力调用。

## 界面

点击聊天界面顶部工具栏的 **✨ Skills** 按钮，打开技能列表面板。

```
┌─────────────────────────────────────────────┐
│  ✨ Skills                           🔍 ___  │
├─────────────────────────────────────────────┤
│  [全部] [生产力] [分析] [创建] [系统] [Agent] │
├─────────────────────────────────────────────┤
│  ┌──────────┐  ┌──────────┐  ┌──────────┐   │
│  │ 📸 截图   │  │ 👁️ 创建   │  │ 📝 代码   │   │
│  │   分析   │  │  Vision  │  │   审查   │   │
│  │ ⌘⇧5     │  │          │  │          │   │
│  │ [分析]   │  │ [Agent]  │  │ [分析]   │   │
│  └──────────┘  └──────────┘  └──────────┘   │
│  ┌──────────┐  ┌──────────┐                  │
│  │ 💡 解释   │  │ 🌐 翻译   │                  │
│  │  选中内容 │  │         │                  │
│  │ ⌘⇧E     │  │         │                  │
│  │ [分析]   │  │ [生产力] │                  │
│  └──────────┘  └──────────┘                  │
└─────────────────────────────────────────────┘
```

## 内置技能

### 分析类

| 技能 | 图标 | 快捷键 | 说明 |
|------|------|--------|------|
| 截图分析 | 📸 | ⌘⇧5 | 截取屏幕并分析内容 |
| 图片分析 | 🖼️ | - | 分析图片中的内容和细节 |
| 代码审查 | 📝 | - | 审查代码质量并提供建议 |
| 解释选中 | 💡 | ⌘⇧E | 解释当前选中的文本或代码 |

### Agent 类

| 技能 | 图标 | 说明 |
|------|------|------|
| 创建 Vision Agent | 👁️ | 创建支持图片分析的 AI Agent |

### 生产力类

| 技能 | 图标 | 说明 |
|------|------|------|
| 翻译文本 | 🌐 | 将文本翻译成其他语言 |
| 总结文本 | 📋 | 总结长文本的核心内容 |

### 系统类

| 技能 | 图标 | 说明 |
|------|------|------|
| 网络搜索 | 🔍 | 搜索网络获取实时信息 |

## 技能状态

- **可用** - 当前 Agent 支持该技能所需的能力
- **需创建 Agent** - 当前 Agent 不支持，需要创建新的 Agent

## 技术实现

### 文件结构

```
AgentSystem/
├── Models/
│   ├── SkillModels.swift      # Skill 协议、内置技能定义
│   └── ChatModels.swift       # SkillContext 定义
└── Views/
    └── Chat/
        ├── ChatView.swift     # 集成 Skills 按钮
        └── SkillsListView.swift  # 技能列表面板
```

### Skill 协议

```swift
protocol Skill: Identifiable {
    var id: String { get }
    var name: String { get }
    var emoji: String { get }
    var category: SkillCategory { get }
    
    func execute(context: SkillContext) async throws -> SkillResult
}
```

### 添加新技能

在 `AISkill` 枚举中添加：

```swift
case myNewSkill = "my_new_skill"

var name: String { 
    switch self {
    case .myNewSkill: return "我的新技能"
    // ...
    }
}

var requiredCapability: Capability? {
    switch self {
    case .myNewSkill: return .textChat
    // ...
    }
}
```

然后在 `AISkillRegistry.execute` 中添加执行逻辑。

## 未来扩展

1. **自定义 Skills** - 用户可创建自己的技能
2. **Skill 市场** - 分享和下载社区技能
3. **快捷键绑定** - 为常用技能设置全局快捷键
4. **语音触发** - 通过语音命令触发技能
