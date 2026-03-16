import CryptoKit
import Foundation

@MainActor
class OpenClawGatewayRuntimeManager {
    struct Endpoint: Sendable {
        let url: URL
        let generation: Int
    }

    struct ManagedState: Sendable {
        let endpoint: Endpoint
        let modelRefsByAgentID: [String: String]
        let primaryModelRef: String?
    }

    struct GatewayInspection: Sendable {
        let executablePath: String?
        let profileDirectory: URL
        let configPath: URL
        let workspaceDirectory: URL
        let logPath: URL
        let processRunning: Bool
        let configExists: Bool
        let healthCheckSucceeded: Bool
        let healthCheckOutput: String
        let readinessDescription: String
    }
    
    /// Gateway 准备状态
    enum GatewayReadiness {
        case notStarted
        case installingDependencies
        case starting
        case ready(endpoint: Endpoint)
        case failed(String)
    }

    static let shared = OpenClawGatewayRuntimeManager()

    private let profileName = "macassistant-wrapper"
    private let gatewayHost = "127.0.0.1"
    private let gatewayPort = 18889
    private let agentStore = AgentStore.shared
    private let dependencyManager = DependencyManager.shared

    private var gatewayProcess: Process?
    private var managedState = ManagedState(
        endpoint: Endpoint(url: URL(string: "ws://127.0.0.1:18889")!, generation: 0),
        modelRefsByAgentID: [:],
        primaryModelRef: nil
    )
    private var configFingerprint: String?
    private var lastGatewayHealthCheckAt = Date.distantPast
    private var lastGatewayHealthWasOK = false
    private let gatewayHealthCheckCacheWindow: TimeInterval = 2
    private var openclawExecutablePath: String?
    
    /// 当前 Gateway 状态（用于 UI 展示）
    @Published var readiness: GatewayReadiness = .notStarted

    func prepareGateway() async throws {
        _ = try await ensureGatewayReadyWithDependencies()
    }
    
    /// 准备 Gateway（带依赖安装）
    func prepareGatewayWithDependencies() async throws -> ManagedState {
        try await ensureGatewayReadyWithDependencies()
    }

    func ensureGatewayReadyWithDependencies() async throws -> ManagedState {
        // 1. 确保 OpenClaw CLI 可用
        await MainActor.run {
            self.readiness = .installingDependencies
        }
        
        do {
            let openclawPath = try await dependencyManager.ensureOpenClawAvailable()
            self.openclawExecutablePath = openclawPath
        
            LogInfo("🦞 使用 OpenClaw: \(openclawPath)")
        
            // 2. 启动 Gateway
            await MainActor.run {
                self.readiness = .starting
            }
        
            let state = try await ensureGatewayReady()
        
            await MainActor.run {
                self.readiness = .ready(endpoint: state.endpoint)
            }
        
            return state
        } catch {
            await MainActor.run {
                self.readiness = .failed(error.localizedDescription)
            }
            throw error
        }
    }

    func ensureGatewayReady() async throws -> ManagedState {
        let snapshot = try self.buildManagedConfigSnapshot()
        let configChanged = snapshot.fingerprint != self.configFingerprint

        self.managedState = ManagedState(
            endpoint: Endpoint(
                url: URL(string: "ws://\(self.gatewayHost):\(self.gatewayPort)")!,
                generation: configChanged ? self.managedState.endpoint.generation + 1 : self.managedState.endpoint.generation
            ),
            modelRefsByAgentID: snapshot.modelRefsByAgentID,
            primaryModelRef: snapshot.primaryModelRef
        )

        if configChanged {
            let usableAgentSummary = snapshot.modelRefsByAgentID
                .sorted(by: { $0.key < $1.key })
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ", ")
            LogDebug("生成 OpenClaw wrapper 配置，可用模型映射: \(usableAgentSummary)")
            try self.writeConfig(data: snapshot.data)
            self.configFingerprint = snapshot.fingerprint
            self.lastGatewayHealthCheckAt = .distantPast
            self.lastGatewayHealthWasOK = false
            try await self.stopGatewayIfNeeded()
            try self.startGatewayProcess()
            try await self.waitUntilHealthy()
            return self.managedState
        }

