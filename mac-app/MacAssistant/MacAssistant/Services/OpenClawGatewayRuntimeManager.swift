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
        let currentAgentID = self.agentStore.currentAgent?.id
        let workspaceDir = workspaceURL.path

        var modelRefsByAgentID: [String: String] = [:]
        var allowlistedModels: [String: Any] = [:]
        var customProviders: [String: Any] = [:]
        var cliBackends: [String: Any] = [:]

        for agent in usableAgents {
            switch agent.provider {
            case .ollama:
                guard let commandPath = self.resolveExecutable(named: "kimi") else { continue }

                let providerID = self.providerID(prefix: "kimi-cli", agentID: agent.id)
                let modelRef = "\(providerID)/default"
                modelRefsByAgentID[agent.id] = modelRef
                allowlistedModels[modelRef] = ["alias": agent.name]
                cliBackends[providerID] = [
                    "command": commandPath,
                    "args": [
                        "--quiet",
                        "-y",
                        "--print",
                        "--input-format", "text",
                        "--output-format", "text",
                        "--final-message-only",
                    ],
                    "output": "text",
                    "input": "stdin",
                    "sessionArg": "--session",
                    "sessionMode": "always",
                    "serialize": true,
                ]

            case .openai, .anthropic, .google, .moonshot:
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
            currentAgentID: currentAgentID,
            usableAgents: usableAgents,
            modelRefsByAgentID: modelRefsByAgentID
        )
        var defaults: [String: Any] = [
            "workspace": workspaceDir,
            "skipBootstrap": true,
            "models": allowlistedModels,
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

    private func resolvePrimaryModelRef(
        currentAgentID: String?,
        usableAgents: [Agent],
        modelRefsByAgentID: [String: String]
    ) -> String? {
        if let currentAgentID, let modelRef = modelRefsByAgentID[currentAgentID] {
            return modelRef
        }

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
        case .anthropic:
            return "anthropic-messages"
        case .google:
            return "google-generative-ai"
        case .moonshot:
            return "openai-completions"
        case .ollama:
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

    private func profileDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openclaw-\(self.profileName)")
    }

    private func configPath() -> URL {
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

    func stopGatewayIfNeeded() async throws {
        if let gatewayProcess, gatewayProcess.isRunning {
            gatewayProcess.terminate()
            gatewayProcess.waitUntilExit()
        }
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
        let localBin = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path
        let defaultPath = "\(localBin):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = environment["PATH"].map { "\($0):\(defaultPath)" } ?? defaultPath
        return environment
    }

    private func runOpenClaw(arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        
        // 优先使用已安装的路径
        let executablePath = self.openclawExecutablePath ?? resolveExecutable(named: "openclaw")
        
        if let path = executablePath, path.hasSuffix("/openclaw") {
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["openclaw"] + arguments
        }
        
        process.environment = self.processEnvironment()

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
}
