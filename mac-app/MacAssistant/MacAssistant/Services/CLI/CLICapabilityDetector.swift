//
//  CLICapabilityDetector.swift
//  MacAssistant
//
//  检测 CLI 安装状态和可用能力，类似 Kimi CLI 的检测机制
//

import Foundation

/// CLI 能力检测结果
struct CLICapabilityProfile: Equatable {
    let isInstalled: Bool
    let version: String?
    let capabilities: [CLICapability]
    let installPath: String?
    let isCompatible: Bool
    
    /// 是否建议使用 CLI
    var isRecommended: Bool {
        isInstalled && isCompatible
    }
    
    /// 能力评估摘要
    var capabilitySummary: String {
        if !isInstalled {
            return "未安装 CLI，使用内置服务管理"
        }
        if !isCompatible {
            return "CLI 版本不兼容，请升级"
        }
        return "已安装 CLI \(version ?? ""), \(capabilities.count) 项能力可用"
    }
}

enum CLICapability: String, CaseIterable {
    case dockerManagement = "docker"
    case homebrewServices = "homebrew"
    case portDiscovery = "port_discovery"
    case healthMonitoring = "health_monitor"
    case logAggregation = "log_agg"
    case statePersistence = "state_persist"
}

/// CLI 能力检测器 - 用户自主选择的核心
@MainActor
final class CLICapabilityDetector: ObservableObject {
    static let shared = CLICapabilityDetector()
    
    @Published private(set) var profile: CLICapabilityProfile = .notInstalled
    @Published private(set) var isChecking = false
    
    private init() {}
    
    /// 检测 CLI 能力
    func checkCapabilities() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        
        // TODO: 实现实际检测逻辑
        // 模拟检测结果
        profile = CLICapabilityProfile(
            isInstalled: false,
            version: nil,
            capabilities: [],
            installPath: nil,
            isCompatible: false
        )
    }
}

extension CLICapabilityProfile {
    static let notInstalled = CLICapabilityProfile(
        isInstalled: false,
        version: nil,
        capabilities: [],
        installPath: nil,
        isCompatible: false
    )
}
