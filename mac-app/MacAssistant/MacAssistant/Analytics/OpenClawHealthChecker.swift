//
//  OpenClawHealthChecker.swift
//  MacAssistant
//
//  OpenClaw 连接健康检查和自动恢复
//

import Foundation

/// OpenClaw 健康状态
enum OpenClawHealthStatus {
    case healthy          // 健康
    case degraded         // 性能下降
    case unhealthy        // 不可用
    case unknown          // 未知
}

/// OpenClaw 健康检查器
class OpenClawHealthChecker: ObservableObject {
    static let shared = OpenClawHealthChecker()
    
    @Published var status: OpenClawHealthStatus = .unknown
    @Published var lastCheckTime: Date?
    @Published var averageResponseTime: TimeInterval = 0
    @Published var errorCount: Int = 0
    @Published var isChecking = false
    
    private var checkTimer: Timer?
    private var responseTimes: [TimeInterval] = []
    
    // MARK: - 健康检查
    
    /// 执行健康检查
    func checkHealth() async -> OpenClawHealthStatus {
        await MainActor.run { isChecking = true }
        
        let startTime = Date()
        var status: OpenClawHealthStatus = .unknown
        var shouldIncrementErrorCount = false
        
        do {
            _ = try await OpenClawGatewayRuntimeManager.shared.ensureGatewayReady()
            let responseTime = Date().timeIntervalSince(startTime)
            
            if responseTime < 1.0 {
                status = .healthy
            } else if responseTime < 3.0 {
                status = .degraded
            } else {
                status = .unhealthy
            }
            
            recordResponseTime(responseTime)
            
        } catch {
            status = .unhealthy
            shouldIncrementErrorCount = true
        }

        let resolvedStatus = status
        let resolvedLastCheckTime = Date()
        let shouldIncrementErrorCountSnapshot = shouldIncrementErrorCount

        await MainActor.run {
            self.status = resolvedStatus
            self.lastCheckTime = resolvedLastCheckTime
            if shouldIncrementErrorCountSnapshot {
                self.errorCount += 1
            }
            self.isChecking = false
        }

        return resolvedStatus
    }
    
    /// 检查是否健康（快速检查，不等待）
    var isHealthy: Bool {
        status == .healthy || status == .degraded
    }
    
    /// 获取健康提示
    var healthMessage: String {
        switch status {
        case .healthy:
            return "✅ OpenClaw 运行正常"
        case .degraded:
            return "⚠️ OpenClaw 响应较慢"
        case .unhealthy:
            return "❌ OpenClaw 连接失败"
        case .unknown:
            return "⏳ 检查中..."
        }
    }
    
    // MARK: - 自动检查
    
    /// 启动定期检查
    func startPeriodicChecks(interval: TimeInterval = 30) {
        stopPeriodicChecks()
        
        checkTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task {
                await self.checkHealth()
            }
        }
        
        // 立即执行一次检查
        Task {
            await checkHealth()
        }
    }
    
    /// 停止定期检查
    func stopPeriodicChecks() {
        checkTimer?.invalidate()
        checkTimer = nil
    }
    
    // MARK: - 连接恢复
    
    /// 尝试恢复连接
    func attemptRecovery() async -> Bool {
        await MainActor.run {
            status = .unknown
        }

        do {
            _ = try await OpenClawGatewayRuntimeManager.shared.forceRestart()
            let status = await checkHealth()
            return status != .unhealthy
        } catch {
            return false
        }
    }
    
    // MARK: - 私有方法
    
    private func recordResponseTime(_ time: TimeInterval) {
        responseTimes.append(time)
        // 只保留最近 10 次
        if responseTimes.count > 10 {
            responseTimes.removeFirst()
        }
        
        // 计算平均值
        if !responseTimes.isEmpty {
            averageResponseTime = responseTimes.reduce(0, +) / Double(responseTimes.count)
        }
    }
}

// MARK: - 发送请求扩展

extension CommandRunner {
    /// 带健康检查的发送请求
    func sendToOpenClawWithRetry(agent: Agent, text: String, images: [String], maxRetries: Int = 2) async {
        let healthChecker = OpenClawHealthChecker.shared
        
        // 1. 检查健康状态
        if healthChecker.status == .unhealthy {
            // 尝试恢复
            let recovered = await healthChecker.attemptRecovery()
            if !recovered {
                await MainActor.run {
                    let errorMessage = ChatMessage(
                        id: UUID(),
                        role: MessageRole.assistant,
                        content: """
                        ❌ 无法连接到 OpenClaw
                        
                        可能的原因：
                        1. OpenClaw gateway wrapper 未启动
                        2. OpenClaw 本体配置异常
                        3. 当前 Agent 的底层模型不可用
                        
                        解决方法：
                        • 检查 OpenClaw gateway 是否已启动
                        • 重新配置当前 Agent
                        • 重启应用后再试
                        """,
                        timestamp: Date()
                    )
                    messages.append(errorMessage)
                    isProcessing = false
                }
                return
            }
        }
        
        // 2. 尝试发送请求（带重试）
        var lastError: Error?
        
        for attempt in 0..<maxRetries {
            do {
                // 显示重试提示
                if attempt > 0 {
                    await MainActor.run {
                        let retryMessage = ChatMessage(
                            id: UUID(),
                            role: MessageRole.system,
                            content: "⏳ 连接超时，正在进行第 \(attempt + 1) 次重试...",
                            timestamp: Date()
                        )
                        messages.append(retryMessage)
                    }
                    try? await Task.sleep(nanoseconds: 1_000_000_000) // 等待1秒
                }
                
                // 发送请求
                try await performOpenClawRequest(agent: agent, text: text, images: images)
                return // 成功，直接返回
                
            } catch {
                lastError = error
                ConversationLogger.shared.logError(error, context: "OpenClaw 请求 (attempt \(attempt + 1))")
                
                // 如果不是超时错误，不再重试
                if !isTimeoutError(error) {
                    break
                }
            }
        }
        
        let failureDescription = lastError?.localizedDescription ?? "未知错误"

        // 3. 所有重试都失败了
        await MainActor.run {
            let errorMessage = ChatMessage(
                id: UUID(),
                role: MessageRole.assistant,
                content: """
                ❌ 请求失败
                
                错误: \(failureDescription)
                
                建议：
                • 检查网络连接
                • 稍后重试
                • 尝试切换其他 Agent
                """,
                timestamp: Date()
            )
            messages.append(errorMessage)
            isProcessing = false
        }
    }
    
    /// 执行实际的 OpenClaw 请求
    private func performOpenClawRequest(agent: Agent, text: String, images: [String]) async throws {
        // 这里放原来的 sendToOpenClaw 逻辑
        // ...
    }
    
    /// 检查是否是超时错误
    private func isTimeoutError(_ error: Error) -> Bool {
        let errorDescription = error.localizedDescription.lowercased()
        return errorDescription.contains("timeout") ||
               errorDescription.contains("timed out") ||
               errorDescription.contains("连接超时")
    }
}
