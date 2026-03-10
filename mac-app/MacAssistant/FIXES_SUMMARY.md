# 体验问题修复总结

## 修复内容

### ✅ 修复 1: 降低意图检测敏感度

**问题**: 用户说"截个图看看我的桌面"被检测为截图意图，但用户只是说说而已

**修复**:
- 只对明确的命令触发检测
- 排除包含"不用"、"不要"、"算了"的输入
- 代码审查需要明确的"review 代码"等指令
- 翻译需要包含"成"或"to"等明确目标语言

```swift
// 修复前：模糊匹配
if containsAny(lowercased, ["截个图", "截图看看", "截屏"]) {
    return .screenshot
}

// 修复后：明确指令 + 排除否定
if containsAny(lowercased, ["截图", "截屏"]) &&
   !lowercased.contains("不用") &&
   !lowercased.contains("不要") {
    return .screenshot
}
```

---

### ✅ 修复 2: Agent 切换时立即检查能力

**问题**: 用户 @GPT-4V 分析图片，系统切换后发现没有 Vision Agent

**修复**:
- 切换前检查目标 Agent 是否支持所需能力
- 如果不支持，立即启动创建流程而不是切换

```swift
// 切换时传入所需能力
await handleAgentSwitch(agent, reason: "...", requiredCapability: .vision)

// 在 handleAgentSwitch 中检查
if let capability = requiredCapability, !agent.supports(capability) {
    // 不切换，直接引导创建
    creationSkill.initiateCreation(for: gap, in: self)
    return
}
```

---

### ✅ 修复 3: OpenClaw 连接健康检查和重试

**问题**: 连接超时导致请求失败

**修复**:
- 添加 `OpenClawHealthChecker` 健康检查
- 定期检查响应时间
- 自动重试机制（最多2次）
- 详细的错误提示和解决建议

```swift
// 健康检查
if healthChecker.status == .unhealthy {
    let recovered = await healthChecker.attemptRecovery()
    if !recovered {
        // 显示详细的错误提示
    }
}

// 带重试的发送
for attempt in 0..<maxRetries {
    do {
        try await performOpenClawRequest(...)
        return // 成功
    } catch {
        // 显示重试提示，继续重试
    }
}
```

---

### ✅ 修复 4: 响应进度指示

**问题**: 长时间响应时没有反馈，用户不知道在做什么

**修复**:
- 初始显示"正在思考..."
- 3秒无响应显示"正在连接..."
- 收到内容后立即更新

```swift
// 初始状态
content: "⏳ \(agent.name) 正在思考..."

// 流式接收时更新
if let content = message["content"] as? String {
    fullContent += content
    messages[index].content = fullContent
}

// 超时提示
if !hasReceivedContent && Date().timeIntervalSince(lastUpdateTime) > 3 {
    messages[index].content = "⏳ \(agent.name) 正在连接..."
}
```

---

### ✅ 修复 5: 用户偏好系统

**问题**: 用户多次拒绝意图检测，系统仍然每次都提示

**修复**:
- `UserPreferenceStore` 记住用户拒绝的 Skill
- 连续拒绝 3 次自动禁用自然语言检测
- 常用 Skill（使用3次以上）自动确认
- 可以导出和重置偏好

```swift
// 记录拒绝
preferences.recordSkillRejection(skill)

// 检查是否应该跳过
if preferences.shouldSkipDetection(skill) {
    await processCleanInput(input, images: images)
    return
}

// 自动确认常用 Skill
if preferences.shouldAutoConfirm(skill) {
    await handleSkillCommand(skill, input: input, images: images)
    return
}
```

---

## 改进后的用户体验

### 场景 1: 自然的拒绝

```
用户: 截个图看看
系统: 💡 检测到 截图分析 意图？
用户: 不用了，谢谢
系统: 好的，已跳过。下次遇到类似情况不再提示此 Skill。

[下次]
用户: 截个图看看
系统: [直接作为普通文本处理，不再提示]
```

### 场景 2: Agent 能力检查

```
用户: @GPT-4V 分析这张图片
系统: ⚠️ GPT-4V Vision 不支持 视觉理解
     
     💡 我可以立即帮你创建一个支持此能力的 Agent：
     
     请选择 AI 提供商：
     1️⃣ OpenAI (GPT-4V)
     2️⃣ Anthropic (Claude 3)
     3️⃣ Moonshot (Kimi K2.5)
```

### 场景 3: 连接错误处理

```
用户: 你好
系统: ⏳ Kimi Local 正在连接...
     [3秒后]
     ⏳ 连接超时，正在进行第 1 次重试...
     [重试成功]
     你好！我是 Kimi...
     
     [或重试失败]
     ❌ 无法连接到 OpenClaw
     
     可能的原因：
     1. OpenClaw 服务未启动
     2. 端口 11434 被占用
     3. 网络连接问题
     
     解决方法：
     • 检查 OpenClaw 是否运行
     • 重启 OpenClaw Bridge 服务
     • 检查网络连接
```

### 场景 4: 响应进度

```
用户: 写一段复杂代码
系统: ⏳ Claude Code 正在思考...
     [收到内容后]
     以下是代码实现... [实时显示]
```

---

## 文件变更

### 新增文件
- `OpenClawHealthChecker.swift` - 健康检查和重试
- `UserPreferenceStore.swift` - 用户偏好存储

### 修改文件
- `ConversationIntelligence.swift` - 降低检测敏感度
- `CommandRunner.swift` - 集成所有修复

---

## 测试建议

1. **测试拒绝检测**
   - 输入"截个图"→确认提示
   - 回复"否"
   - 再次输入"截个图"→应该不再提示

2. **测试 Agent 能力检查**
   - 确保没有 Vision Agent
   - @GPT-4V 并要求分析图片
   - 应该直接提示创建而不是切换

3. **测试连接重试**
   - 停止 OpenClaw 服务
   - 发送消息
   - 应该显示详细错误和解决建议

4. **测试进度指示**
   - 请求复杂任务
   - 观察"正在思考..."和"正在连接..."提示