        if !self.gatewayHealthOK() {
            try self.startGatewayProcess()
            try await self.waitUntilHealthy()
        }

        return self.managedState
    }

    func forceRestart() async throws -> ManagedState {
        try await self.stopGatewayIfNeeded()
        try self.startGatewayProcess()
        try await self.waitUntilHealthy()
        return self.managedState
    }

    func modelRef(for agent: Agent) async throws -> String? {
        let state = try await ensureGatewayReady()
        return state.modelRefsByAgentID[agent.id]
    }

    func primaryModelRef() async throws -> String? {
        try await ensureGatewayReady().primaryModelRef
    }

    func workspaceDirectory() -> URL {
        self.profileDirectory().appendingPathComponent("workspace", isDirectory: true)
    }

    func managedSkillsDirectory() -> URL {
        self.workspaceDirectory().appendingPathComponent("skills", isDirectory: true)
    }

    func currentExecutablePath() -> String? {
        self.openclawExecutablePath
    }

    func currentProfileName() -> String {
        self.profileName
    }

    func currentProcessEnvironment() -> [String: String] {
        self.processEnvironment()
    }

    func stopGateway() async throws {
        try await self.stopGatewayIfNeeded()
    }

    func resetRuntimeState(preserveWorkspace: Bool = true) async throws {
        try await self.stopGatewayIfNeeded()

        let fileManager = FileManager.default
        let profileDirectory = self.profileDirectory()

        if fileManager.fileExists(atPath: profileDirectory.path) {
            if preserveWorkspace {
                let entries = try fileManager.contentsOfDirectory(
                    at: profileDirectory,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
                for entry in entries where entry.lastPathComponent != "workspace" {
                    try? fileManager.removeItem(at: entry)
                }
            } else {
                try fileManager.removeItem(at: profileDirectory)
            }
        }

        self.configFingerprint = nil
        self.lastGatewayHealthCheckAt = .distantPast
        self.lastGatewayHealthWasOK = false
        self.readiness = .notStarted
    }

    func inspectGatewayState(preferredExecutablePath: String? = nil) async -> GatewayInspection {
        let executablePath = preferredExecutablePath ?? self.openclawExecutablePath ?? self.resolveExecutable(named: "openclaw")
        let profileDirectory = self.profileDirectory()
        let configPath = self.configPath()
        let workspaceDirectory = self.workspaceDirectory()
        let logPath = self.gatewayLogPath()
        let processRunning = self.gatewayProcess?.isRunning ?? false
        let environment = self.processEnvironment()
        let profileName = self.profileName
        let readinessDescription = self.readinessDescription()

        return await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            let configExists = fileManager.fileExists(atPath: configPath.path)
            let result = Self.executeOpenClaw(
                arguments: [
                    "--profile", profileName,
                    "gateway",
                    "call",
                    "health",
                    "--json",
                ],
                executablePath: executablePath,
                environment: environment
            )

            return GatewayInspection(
                executablePath: executablePath,
                profileDirectory: profileDirectory,
                configPath: configPath,
                workspaceDirectory: workspaceDirectory,
                logPath: logPath,
                processRunning: processRunning,
                configExists: configExists,
                healthCheckSucceeded: result.status == 0,
                healthCheckOutput: result.output.trimmingCharacters(in: .whitespacesAndNewlines),
                readinessDescription: readinessDescription
            )
        }.value
    }

    private struct ManagedConfigSnapshot {
        let data: Data
        let fingerprint: String
        let modelRefsByAgentID: [String: String]
        let primaryModelRef: String?
    }

    private func buildManagedConfigSnapshot() throws -> ManagedConfigSnapshot {
        let workspaceURL = self.profileDirectory().appendingPathComponent("workspace", isDirectory: true)
        try self.prepareWorkspace(at: workspaceURL)

        let usableAgents = self.agentStore.usableAgents
        let workspaceDir = workspaceURL.path

        var modelRefsByAgentID: [String: String] = [:]
        var allowlistedModels: [String: Any] = [:]
        var customProviders: [String: Any] = [:]
        var cliBackends: [String: Any] = [:]

        for agent in usableAgents {
            switch agent.provider {
            case .deepseek, .doubao, .zhipu, .openai, .anthropic, .google, .moonshot, .kimiCLI:
                guard let profile = self.agentStore.runtimeProfile(for: agent) else { continue }

                let providerID = self.providerID(prefix: agent.provider.rawValue, agentID: agent.id)
                let modelRef = "\(providerID)/\(profile.model)"
                modelRefsByAgentID[agent.id] = modelRef
                allowlistedModels[modelRef] = ["alias": agent.name]
                customProviders[providerID] = [
                    "baseUrl": self.normalizedBaseURL(profile.baseURL),
                    "apiKey": profile.apiKey,
                    "api": self.gatewayAdapter(for: agent.provider),
                    "models": [[
                        "id": profile.model,
                        "name": agent.name,
                        "reasoning": false,
                        "input": agent.supportsImageAnalysis ? ["text", "image"] : ["text"],
                        "cost": [
                            "input": 0,
                            "output": 0,
                            "cacheRead": 0,
                            "cacheWrite": 0,
                        ],
                        "contextWindow": max(agent.config.maxTokens, 128000),
                        "maxTokens": max(agent.config.maxTokens, 4096),
                    ]],
                ]
            }
        }

        let primaryModelRef = self.resolvePrimaryModelRef(
            usableAgents: usableAgents,
            modelRefsByAgentID: modelRefsByAgentID
        )
        var defaults: [String: Any] = [
            "workspace": workspaceDir,
            "skipBootstrap": true,
            "models": allowlistedModels,
            "memorySearch": [
                "enabled": true,
                "sources": ["memory", "sessions"],
                "experimental": [
                    "sessionMemory": true,
                ],
            ],
        ]
        if let primaryModelRef {
            defaults["model"] = [
                "primary": primaryModelRef,
                // Recovery is handled at the app layer so the gateway never silently
                // jumps to a stale remote provider and leaks raw auth errors to the UI.
                "fallbacks": [],
            ]
        }
        if !cliBackends.isEmpty {
            defaults["cliBackends"] = cliBackends
        }

        var payload: [String: Any] = [
            "agents": [
                "defaults": defaults,
                "list": [[
                    "id": "desktop",
                    "default": true,
                    "workspace": workspaceDir,
                    "identity": [
                        "name": "Mac Assistant",
                        "emoji": "🦞",
                        "theme": "desktop-wrapper",
                    ],
                ]],
            ],
            "gateway": [
                "mode": "local",
                "port": self.gatewayPort,
                "bind": "loopback",
                "auth": [
                    "mode": "none",
                ],
            ],
            "browser": [
                "enabled": true,
                "color": "#34C759",
            ],
            "tools": self.buildManagedToolConfig(usableAgents: usableAgents),
        ]

        if !customProviders.isEmpty {
            payload["models"] = [
                "mode": "merge",
                "providers": customProviders,
            ]
        }

        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        let fingerprint = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
        return ManagedConfigSnapshot(
            data: data,
            fingerprint: fingerprint,
            modelRefsByAgentID: modelRefsByAgentID,
            primaryModelRef: primaryModelRef
        )
    }

    private func buildManagedToolConfig(usableAgents: [Agent]) -> [String: Any] {
        var web: [String: Any] = [
            "fetch": [
                "enabled": true,
                "maxChars": 50_000,
                "maxCharsCap": 50_000,
                "timeoutSeconds": 30,
                "cacheTtlMinutes": 15,
                "maxRedirects": 3,
            ]
        ]

        if let searchConfig = self.buildManagedWebSearchConfig(usableAgents: usableAgents) {
            web["search"] = searchConfig
        }

        return [
            "web": web
        ]
    }

    private func buildManagedWebSearchConfig(usableAgents: [Agent]) -> [String: Any]? {
        var search: [String: Any] = [
            "enabled": true,
            "maxResults": 5,
            "timeoutSeconds": 30,
            "cacheTtlMinutes": 15,
        ]

        if let apiKey = nonEmptyEnvironmentValue("BRAVE_API_KEY") {
            search["provider"] = "brave"
            search["apiKey"] = apiKey
            return search
        }

        if let apiKey = nonEmptyEnvironmentValue("KIMI_API_KEY")
            ?? nonEmptyEnvironmentValue("MOONSHOT_API_KEY")
            ?? providerSearchAPIKey(for: .moonshot, usableAgents: usableAgents) {
            search["provider"] = "kimi"
            search["kimi"] = ["apiKey": apiKey]
            return search
        }

        if let apiKey = nonEmptyEnvironmentValue("GEMINI_API_KEY")
            ?? providerSearchAPIKey(for: .google, usableAgents: usableAgents) {
            search["provider"] = "gemini"
            search["gemini"] = ["apiKey": apiKey]
            return search
        }

        if let apiKey = nonEmptyEnvironmentValue("XAI_API_KEY") {
            search["provider"] = "grok"
            search["grok"] = ["apiKey": apiKey]
            return search
        }

        if let apiKey = nonEmptyEnvironmentValue("PERPLEXITY_API_KEY") {
            search["provider"] = "perplexity"
            search["perplexity"] = ["apiKey": apiKey]
            return search
        }

        if let apiKey = nonEmptyEnvironmentValue("OPENROUTER_API_KEY") {
            search["provider"] = "perplexity"
            search["perplexity"] = [
                "apiKey": apiKey,
                "baseUrl": "https://openrouter.ai/api/v1",
            ]
            return search
        }

        return nil
    }

    private func providerSearchAPIKey(for provider: ProviderType, usableAgents: [Agent]) -> String? {
        for agent in usableAgents where agent.provider == provider {
            if let apiKey = self.agentStore.runtimeProfile(for: agent)?.apiKey
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !apiKey.isEmpty {
                return apiKey
            }
        }
        return nil
    }

    private func nonEmptyEnvironmentValue(_ key: String) -> String? {
        let value = ProcessInfo.processInfo.environment[key]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    private func resolvePrimaryModelRef(
        usableAgents: [Agent],
        modelRefsByAgentID: [String: String]
    ) -> String? {
        if let defaultAgent = usableAgents.first(where: \.isDefault),
           let modelRef = modelRefsByAgentID[defaultAgent.id] {
            return modelRef
        }

        return usableAgents.compactMap { modelRefsByAgentID[$0.id] }.first
    }

    private func gatewayAdapter(for provider: ProviderType) -> String {
        switch provider {
        case .openai:
            return "openai-responses"
        case .deepseek, .doubao, .zhipu:
            return "openai-completions"
        case .anthropic:
            return "anthropic-messages"
        case .google:
            return "google-generative-ai"
        case .moonshot:
            return "openai-completions"
        case .kimiCLI:
            return "openai-completions"
        }
    }

    private func providerID(prefix: String, agentID: String) -> String {
        let raw = "\(prefix)-\(agentID)".lowercased()
        let sanitized = raw.map { character -> Character in
            if character.isLetter || character.isNumber || character == "-" {
                return character
            }
            return "-"
        }
        return String(sanitized)
    }

    private func normalizedBaseURL(_ baseURL: String) -> String {
        var value = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }

    private func resolveExecutable(named executable: String) -> String? {
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)

        for directory in path where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(executable).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        let commonCandidates = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/\(executable)").path,
            "/opt/homebrew/bin/\(executable)",
            "/usr/local/bin/\(executable)",
            "/usr/bin/\(executable)",
        ]

        return commonCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func prepareWorkspace(at workspaceURL: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: workspaceURL, withIntermediateDirectories: true)

        let skillsURL = workspaceURL.appendingPathComponent("skills", isDirectory: true)
        try fileManager.createDirectory(at: skillsURL, withIntermediateDirectories: true)

        let memoryURL = workspaceURL.appendingPathComponent("memory", isDirectory: true)
        try fileManager.createDirectory(at: memoryURL, withIntermediateDirectories: true)

        let entries = try fileManager.contentsOfDirectory(
            at: workspaceURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        for entry in entries {
            if entry.lastPathComponent == "skills" {
                continue
            }

            let values = try entry.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { continue }

            let skillFile = entry.appendingPathComponent("SKILL.md", isDirectory: false)
            guard fileManager.fileExists(atPath: skillFile.path) else { continue }

            let destination = skillsURL.appendingPathComponent(entry.lastPathComponent, isDirectory: true)
            guard !fileManager.fileExists(atPath: destination.path) else { continue }

            try fileManager.moveItem(at: entry, to: destination)
            LogInfo("🦞 已将 workspace 根目录下的 Skill 迁移到 OpenClaw skills 目录: \(destination.path)")
        }
    }

    func profileDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openclaw-\(self.profileName)")
    }

    func configPath() -> URL {
        self.profileDirectory().appendingPathComponent("openclaw.json")
    }

    func gatewayLogPath() -> URL {
        self.profileDirectory().appendingPathComponent("gateway.log")
    }

    private func writeConfig(data: Data) throws {
        let profileDirectory = self.profileDirectory()
        try FileManager.default.createDirectory(at: profileDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: profileDirectory.appendingPathComponent("workspace"),
            withIntermediateDirectories: true
        )
        try data.write(to: self.configPath(), options: .atomic)
        LogInfo("🦞 已写入 OpenClaw wrapper 配置: \(self.configPath().path)")
    }

    private func stopGatewayIfNeeded() async throws {
        if let gatewayProcess, gatewayProcess.isRunning {
            gatewayProcess.terminate()
            gatewayProcess.waitUntilExit()
        }
        try self.terminateStaleGatewayListeners()
        self.gatewayProcess = nil
        self.lastGatewayHealthCheckAt = .distantPast
        self.lastGatewayHealthWasOK = false
    }

    private func startGatewayProcess() throws {
        try FileManager.default.createDirectory(at: self.profileDirectory(), withIntermediateDirectories: true)

        let logFileHandle: FileHandle
        let logPath = self.gatewayLogPath().path
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: logPath) else {
            throw NSError(
                domain: "OpenClawGatewayRuntimeManager",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "无法打开 OpenClaw gateway 日志文件。"]
            )
        }
        handle.seekToEndOfFile()
        logFileHandle = handle

        let process = Process()
        
        // 使用已安装的 OpenClaw 路径，或回退到系统 PATH
        let executablePath = self.openclawExecutablePath ?? resolveExecutable(named: "openclaw") ?? "/usr/bin/env"
        
        // 如果直接指向 openclaw 可执行文件，就不需要 env wrapper
        let isDirectExecutable = executablePath.hasSuffix("/openclaw") && 
            FileManager.default.isExecutableFile(atPath: executablePath)
        
        if isDirectExecutable {
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = [
                "--profile", self.profileName,
                "gateway",
                "run",
                "--allow-unconfigured",
                "--force",
                "--bind", "loopback",
                "--port", "\(self.gatewayPort)",
                "--auth", "none",
            ]
        } else {
            // 使用 env wrapper
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [
                "openclaw",
                "--profile", self.profileName,
                "gateway",
                "run",
                "--allow-unconfigured",
                "--force",
                "--bind", "loopback",
                "--port", "\(self.gatewayPort)",
                "--auth", "none",
            ]
        }
        
        process.environment = self.processEnvironment()
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardOutput = logFileHandle
        process.standardError = logFileHandle

        try process.run()
        self.gatewayProcess = process
        LogInfo("🦞 已启动 OpenClaw gateway wrapper 进程，PID: \(process.processIdentifier)")
    }

    private func waitUntilHealthy() async throws {
        let start = Date()
        while Date().timeIntervalSince(start) < 20 {
            if self.gatewayHealthOK(forceRefresh: true) {
                return
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        }

        throw NSError(
            domain: "OpenClawGatewayRuntimeManager",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "OpenClaw gateway 启动超时。"]
        )
    }

    private func gatewayHealthOK(forceRefresh: Bool = false) -> Bool {
        let now = Date()
        if !forceRefresh,
           self.lastGatewayHealthWasOK,
           now.timeIntervalSince(self.lastGatewayHealthCheckAt) < self.gatewayHealthCheckCacheWindow {
            return true
        }

        let result = self.runOpenClaw(arguments: [
            "--profile", self.profileName,
            "gateway",
            "call",
            "health",
            "--json",
        ])
        self.lastGatewayHealthCheckAt = now
        self.lastGatewayHealthWasOK = result.status == 0
        return self.lastGatewayHealthWasOK
    }

    private func processEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = dependencyManager.pathEnvironment()
        return environment
    }

    private func terminateStaleGatewayListeners() throws {
        let listenerLookup = Self.executeCommand(
            executablePath: "/usr/sbin/lsof",
            arguments: ["-tiTCP:\(self.gatewayPort)", "-sTCP:LISTEN"],
            environment: self.processEnvironment()
        )

        let pids = listenerLookup.output
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }

        for pid in pids {
            if pid == self.gatewayProcess?.processIdentifier {
                continue
            }

            let comm = Self.executeCommand(
                executablePath: "/bin/ps",
                arguments: ["-p", "\(pid)", "-o", "comm="],
                environment: self.processEnvironment()
            ).output.trimmingCharacters(in: .whitespacesAndNewlines)

            let command = Self.executeCommand(
                executablePath: "/bin/ps",
                arguments: ["-p", "\(pid)", "-o", "command="],
                environment: self.processEnvironment()
            ).output.trimmingCharacters(in: .whitespacesAndNewlines)

            let isGatewayProcess =
                comm == "openclaw-gateway" ||
                command.contains("openclaw-gateway") ||
                (command.contains("openclaw") && command.contains("gateway"))

            guard isGatewayProcess else { continue }

            LogInfo("🦞 终止残留 OpenClaw gateway 进程，PID: \(pid)")
            _ = Self.executeCommand(
                executablePath: "/bin/kill",
                arguments: ["-TERM", "\(pid)"],
                environment: self.processEnvironment()
            )

            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                let status = Self.executeCommand(
                    executablePath: "/bin/ps",
                    arguments: ["-p", "\(pid)"],
                    environment: self.processEnvironment()
                ).status
                if status != 0 {
                    break
                }
                Thread.sleep(forTimeInterval: 0.1)
            }

            let stillRunning = Self.executeCommand(
                executablePath: "/bin/ps",
                arguments: ["-p", "\(pid)"],
                environment: self.processEnvironment()
            ).status == 0

            if stillRunning {
                LogInfo("🦞 强制终止残留 OpenClaw gateway 进程，PID: \(pid)")
                _ = Self.executeCommand(
                    executablePath: "/bin/kill",
                    arguments: ["-KILL", "\(pid)"],
                    environment: self.processEnvironment()
                )
            }
        }
    }

    private func runOpenClaw(arguments: [String]) -> (status: Int32, output: String) {
        Self.executeOpenClaw(
            arguments: arguments,
            executablePath: self.openclawExecutablePath ?? resolveExecutable(named: "openclaw"),
            environment: self.processEnvironment()
        )
    }

    private func readinessDescription() -> String {
        switch self.readiness {
        case .notStarted:
            return "未启动"
        case .installingDependencies:
            return "安装依赖中"
        case .starting:
            return "启动中"
        case .ready:
            return "已就绪"
        case .failed(let message):
            return "失败: \(message)"
        }
    }

    nonisolated private static func executeOpenClaw(
        arguments: [String],
        executablePath: String?,
        environment: [String: String]
    ) -> (status: Int32, output: String) {
        let process = Process()

        if let path = executablePath,
           path.hasSuffix("/openclaw"),
           FileManager.default.isExecutableFile(atPath: path) {
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["openclaw"] + arguments
        }

        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return (process.terminationStatus, output)
        } catch {
            return (
                1,
                (error as NSError).localizedDescription
            )
        }
    }

    nonisolated private static func executeCommand(
        executablePath: String,
        arguments: [String],
        environment: [String: String]
    ) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return (process.terminationStatus, output)
        } catch {
            return (1, "")
        }
    }
}
