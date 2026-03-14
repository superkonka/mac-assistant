//
//  RequestScheduler.swift
//  MacAssistant
//
//  轻量级请求调度器
//  只负责编排和调度，所有执行在 OpenClaw Core 层处理
//

import Foundation
import Combine

/// 请求调度器
/// 职责：
/// 1. 接收用户输入，构建请求上下文
/// 2. 通过 GatewayClient 发送到 OpenClaw Core
/// 3. 聚合 Core 层返回的事件，更新 UI 状态
/// 4. 管理会话生命周期（UI 层面）
class RequestScheduler: ObservableObject {
    static let shared = RequestScheduler()
    
    // MARK: - 发布状态
    
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var isProcessing: Bool = false
    @Published private(set) var currentExecution: ExecutionState?
    @Published private(set) var activeTools: [ActiveToolCall] = []
    @Published private(set) var activeSkills: [ActiveSkillCall] = []
    
    // MARK: - 依赖
    
    private let gateway = GatewayClient.shared
    private let storage = ConversationStorage.shared
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - 类型定义
    
    struct ExecutionState {
        let messageId: String
        let startTime: Date
        var currentAgentId: String?
        var currentAgentName: String?
        var status: Status
        
        enum Status {
            case planning      // 正在规划
            case routing       // 正在路由选择 Agent
            case executing     // 正在执行
            case toolCalling   // 正在调用工具
            case skillCalling  // 正在调用技能
            case synthesizing  // 正在合成回复
            case completed
            case failed(String)
        }
    }
    
    struct ActiveToolCall: Identifiable {
        let id: String
        let toolName: String
        let arguments: String
        let startTime: Date
        var status: ToolStatus
        
        enum ToolStatus {
            case pending
            case running
            case completed(String)  // 结果
            case failed(String)     // 错误
        }
    }
    
    struct ActiveSkillCall: Identifiable {
        let id: String
        let skillId: String
        let skillName: String
        let startTime: Date
        var status: SkillStatus
        
        enum SkillStatus {
            case pending
            case running
            case completed(String)
            case failed(String)
        }
    }
    
    // MARK: - 公共方法
    
    /// 发送用户消息
    /// 所有复杂逻辑（Agent选择、Tool执行、Skill调用）都在 OpenClaw Core 层处理
    func sendMessage(
        content: String,
        images: [RequestContext.ImageAttachment] = [],
        preferredAgentId: String? = nil
    ) async {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        
        let messageId = UUID().uuidString
        let conversationId = storage.currentConversationId
        
        // 1. 创建用户消息并保存
        let userMessage = ChatMessage(
            id: UUID(uuidString: messageId)!,
            role: .user,
            content: content,
            timestamp: Date(),
            attachedImages: images.map { $0.id }
        )
        
        await MainActor.run {
            messages.append(userMessage)
            isProcessing = true
            currentExecution = ExecutionState(
                messageId: messageId,
                startTime: Date(),
                currentAgentId: nil,
                currentAgentName: nil,
                status: .planning
            )
        }
        
        storage.saveMessage(userMessage, conversationId: conversationId)
        
        // 2. 构建请求上下文
        let context = RequestContext(
            conversationId: conversationId,
            messageId: messageId,
            parentMessageId: nil,
            preferredAgentId: preferredAgentId,
            attachedImages: images,
            metadata: nil
        )
        
        // 3. 发送到 Gateway，所有事件从 Core 层返回
        var assistantContent = ""
        var assistantMessage: ChatMessage?
        
        do {
            try await gateway.sendMessage(
                content: content,
                context: context
            ) { [weak self] event in
                guard let self = self else { return }
                
                Task { @MainActor in
                    await self.handleEvent(
                        event,
                        messageId: messageId,
                        assistantContent: &assistantContent,
                        assistantMessage: &assistantMessage
                    )
                }
            }
        } catch {
            await MainActor.run {
                self.handleError(error, messageId: messageId)
            }
        }
    }
    
    /// 取消当前执行
    func cancelCurrent() async {
        guard let execution = currentExecution else { return }
        
        do {
            try await gateway.cancelTask(execution.messageId)
            await MainActor.run {
                currentExecution?.status = .failed("已取消")
                isProcessing = false
            }
        } catch {
            print("取消失败: \(error)")
        }
    }
    
    /// 重新生成消息
    func regenerateMessage(_ messageId: String) async {
        do {
            try await gateway.regenerateMessage(messageId)
        } catch {
            print("重新生成失败: \(error)")
        }
    }
    
    /// 清空会话
    func clearConversation() {
        messages.removeAll()
        storage.createNewConversation()
    }
    
    /// 加载历史会话
    func loadConversation(_ conversationId: String) {
        messages = storage.loadMessages(conversationId: conversationId)
    }
    
    // MARK: - 事件处理
    
