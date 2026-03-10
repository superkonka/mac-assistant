# Agents & Skills 自然融入会话 - 实现总结

## 新增文件

### 核心服务
- `ConversationIntelligence.swift` - 智能解析 @Agent 和 /Skill
- `IntelligentInputView.swift` - 智能输入框组件
- `BuiltInSkillModels.swift` - AI 技能定义（重命名避免冲突）
- `SkillsListView.swift` - 技能列表面板

### 更新文件
- `ChatView.swift` - 集成智能输入框
- `CommandRunner.swift` - 支持解析后的输入处理
- `ChatModels.swift` - 共享 ChatMessage 和 SkillContext
- `AgentModels.swift` - 更新最新模型定义

## 核心交互

### 1. @Agent 语法
```
用户: @GPT-4V 分析这张图片
系统: 🔄 通过 @GPT-4V 指定，已切换到 👁️ GPT-4V Vision
```

### 2. /Skill 语法
```
用户: /screenshot 看看我的桌面
系统: ✅ 截图分析 执行成功
```

### 3. 自然语言检测
```
用户: 截个图分析一下
系统: 💡 检测到 截图分析 意图
      是否使用 📸 截图分析？回复 "是" 确认
```

### 4. 智能 Agent 建议
```
用户: 分析一下这段代码
系统: 💡 当前 Agent 不支持代码分析
      建议切换到 📝 Claude Code
      是否切换？回复 "是" 确认
```

## 输入框功能

| 触发器 | 功能 | 示例 |
|--------|------|------|
| `@` | 显示 Agent 下拉建议 | `@G` → [@GPT-4V, @Gemini] |
| `/` | 显示 Skill 下拉建议 | `/s` → [/screenshot, /summarize] |
| 自然语言 | 智能检测意图 | "截图" → 提示使用截图技能 |

## 处理流程

```
用户输入
    ↓
ConversationIntelligence.analyzeInput()
    ├─ 检测 @Agent → AgentMention
    ├─ 检测 /Skill → SkillCommand  
    ├─ 自然语言 → detectedSkill
    └─ 能力匹配 → suggestedAgent
    ↓
CommandRunner.processInput()
    ├─ @Agent → handleAgentSwitch() → 切换并提示
    ├─ /Skill → handleSkillCommand() → 执行
    ├─ detectedSkill → handleDetectedSkill() → 确认提示
    ├─ suggestedAgent → handleAgentSuggestion() → 确认/创建
    └─ 普通输入 → processCleanInput() → 正常路由
```

## 确认机制

对于需要确认的检测意图，系统会：

1. 发送确认消息（带 metadata 标记）
2. 等待用户回复 "是"/"y"
3. 根据回复执行或忽略

```swift
// 标记待处理 Skill
metadata: ["pending_skill": skill.rawValue]

// 标记待切换 Agent  
metadata: ["pending_switch": agent.id]
```

## UI 组件

### IntelligentInputView
- TextEditor + 智能提示
- @ 和 / 触发下拉建议
- Skills 和截图快捷按钮

### SkillsListView
- 分类标签（生产力/分析/创建/系统/Agent）
- 技能卡片网格
- 可用/不可用状态显示
- 搜索功能

### ChatView
- Agent 选择器（保留）
- 消息气泡
- 当前 Agent 指示器
- 智能输入框

## 后续优化方向

1. **确认状态持久化** - 记住用户的确认偏好
2. **学习用户习惯** - 自动选择常用的 Agent/Skill
3. **更智能的检测** - 使用 AI 分析更复杂的意图
4. **快捷键支持** - 全局快捷键触发常用 Skill
5. **语音输入** - 语音命令触发 Skill
