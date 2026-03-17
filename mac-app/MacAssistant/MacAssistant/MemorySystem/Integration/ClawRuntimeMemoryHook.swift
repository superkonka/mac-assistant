//
//  ClawRuntimeMemoryHook.swift
//  MacAssistant
//
//  Integration point between ClawRuntime and Memory System
//

import Foundation
import OpenClawKit

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
            systemPrompt: nil,
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
