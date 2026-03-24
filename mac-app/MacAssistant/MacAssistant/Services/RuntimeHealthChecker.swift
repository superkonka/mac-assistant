//
//  RuntimeHealthChecker.swift
//  MacAssistant
//
//  运行时健康检查（支持原生运行时和 OpenClaw 兼容层）
//

import Foundation

/// 运行时健康状态
enum RuntimeHealthStatus: Equatable {
    case healthy          // 健康（原生运行时正常）
    case degraded         // 性能下降
    case fallbackActive   // 正在使用兼容层
    case unhealthy        // 不可用
    case unknown          // 未知
    
    var description: String {
        switch self {
        case .healthy:
            return "原生运行正常"
        case .degraded:
            return "性能下降"
        case .fallbackActive:
            return "兼容层运行中"
        case .unhealthy:
            return "运行异常"
        case .unknown:
            return "检查中..."
        }
    }
}

/// 运行时健康检查器
@MainActor
final class RuntimeHealthChecker: ObservableObject {
    static let shared = RuntimeHealthChecker()
    
    @Published var status: RuntimeHealthStatus = .unknown
    @Published var lastCheckTime: Date?
    @Published var averageResponseTime: TimeInterval = 0
    @Published var errorCount: Int = 0
    @Published var isChecking = false
    @Published var activeRuntime: String = "检查中..."
    
    private var checkTimer: Timer?
    private var responseTimes: [TimeInterval] = []
    
    private init() {}
    
    // MARK: - 健康检查
    
    /// 执行健康检查
    func checkHealth() async -> RuntimeHealthStatus {
        await MainActor.run { isChecking = true }
        
        let startTime = Date()
        var status: RuntimeHealthStatus = .unknown
        
        // 检查当前运行时是原生还是兼容层
        let runtimeType = await checkActiveRuntime()
        
        await MainActor.run {
            self.activeRuntime = runtimeType
        }
        
        do {
            // 测试一个简单的 LLM 调用
            let testResult = try await performHealthCheckTest()
            let responseTime = Date().timeIntervalSince(startTime)
            
            if testResult {
                if runtimeType.contains("原生") {
                    status = responseTime < 3.0 ? .healthy : .degraded
                } else {
                    status = .fallbackActive
                }
            } else {
                status = .unhealthy
            }
            
            recordResponseTime(responseTime)
            
        } catch {
            status = .unhealthy
            await MainActor.run { errorCount += 1 }
        }

        let resolvedStatus = status
        await MainActor.run {
            self.status = resolvedStatus
            self.lastCheckTime = Date()
            self.isChecking = false
        }

        return resolvedStatus
    }
    
    /// 检查当前活跃的运行时
    private func checkActiveRuntime() async -> String {
        // 检查 NativeConversationRuntimeAdapter 是否可用
        let nativeAvailable = await checkNativeRuntimeAvailable()
        if nativeAvailable {
            return "原生运行时 (Native)"
        }
        
        // 原生运行时是唯一运行时
        return "无可用运行时"
    }
    
    /// 检查原生运行时是否可用
    private func checkNativeRuntimeAvailable() async -> Bool {
        // 检查是否有可用的本地 LLM 配置
        let agents = await MainActor.run { AgentStore.shared.usableAgents }
        return !agents.isEmpty
    }
    
    /// 执行健康测试
    private func performHealthCheckTest() async throws -> Bool {
        // 简化：只检查是否能获取可用 agents
        let agents = await MainActor.run { AgentStore.shared.usableAgents }
        return !agents.isEmpty
    }
    
    /// 快速检查是否健康
    var isHealthy: Bool {
        status == .healthy || status == .fallbackActive
    }
    
    /// 获取健康提示
    var healthMessage: String {
        switch status {
        case .healthy:
            return "✅ \(activeRuntime)"
        case .degraded:
            return "⚠️ \(activeRuntime) - 响应较慢"
        case .fallbackActive:
            return "ℹ️ \(activeRuntime)"
        case .unhealthy:
            return "❌ 无可用运行时"
        case .unknown:
            return "⏳ 检查中..."
        }
    }
    
    // MARK: - 自动检查
    
    /// 启动定期检查
    func startPeriodicChecks(interval: TimeInterval = 60) {
        stopPeriodicChecks()
        
        checkTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task {
                await self.checkHealth()
            }
        }
        
        Task {
            await checkHealth()
        }
    }
    
    /// 停止定期检查
    func stopPeriodicChecks() {
        checkTimer?.invalidate()
        checkTimer = nil
    }
    
    // MARK: - 私有方法
    
    private func recordResponseTime(_ time: TimeInterval) {
        responseTimes.append(time)
        if responseTimes.count > 10 {
            responseTimes.removeFirst()
        }
        
        if !responseTimes.isEmpty {
            averageResponseTime = responseTimes.reduce(0, +) / Double(responseTimes.count)
        }
    }
}
