//
//  RuntimeDoctor.swift
//  MacAssistant
//
//  运行时健康诊断（通用版，支持原生运行时和兼容层）
//

import AppKit
import Foundation

@MainActor
final class RuntimeDoctor: ObservableObject {
    enum Status: Equatable {
        case checking
        case healthy
        case fallback
        case needsAttention
        case missingRuntime
        
        var title: String {
            switch self {
            case .checking:
                return "检查中"
            case .healthy:
                return "运行正常"
            case .fallback:
                return "兼容运行"
            case .needsAttention:
                return "需要关注"
            case .missingRuntime:
                return "缺少运行时"
            }
        }
        
        var shortLabel: String {
            switch self {
            case .checking:
                return "检查中"
            case .healthy:
                return "原生运行"
            case .fallback:
                return "兼容层"
            case .needsAttention:
                return "需要关注"
            case .missingRuntime:
                return "缺少运行时"
            }
        }
        
        var iconName: String {
            switch self {
            case .checking:
                return "arrow.triangle.2.circlepath"
            case .healthy:
                return "checkmark.circle.fill"
            case .fallback:
                return "checkmark.circle"
            case .needsAttention:
                return "exclamationmark.circle.fill"
            case .missingRuntime:
                return "exclamationmark.triangle.fill"
            }
        }
    }
    
    struct Snapshot: Equatable {
        let status: Status
        let summary: String
        let detail: String
        let recommendation: String
        let runtimeType: String
        let availableProviders: [String]
        let lastCheckedAt: Date?
    }
    
    static let shared = RuntimeDoctor()
    
    @Published private(set) var snapshot = Snapshot(
        status: .checking,
        summary: "正在检查运行时状态。",
        detail: "应用优先使用原生运行时，必要时自动切换到兼容层。",
        recommendation: "稍候会自动刷新状态。",
        runtimeType: "检查中...",
        availableProviders: [],
        lastCheckedAt: nil
    )
    
    @Published private(set) var isRefreshing = false
    
    private let healthChecker = RuntimeHealthChecker.shared
    private var refreshTimer: Timer?
    private var hasStarted = false
    
    func startMonitoring() {
        guard !hasStarted else { return }
        hasStarted = true
        
        refresh()
        
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }
    
    func stopMonitoring() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        hasStarted = false
    }
    
    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        
        Task {
            let healthStatus = await healthChecker.checkHealth()
            let newSnapshot = createSnapshot(from: healthStatus)
            
            await MainActor.run {
                self.snapshot = newSnapshot
                self.isRefreshing = false
            }
        }
    }
    
    private func createSnapshot(from status: RuntimeHealthStatus) -> Snapshot {
        let runtimeType = healthChecker.activeRuntime
        let providers = getAvailableProviders()
        
        switch status {
        case .healthy:
            return Snapshot(
                status: .healthy,
                summary: "原生运行时工作正常",
                detail: "当前使用原生运行时处理请求，无需兼容层。",
                recommendation: "一切正常，继续使用。",
                runtimeType: runtimeType,
                availableProviders: providers,
                lastCheckedAt: Date()
            )
            
        case .fallbackActive:
            return Snapshot(
                status: .fallback,
                summary: "正在使用兼容层",
                detail: "原生运行时不可用，已自动切换到 OpenClaw 兼容层。",
                recommendation: "如需使用原生运行时，请检查 Agent 配置。",
                runtimeType: runtimeType,
                availableProviders: providers,
                lastCheckedAt: Date()
            )
            
        case .degraded:
            return Snapshot(
                status: .needsAttention,
                summary: "运行时性能下降",
                detail: "响应时间较长，可能影响使用体验。",
                recommendation: "检查网络连接或稍后重试。",
                runtimeType: runtimeType,
                availableProviders: providers,
                lastCheckedAt: Date()
            )
            
        case .unhealthy, .unknown:
            return Snapshot(
                status: .missingRuntime,
                summary: "无可用运行时",
                detail: "未检测到可用的运行时。",
                recommendation: "请至少配置一个 Agent 以开始使用。",
                runtimeType: runtimeType,
                availableProviders: providers,
                lastCheckedAt: Date()
            )
        }
    }
    
    private func getAvailableProviders() -> [String] {
        let agents = AgentStore.shared.usableAgents
        return agents.map { $0.provider.displayName }
    }
}
