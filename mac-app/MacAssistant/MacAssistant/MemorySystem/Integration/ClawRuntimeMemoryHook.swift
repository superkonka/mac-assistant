//
//  ClawRuntimeMemoryHook.swift
//  MacAssistant
//
//  Integration point between ClawRuntime and Memory System
//

import Foundation

/// ClawRuntimeAdapter 的记忆钩子扩展
extension ClawRuntimeAdapter {
    
    /// 发送消息并自动记录到记忆系统
    func sendMessageWithMemory(
        agent: Agent,
        sessionKey: String,
        sessionLabel: String? = nil,
        requestID: String,
        text: String,
        images: [String] = [],
        planId: String? = nil,
        taskId: String? = nil,
        onAssistantText: (@Sendable (String) async -> Void)? = nil
    ) async throws -> String {
        
        let startTime = Date()
        
        // 调用原始方法
        let response = try await sendMessage(
            agent: agent,
            sessionKey: sessionKey,
            sessionLabel: sessionLabel,
            requestID: requestID,
            text: text,
            images: images,
            onAssistantText: onAssistantText
        )
        
        // 记录到记忆系统（如果启用）
        if MemoryFeatureFlags.enableL0Storage {
            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            
            await MemoryCoordinator.shared.storeExecution(
                planId: planId ?? sessionKey,
                taskId: taskId,
                agentId: agent.id,
                sessionKey: sessionKey,
                prompt: text,
                response: response,
                durationMs: durationMs,
                tokenUsage: nil,  // 可从 response 解析
                metadata: [
                    "requestID": AnyCodable(requestID),
                    "imagesCount": AnyCodable(images.count)
                ]
            )
        }
        
        return response
    }
}

/// OpenClawGatewayClient 的记忆扩展
extension OpenClawGatewayClient {
    
    /// 发送消息并记录到记忆系统
    func sendMessageWithMemoryLogging(
        agent: Agent,
        sessionKey: String,
        sessionLabel: String? = nil,
        requestID: String,
        text: String,
        images: [String] = [],
        planId: String? = nil,
        taskId: String? = nil,
        onAssistantText: (@Sendable (String) async -> Void)? = nil
    ) async throws -> String {
        
        let startTime = Date()
        var latestText = ""
        
        // 包装回调以捕获完整响应
        let wrappedCallback: (@Sendable (String) async -> Void)? = onAssistantText.map { original in
            { @Sendable text in
                latestText = text
                await original(text)
            }
        }
        
        // 调用原始方法
        let response = try await sendMessage(
            agent: agent,
            sessionKey: sessionKey,
            sessionLabel: sessionLabel,
            requestID: requestID,
            text: text,
            images: images,
            onAssistantText: wrappedCallback
        )
        
        // 记录到记忆系统
        if MemoryFeatureFlags.enableL0Storage {
            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            
            await MemoryCoordinator.shared.storeExecution(
                planId: planId ?? derivePlanId(from: sessionKey),
                taskId: taskId,
                agentId: agent.id,
                sessionKey: sessionKey,
                prompt: text,
                response: response,
                durationMs: durationMs,
                tokenUsage: nil,
                metadata: [
                    "agentName": AnyCodable(agent.name),
                    "agentProvider": AnyCodable(agent.provider.rawValue),
                    "model": AnyCodable(agent.model)
                ]
            )
        }
        
        return response
    }
    
    private func derivePlanId(from sessionKey: String) -> String {
        // 从 session key 提取 plan ID
        // 例如: "plan-xxx/task-yyy" -> "plan-xxx"
        sessionKey.components(separatedBy: "/").first ?? sessionKey
    }
}

// MARK: - TaskWorkerPool Memory Integration

extension TaskWorkerPool {
    
    /// 执行任务并记录到记忆系统
    func executeTaskWithMemory(
        _ task: TaskNode,
        in planId: String,
        plan: TaskPlan,
        mainSessionKey: String
    ) async -> TaskResult {
        
        let startTime = Date()
        
        // 构建带记忆上下文的执行
        let context = await MemoryCoordinator.shared.buildTaskContext(
            planId: planId,
            taskId: task.id,
            requiredDepth: .detailed
        )
        
        // 注入记忆上下文到提示词
        let enrichedPrompt = enrichPromptWithContext(task.prompt.template, context: context)
        
        // 执行（这里简化，实际需要调用 runtime）
        // ... 执行逻辑 ...
        let result = TaskResult(
            output: "执行结果",
            metadata: ["taskId": AnyCodable(task.id)],
            usage: nil
        )
        
        // 记录到记忆系统
        let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
        await MemoryCoordinator.shared.storeExecution(
            planId: planId,
            taskId: task.id,
            agentId: resolveAgentRef(task.agentRef).id,
            sessionKey: "\(mainSessionKey)/task-\(task.id)",
            prompt: enrichedPrompt,
            response: result.output,
            durationMs: durationMs,
            tokenUsage: result.usage,
            metadata: result.metadata
        )
        
        return result
    }
    
