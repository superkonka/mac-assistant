//
//  OpenClawTypes.swift
//  MacAssistant
//
//  OpenClaw 类型占位符 - 已废弃，保留用于编译兼容
//

import Foundation

// MARK: - 状态报告类型

// MARK: - 类型别名（向后兼容）
typealias SkillsStatusReport = OpenClawSkillsStatusReport
typealias SkillStatus = OpenClawSkillStatus
typealias RecoveredOutput = OpenClawRecoveredOutput

struct OpenClawSkillsStatusReport: Codable {
    let workspaceDir: String
    let managedSkillsDir: String
    let skills: [OpenClawSkillStatus]
    
    static let empty = OpenClawSkillsStatusReport(
        workspaceDir: "",
        managedSkillsDir: "",
        skills: []
    )
}

struct OpenClawSkillStatus: Codable {
    let name: String
    let version: String
    let status: String
    let description: String
    let capabilityTags: [String]
    let eligible: Bool
    let disabled: Bool
    
    struct Missing: Codable {
        let bins: [String]
        let env: [String]
        let config: [String]
    }
    let missing: Missing
    
    var isMissing: Bool { status == "missing" }
}

struct OpenClawRecoveredOutput {
    enum Source {
        case history
        case buffer
    }
    
    let content: String
    let isComplete: Bool
    let source: Source
    let text: String
    let sessionID: String?
    let history: String?
    
    init(content: String = "", isComplete: Bool = false, source: Source = .buffer, text: String = "", sessionID: String? = nil, history: String? = nil) {
        self.content = content
        self.isComplete = isComplete
        self.source = source
        self.text = text
        self.sessionID = sessionID
        self.history = history
    }
}

// MARK: - Client 占位符

class OpenClawGatewayClient {
    static let shared = OpenClawGatewayClient()
    
    func sendMessage(agent: Agent, sessionKey: String, sessionLabel: String?, requestID: String, text: String, images: [String], systemPrompt: String?, onAssistantText: (@Sendable (String) async -> Void)?) async throws -> String {
        throw NSError(domain: "OpenClaw", code: -1, userInfo: [NSLocalizedDescriptionKey: "OpenClaw 已移除"])
    }
    
    func skillsStatus() async throws -> OpenClawSkillsStatusReport { .empty }
    func recoverInterruptedTaskOutput(sessionKey: String, requestStartedAt: Date, latestAssistantText: String) async -> OpenClawRecoveredOutput? { nil }
    func injectAssistantMessage(sessionKey: String, message: String, label: String?) async throws {}
    func prepareGateway() async throws {}
    static func uniqueSessionLabel(base: String, uniqueSource: String) -> String { "\(base)-\(uniqueSource)" }
}

// MARK: - RuntimeManager 占位符

class OpenClawGatewayRuntimeManager {
    static let shared = OpenClawGatewayRuntimeManager()
    
    struct GatewayInspection {
        let logPath: String
        let executablePath: String?
        let version: String?
        let readinessDescription: String
        let runtimeDirectory: String
        let configPath: String
    }
    
    func ensureGatewayReady() async throws {}
    func ensureGatewayReadyWithDependencies() async throws -> Bool { false }
    func forceRestart() async throws {}
    func inspectGatewayState(preferredExecutablePath: String?) async -> GatewayInspection {
        GatewayInspection(logPath: "", executablePath: nil, version: nil, readinessDescription: "已移除", runtimeDirectory: "", configPath: "")
    }
    
    func currentExecutablePath() -> String? { nil }
    func currentProcessEnvironment() -> [String: String] { [:] }
    func currentProfileName() -> String { "native" }
}

// MARK: - Doctor 占位符

class OpenClawDoctor: ObservableObject {
    static let shared = OpenClawDoctor()
    
    enum Status: Equatable {
        case checking, healthy, externalHealthy, needsRepair, missingBundle, repairing, reinstalling
    }
    
    struct Snapshot: Equatable {
        let status: Status
        let summary: String
        let detail: String
        let recommendation: String
        let sourceLabel: String
        let executablePath: String?
        let version: String?
        let readinessDescription: String
        let runtimeDirectory: String
        let configPath: String
        let logPath: String
        let logExcerpt: String?
        let lastCheckedAt: Date?
        let canRepair: Bool
        let canReinstall: Bool
    }
    
    @Published var snapshot = Snapshot(
        status: .missingBundle,
        summary: "已移除",
        detail: "使用原生运行时",
        recommendation: "无需操作",
        sourceLabel: "native",
        executablePath: nil,
        version: nil,
        readinessDescription: "已移除",
        runtimeDirectory: "",
        configPath: "",
        logPath: "",
        logExcerpt: nil,
        lastCheckedAt: Date(),
        canRepair: false,
        canReinstall: false
    )
    
    @Published var isRefreshing = false
    @Published var isRepairing = false
    @Published var isReinstalling = false
    
    func startMonitoring() {}
    func stopMonitoring() {}
    func refresh(allowAutoRepair: Bool = false) {}
    func repair() {}
    func reinstall() {}
    func openRuntimeDirectory() {}
    func openConfigFile() {}
    func openLogDirectory() {}
}

// MARK: - Bridge 占位符

class OpenClawBridge {
    static let shared = OpenClawBridge()
}

// MARK: - Marketplace 占位符

class ClawHubMarketplaceService: ObservableObject {
    static let shared = ClawHubMarketplaceService()
    
    struct SkillItem: Identifiable {
        let id: String
        let name: String
        var badgeText: String? { nil }
    }
    
    struct InstalledSkill: Identifiable {
        let id: String
        let name: String
        enum Status: String { case unknown, ready, error }
        var status: Status { .unknown }
    }
    
    struct RemoteSkill: Identifiable {
        let id: String
        let name: String
    }
    
    @Published var availableSkills: [SkillItem] = []
    @Published var installedSkills: [InstalledSkill] = []
    @Published var remoteSkills: [RemoteSkill] = []
    @Published var isLoading = false
    @Published var isRefreshingInstalled = false
    @Published var authState: String = "none"
    @Published var lastNotice: String? = nil
    
    func refreshSkills() async {}
    func refreshInstalledSkills() async {}
    func installSkill(id: String) async throws {}
    func uninstallSkill(id: String) async throws {}
    func refreshAuthState() {}
    func refreshAll() {}
    func loadCatalog() {}
}

// MARK: - MemoryHook 占位符

class ClawRuntimeMemoryHook {
    static let shared = ClawRuntimeMemoryHook()
}