    private func handleEvent(
        _ event: GatewayEvent,
        messageId: String,
        assistantContent: inout String,
        assistantMessage: inout ChatMessage?
    ) async {
        switch event {
        // 文本内容
        case .textChunk(let text):
            assistantContent += text
            updateOrCreateAssistantMessage(
                content: assistantContent,
                messageId: messageId,
                assistantMessage: &assistantMessage
            )
            
        case .textComplete(let text):
            assistantContent = text
            updateOrCreateAssistantMessage(
                content: text,
                messageId: messageId,
                assistantMessage: &assistantMessage
            )
            finalizeMessage(assistantMessage)
            
        // 思考过程
        case .thinkingStart(let title):
            currentExecution?.status = .planning
            // 可以展示思考标题
            
        case .thinkingChunk(let text):
            // 可以流式展示思考过程
            break
            
        case .thinkingEnd:
            currentExecution?.status = .routing
            
        // Agent 状态
        case .agentStart(let agentId, let agentName):
            currentExecution?.currentAgentId = agentId
            currentExecution?.currentAgentName = agentName
            currentExecution?.status = .executing
            
        case .agentSwitch(let from, let to, let reason):
            currentExecution?.currentAgentId = to
            // 可以展示切换提示
            
        case .agentEnd:
            currentExecution?.status = .synthesizing
            
        // Tool 调用
        case .toolStart(let call):
            currentExecution?.status = .toolCalling
            let activeTool = ActiveToolCall(
                id: call.id,
                toolName: call.toolName,
                arguments: "",
                startTime: call.timestamp,
                status: .running
            )
            activeTools.append(activeTool)
            
        case .toolEnd(let result):
            if let index = activeTools.firstIndex(where: { $0.id == result.callId }) {
                if result.success {
                    activeTools[index].status = .completed(result.output ?? "")
                } else {
                    activeTools[index].status = .failed(result.error ?? "未知错误")
                }
                // 延迟移除
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    self?.activeTools.removeAll { $0.id == result.callId }
                }
            }
            
        // Skill 调用
        case .skillStart(let invocation):
            currentExecution?.status = .skillCalling
            let activeSkill = ActiveSkillCall(
                id: invocation.id,
                skillId: invocation.skillId,
                skillName: invocation.skillName,
                startTime: invocation.timestamp,
                status: .running
            )
            activeSkills.append(activeSkill)
            
        case .skillEnd(let result):
            if let index = activeSkills.firstIndex(where: { $0.id == result.invocationId }) {
                if result.success {
                    activeSkills[index].status = .completed(result.output ?? "")
                } else {
                    activeSkills[index].status = .failed(result.error ?? "未知错误")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    self?.activeSkills.removeAll { $0.id == result.invocationId }
                }
            }
            
        // 任务状态
        case .taskStart(let taskId, let description):
            // 可以展示子任务开始
            break
            
        case .taskProgress(let taskId, let percent):
            // 可以更新进度条
            break
            
        case .taskComplete:
            // 子任务完成
            break
            
        case .taskError(let taskId, let error):
            // 子任务错误
            break
            
        // 完成和错误
        case .done:
            isProcessing = false
            currentExecution = nil
            activeTools.removeAll()
            activeSkills.removeAll()
            
        case .error(let error):
            handleError(error, messageId: messageId)
            
        case .cancelled:
            isProcessing = false
            currentExecution?.status = .failed("已取消")
        }
    }
    
    // MARK: - 私有方法
    
    private func updateOrCreateAssistantMessage(
        content: String,
        messageId: String,
        assistantMessage: inout ChatMessage?
    ) {
        if let existing = assistantMessage {
            // 更新现有消息
            if let index = messages.firstIndex(where: { $0.id == existing.id }) {
                messages[index].content = content
            }
        } else {
            // 创建新消息
            let newMessage = ChatMessage(
                id: UUID(),
                role: .assistant,
                content: content,
                timestamp: Date(),
                agentId: currentExecution?.currentAgentId,
                agentName: currentExecution?.currentAgentName
            )
            assistantMessage = newMessage
            messages.append(newMessage)
        }
    }
    
    private func finalizeMessage(_ message: ChatMessage?) {
        guard let message = message else { return }
        storage.saveMessage(message, conversationId: storage.currentConversationId)
        currentExecution?.status = .completed
    }
    
    private func handleError(_ error: Error, messageId: String) {
        isProcessing = false
        currentExecution?.status = .failed(error.localizedDescription)
        
        // 添加错误消息
        let errorMessage = ChatMessage(
            id: UUID(),
            role: .system,
            content: "抱歉，处理过程中出现了错误: \(error.localizedDescription)",
            timestamp: Date()
        )
        messages.append(errorMessage)
    }
}

// MARK: - 存储层

class ConversationStorage {
    static let shared = ConversationStorage()
    
    var currentConversationId: String = UUID().uuidString
    
    func saveMessage(_ message: ChatMessage, conversationId: String) {
        // 实现本地持久化
    }
    
    func loadMessages(conversationId: String) -> [ChatMessage] {
        // 实现从本地加载
        return []
    }
    
    func createNewConversation() {
        currentConversationId = UUID().uuidString
    }
}