    private func enrichPromptWithContext(_ prompt: String, context: TaskExecutionContext) -> String {
        var enriched = prompt
        
        if !context.entries.isEmpty {
            enriched += "\n\n[相关背景信息]\n"
            for entry in context.entries.prefix(3) {
                enriched += "- \(entry.content.prefix(100))...\n"
            }
        }
        
        if !context.concepts.isEmpty {
            enriched += "\n[相关概念]\n"
            for concept in context.concepts.prefix(3) {
                enriched += "- \(concept.name): \(concept.definition.prefix(50))...\n"
            }
        }
        
        return enriched
    }
}

// MARK: - 辅助类型

struct TaskNode {
    let id: String
    let prompt: Prompt
    let agentRef: AgentReference
}

struct Prompt {
    let template: String
}

struct AgentReference {
    enum RefType {
        case byId(String)
        case byRole(String)
        case auto
    }
    let type: RefType
}

struct TaskPlan {
    let planId: String
}

struct TaskResult {
    let output: String
    let metadata: [String: AnyCodable]
    let usage: TokenUsage?
}

// 模拟解析
func resolveAgentRef(_ ref: AgentReference) -> Agent {
    // 实际实现中根据 ref 解析 Agent
    Agent(
        name: "Worker",
        emoji: "🤖",
        description: "Task worker",
        provider: .openai,
        model: "gpt-4",
        capabilities: [.textChat]
    )
}

// MARK: - Memory-Aware Conversation Controller

import Combine

/// 支持分层记忆的对话控制器
actor MemoryAwareConversationController {
    private let memoryCoordinator = MemoryCoordinator.shared
    private let runtime: ClawRuntimeAdapter
    
    init(runtime: ClawRuntimeAdapter) {
        self.runtime = runtime
    }
    
    /// 发送用户消息（带记忆增强）
    func sendUserMessage(
        _ text: String,
        sessionKey: String,
        agent: Agent
    ) async throws -> String {
        
        let planId = derivePlanId(from: sessionKey)
        
        // 1. 检索相关记忆
        var contextEntries: [String] = []
        if MemoryFeatureFlags.enableNewRetrieval {
            let query = RetrievalQuery(
                text: text,
                embedding: nil,
                filters: RetrievalFilters(
                    timeRange: nil,
                    categories: nil,
                    minImportance: .normal,
                    entities: nil,
                    planId: planId
                ),
                depth: .detailed,
                maxResults: 5
            )
            
            let result = try? await memoryCoordinator.retrieve(query: query)
            let assembled = await memoryCoordinator.assembleContext(
                retrievalResult: result ?? HierarchicalRetrievalResult(
                    query: query,
                    l2Entries: [],
                    l1Entries: [],
                    l0Entries: [],
                    diffusionPaths: [],
                    totalTokens: 0
                ),
                budget: .default
            )
            
            contextEntries = assembled.sections.map { $0.content }
        }
        
        // 2. 组装增强后的提示词
        let enrichedPrompt = assemblePromptWithMemory(
            userInput: text,
            contextEntries: contextEntries
        )
        
        // 3. 发送消息
        let response = try await runtime.sendMessageWithMemory(
            agent: agent,
            sessionKey: sessionKey,
            requestID: UUID().uuidString,
            text: enrichedPrompt,
            planId: planId
        )
        
        return response
    }
    
    private func assemblePromptWithMemory(
        userInput: String,
        contextEntries: [String]
    ) -> String {
        var prompt = ""
        
        if !contextEntries.isEmpty {
            prompt += "[相关历史信息]\n"
            for entry in contextEntries {
                prompt += "\(entry)\n\n"
            }
            prompt += "---\n\n"
        }
        
        prompt += userInput
        return prompt
    }
    
    private func derivePlanId(from sessionKey: String) -> String {
        sessionKey.components(separatedBy: "/").first ?? "default-plan"
    }
}
