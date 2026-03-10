# 对话日志分析系统

## 概述

自动记录所有对话交互，分析用户体验问题，并提供优化建议。

## 功能

### 1. 自动日志记录

系统自动记录以下事件：

| 事件类型 | 记录内容 |
|---------|---------|
| 用户输入 | 原始输入、解析结果 (@Agent, /Skill, 意图检测) |
| Agent 切换 | 切换前后、切换原因 |
| Skill 执行 | 执行结果、耗时 |
| 系统响应 | 响应内容、响应时间 |
| 能力缺口 | 检测到的能力缺失 |
| 错误 | 错误类型、上下文 |
| 性能指标 | 各操作耗时 |

### 2. 分析问题类型

系统能识别以下问题：

#### 🔴 严重问题
- **首次交互失败** - 用户第一次使用就遇到错误
- **请求超时** - 响应超过10秒
- **Skill 执行失败率高** - 超过30%失败
- **重复错误** - 同一错误发生多次

#### 🟠 重要问题
- **响应时间过长** - 多次超过3秒
- **Agent 来回切换** - 用户在两个Agent间反复切换
- **意图检测准确率低** - 检测到但未执行
- **连续意图被拒绝** - 用户多次拒绝系统的意图检测

#### 🟡 轻微问题
- **Agent 切换频繁** - 会话中切换超过5次
- **确认提示过多** - 影响用户流程

### 3. 体验指标

| 指标 | 说明 | 目标值 |
|-----|------|-------|
| 成功率 | 成功交互 / 总交互 | > 80% |
| 平均响应时间 | 系统响应耗时 | < 2s |
| Agent 切换次数 | 会话中切换次数 | < 5 |
| 用户确认率 | 确认执行 / 检测意图 | > 60% |
| Skill 成功率 | 成功执行 / 总执行 | > 80% |

## 使用方式

### 在 ChatView 中集成分析器视图

```swift
// 在设置或调试菜单中添加
Button("对话分析") {
    showAnalyzer = true
}
.sheet(isPresented: $showAnalyzer) {
    ConversationAnalyzerView()
}
```

### 查看实时日志

```swift
// 在 SwiftUI Preview 中
ConversationAnalyzerView()
```

### 导出日志

```swift
if let exportURL = ConversationLogger.shared.exportSession(sessionId) {
    // 分享 exportURL
}
```

## 日志文件位置

```
~/Documents/MacAssistant/ConversationLogs/
├── session-xxxx.jsonl       # 原始事件日志
├── session-xxxx-stats.json  # 会话统计
└── session-xxxx-export.json # 导出文件
```

## 分析流程

```
用户对话
    ↓
[ConversationLogger] 自动记录所有事件
    ↓
[ConversationAnalyzer] 分析问题
    ├─ 响应时间分析
    ├─ Agent 切换分析
    ├─ 意图检测分析
    ├─ Skill 执行分析
    ├─ 用户流程分析
    └─ 错误分析
    ↓
[ConversationAnalyzerView] 可视化展示
    ├─ 会话列表
    ├─ 事件时间线
    └─ 分析报告
```

## 优化建议示例

### 场景 1: 意图检测被拒绝

**问题**: 用户连续 4 次拒绝系统的意图检测

**分析**: 用户在使用自然语言时不想触发 Skill

**建议**: 
1. 降低自然语言检测敏感度
2. 只对明确命令触发
3. 添加关闭检测的选项

### 场景 2: Agent 来回切换

**问题**: 用户在 GPT-4V 和 Claude 之间反复切换

**分析**: 切换提示不够清晰，用户不确定该用哪个 Agent

**建议**:
1. 改进 Agent 能力说明
2. 添加自动选择逻辑
3. 显示 Agent 擅长领域的对比

### 场景 3: 响应时间过长

**问题**: 平均响应时间 5.2s，多次超过 3s

**分析**: OpenClaw 连接或模型响应慢

**建议**:
1. 优化 OpenClaw 连接池
2. 使用更快的模型作为默认
3. 添加响应进度提示

## 调试技巧

### 1. 实时查看日志

在 Xcode 控制台添加过滤器：
```
ConversationLogger
```

### 2. 快速测试特定场景

```swift
// 在代码中添加测试日志
ConversationLogger.shared.logUserInput(
    "测试输入",
    parsed: ParsedInput(...)
)
```

### 3. 导出并分享日志

```swift
// 在 App 中添加导出功能
let sessions = ConversationLogger.shared.getSessions()
// 显示列表让用户选择
// 导出为 JSON 文件
```

## 隐私说明

- 日志仅保存在本地 Documents 目录
- 不包含敏感信息（API Key 等）
- 用户可手动删除所有日志

```swift
// 清除所有日志
ConversationLogger.shared.clearAllLogs()
```

## 后续优化方向

1. **实时分析** - 会话进行中实时提示问题
2. **机器学习** - 基于历史数据预测用户意图
3. **A/B 测试** - 对比不同交互方案的效果
4. **用户画像** - 分析用户习惯和偏好
