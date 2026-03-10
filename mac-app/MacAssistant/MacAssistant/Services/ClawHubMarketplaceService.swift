//
//  ClawHubMarketplaceService.swift
//  MacAssistant
//

import AppKit
import Combine
import Foundation

@MainActor
final class ClawHubMarketplaceService: ObservableObject {
    static let shared = ClawHubMarketplaceService()

    enum AuthState: Equatable {
        case unknown
        case loggedOut
        case loggedIn(handle: String?)
        case rateLimited
        case failed(message: String)

        var badgeText: String {
            switch self {
            case .unknown:
                return "状态未知"
            case .loggedOut:
                return "未登录"
            case .loggedIn(let handle):
                if let handle, !handle.isEmpty {
                    return "@\(handle)"
                }
                return "已登录"
            case .rateLimited:
                return "已限流"
            case .failed:
                return "异常"
            }
        }
    }

    enum CatalogState: Equatable {
        case idle
        case loading
        case ready
        case needsLogin
        case empty
        case rateLimited
        case failed(String)
    }

    struct InstalledSkill: Identifiable, Equatable {
        let slug: String
        let version: String?
        let installedAt: Date
        let registry: String?
        let status: OpenClawSkillStatus?

        var id: String { slug }
        var displayName: String { status?.name ?? slug }
        var summary: String {
            let trimmed = status?.description.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? "来自 ClawHub 的外部 Skill" : trimmed
        }
        var statusSummary: String {
            guard let status else {
                return "等待 OpenClaw 刷新运行状态"
            }
            if status.disabled {
                return "已安装，但当前被禁用"
            }
            if status.eligible {
                return "已安装并可直接使用"
            }

            let missing = (status.missing.bins + status.missing.env + status.missing.config)
            if missing.isEmpty {
                return "已安装，但当前还不能运行"
            }
            return "缺少：\(missing.joined(separator: ", "))"
        }

        static func == (lhs: InstalledSkill, rhs: InstalledSkill) -> Bool {
            lhs.slug == rhs.slug &&
            lhs.version == rhs.version &&
            lhs.installedAt == rhs.installedAt &&
            lhs.registry == rhs.registry &&
            lhs.status?.name == rhs.status?.name &&
            lhs.status?.description == rhs.status?.description &&
            lhs.status?.eligible == rhs.status?.eligible &&
            lhs.status?.disabled == rhs.status?.disabled &&
            lhs.status?.missing.bins == rhs.status?.missing.bins &&
            lhs.status?.missing.env == rhs.status?.missing.env &&
            lhs.status?.missing.config == rhs.status?.missing.config
        }
    }

    struct RemoteSkill: Identifiable, Equatable {
        let slug: String
        let displayName: String
        let summary: String?
        let version: String?
        let updatedAt: Date?
        let downloads: Int?
        let stars: Int?
        let tags: [String]

        var id: String { slug }
    }

    @Published private(set) var authState: AuthState = .unknown
    @Published private(set) var catalogState: CatalogState = .idle
    @Published private(set) var installedSkills: [InstalledSkill] = []
    @Published private(set) var remoteSkills: [RemoteSkill] = []
    @Published private(set) var isRefreshingInstalled = false
    @Published private(set) var isLoadingCatalog = false
    @Published private(set) var activeMutationSlugs: Set<String> = []
    @Published private(set) var lastNotice: String?

    private let runtimeManager = OpenClawGatewayRuntimeManager.shared
    private let gatewayClient = OpenClawGatewayClient.shared
    private let defaultRegistryBaseURL = URL(string: "https://clawhub.ai")!
    private var cancellables = Set<AnyCancellable>()
    private var waitingForBrowserLogin = false
    private var lastQuery = ""

    private init() {
        setupNotifications()
    }

    func refreshAll(query: String = "") async {
        lastQuery = query
        await refreshInstalledSkills()
        await refreshAuthState()
        await loadCatalog(query: query)
    }

    func refreshInstalledSkills() async {
        isRefreshingInstalled = true
        defer { isRefreshingInstalled = false }

        do {
            let workspaceURL = await runtimeManager.workspaceDirectory()
            let skillsDirectoryURL = workspaceURL.appendingPathComponent("skills", isDirectory: true)
            try FileManager.default.createDirectory(at: skillsDirectoryURL, withIntermediateDirectories: true)

            let lockfile = try readLockfile(at: workspaceURL)
            let statuses = await fetchGatewaySkillStatuses()

            let installed = lockfile.skills
                .map { slug, entry in
                    InstalledSkill(
                        slug: slug,
                        version: entry.version,
                        installedAt: Date(timeIntervalSince1970: entry.installedAt / 1000),
                        registry: readOrigin(at: skillsDirectoryURL.appendingPathComponent(slug, isDirectory: true))?.registry,
                        status: statuses[slug]
                    )
                }
                .sorted(by: { $0.installedAt > $1.installedAt })

            installedSkills = installed
        } catch {
            lastNotice = "读取已安装 Skills 失败：\(error.localizedDescription)"
        }
    }

    func refreshAuthState() async {
        do {
            let config = try readGlobalConfig()
            guard let token = config.token, !token.isEmpty else {
                authState = .loggedOut
                return
            }

            let registry = config.registry ?? defaultRegistryBaseURL
            let request = authorizedRequest(
                url: registry.appendingPathComponent("api/v1/whoami"),
                token: token
            )
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = try requireHTTP(response)

            switch http.statusCode {
            case 200:
                let payload = try JSONDecoder().decode(WhoAmIResponse.self, from: data)
                authState = .loggedIn(handle: payload.user.handle)
            case 401, 403:
                authState = .loggedOut
            case 429:
                authState = .rateLimited
            default:
                authState = .failed(message: "HTTP \(http.statusCode)")
            }
        } catch {
            authState = .failed(message: error.localizedDescription)
        }
    }

    func loadCatalog(query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        lastQuery = trimmed

        if trimmed.isEmpty {
            let config = try? readGlobalConfig()
            if config?.token == nil {
                remoteSkills = []
                catalogState = .needsLogin
                return
            }
        }

        isLoadingCatalog = true
        catalogState = .loading
        defer { isLoadingCatalog = false }

        do {
            let config = try readGlobalConfig()
            let baseURL = config.registry ?? defaultRegistryBaseURL
            let token = config.token

            let url: URL
            if trimmed.isEmpty {
                var components = URLComponents(url: baseURL.appendingPathComponent("api/v1/skills"), resolvingAgainstBaseURL: false)
                components?.queryItems = [
                    URLQueryItem(name: "limit", value: "24"),
                    URLQueryItem(name: "sort", value: "updated")
                ]
                url = components?.url ?? baseURL.appendingPathComponent("api/v1/skills")
            } else {
                var components = URLComponents(url: baseURL.appendingPathComponent("api/v1/search"), resolvingAgainstBaseURL: false)
                components?.queryItems = [
                    URLQueryItem(name: "q", value: trimmed),
                    URLQueryItem(name: "limit", value: "24")
                ]
                url = components?.url ?? baseURL.appendingPathComponent("api/v1/search")
            }

            let request = authorizedRequest(url: url, token: token)
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = try requireHTTP(response)

            switch http.statusCode {
            case 200:
                if trimmed.isEmpty {
                    let payload = try JSONDecoder().decode(CatalogListResponse.self, from: data)
                    remoteSkills = payload.items.map(Self.mapRemoteSkill(from:))
                } else {
                    let payload = try JSONDecoder().decode(CatalogSearchResponse.self, from: data)
                    remoteSkills = payload.results.map(Self.mapRemoteSkill(from:))
                }
                catalogState = remoteSkills.isEmpty ? .empty : .ready
            case 401, 403:
                catalogState = .needsLogin
            case 429:
                catalogState = .rateLimited
            default:
                let body = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                catalogState = .failed(body?.isEmpty == false ? body! : "HTTP \(http.statusCode)")
            }
        } catch {
            catalogState = .failed(error.localizedDescription)
        }
    }

    func install(slug: String) async {
        await mutateSkill(slug: slug) { [self] in
            let workspaceURL = await self.runtimeManager.workspaceDirectory()
            _ = try await self.runClawHubCommand(
                arguments: [
                    "--workdir", workspaceURL.path,
                    "--dir", "skills",
                    "install", slug
                ]
            )
            _ = try await self.runtimeManager.forceRestart()
            self.lastNotice = "已安装 \(slug)，并刷新 OpenClaw runtime。"
        }
    }

    func uninstall(slug: String) async {
        await mutateSkill(slug: slug) { [self] in
            let workspaceURL = await self.runtimeManager.workspaceDirectory()
            _ = try await self.runClawHubCommand(
                arguments: [
                    "--workdir", workspaceURL.path,
                    "--dir", "skills",
                    "uninstall", slug,
                    "--yes"
                ]
            )
            _ = try await self.runtimeManager.forceRestart()
            self.lastNotice = "已卸载 \(slug)，并刷新 OpenClaw runtime。"
        }
    }

    func update(slug: String) async {
        await mutateSkill(slug: slug) { [self] in
            let workspaceURL = await self.runtimeManager.workspaceDirectory()
            _ = try await self.runClawHubCommand(
                arguments: [
                    "--workdir", workspaceURL.path,
                    "--dir", "skills",
                    "update", slug
                ]
            )
            _ = try await self.runtimeManager.forceRestart()
            self.lastNotice = "已更新 \(slug)，并刷新 OpenClaw runtime。"
        }
    }

    func launchLogin() async {
        let workspaceURL = await runtimeManager.workspaceDirectory()
        let command = """
        export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/sbin:/usr/sbin"
        npx --yes clawhub@latest --workdir "\(workspaceURL.path)" --dir skills login --label "MacAssistant Marketplace"
        """
        let launched = launchCommandInTerminal(command)
        waitingForBrowserLogin = launched
        lastNotice = launched
            ? "已在终端启动 ClawHub 登录流程，浏览器授权完成后回到应用即可。"
            : "无法自动拉起终端，请手动执行 clawhub 登录。"
    }

    func logout() async {
        do {
            let workspaceURL = await runtimeManager.workspaceDirectory()
            _ = try await runClawHubCommand(
                arguments: [
                    "--workdir", workspaceURL.path,
                    "--dir", "skills",
                    "logout"
                ]
            )
            authState = .loggedOut
            remoteSkills = []
            catalogState = .needsLogin
            lastNotice = "已退出 ClawHub。"
        } catch {
            lastNotice = "退出 ClawHub 失败：\(error.localizedDescription)"
        }
    }

    func isMutating(slug: String) -> Bool {
        activeMutationSlugs.contains(slug)
    }

    private func setupNotifications() {
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    await self.refreshInstalledSkills()
                    await self.refreshAuthState()
                    if self.waitingForBrowserLogin, case .loggedIn = self.authState {
                        self.waitingForBrowserLogin = false
                        await self.loadCatalog(query: self.lastQuery)
                        self.lastNotice = "ClawHub 登录已恢复，可以开始安装或管理 Skills。"
                    }
                }
            }
            .store(in: &cancellables)
    }

    private func fetchGatewaySkillStatuses() async -> [String: OpenClawSkillStatus] {
        do {
            let report = try await gatewayClient.skillsStatus()
            return Dictionary(uniqueKeysWithValues: report.skills.map { ($0.name, $0) })
        } catch {
            return [:]
        }
    }

    private func mutateSkill(slug: String, operation: @escaping @MainActor () async throws -> Void) async {
        activeMutationSlugs.insert(slug)
        defer { activeMutationSlugs.remove(slug) }

        do {
            try await operation()
            await refreshInstalledSkills()
            await loadCatalog(query: lastQuery)
        } catch {
            lastNotice = error.localizedDescription
        }
    }

    private func runClawHubCommand(arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["npx", "--yes", "clawhub@latest"] + arguments
            process.environment = mergedEnvironment()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            process.terminationHandler = { task in
                let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let merged = [output, error]
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if task.terminationStatus == 0 {
                    continuation.resume(returning: merged)
                } else {
                    continuation.resume(
                        throwing: NSError(
                            domain: "ClawHubMarketplaceService",
                            code: Int(task.terminationStatus),
                            userInfo: [NSLocalizedDescriptionKey: merged.isEmpty ? "ClawHub 命令执行失败。" : merged]
                        )
                    )
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func authorizedRequest(url: URL, token: String?) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("MacAssistant/1.0", forHTTPHeaderField: "User-Agent")
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func requireHTTP(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else {
            throw NSError(
                domain: "ClawHubMarketplaceService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "没有拿到有效的 HTTP 响应。"]
            )
        }
        return http
    }

    private func mergedEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/sbin:/usr/sbin"
            .replacingOccurrences(of: "$HOME", with: FileManager.default.homeDirectoryForCurrentUser.path)
        return environment
    }

    private func launchCommandInTerminal(_ command: String) -> Bool {
        let script = """
        tell application "Terminal"
            activate
            do script "\(escapeAppleScript(command))"
        end tell
        """

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]

        do {
            try task.run()
            return true
        } catch {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
            return false
        }
    }

    private func escapeAppleScript(_ command: String) -> String {
        command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func readGlobalConfig() throws -> GlobalConfig {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("Library/Application Support/clawhub/config.json"),
            home.appendingPathComponent("Library/Application Support/clawdhub/config.json")
        ]

        for candidate in candidates where fileManager.fileExists(atPath: candidate.path) {
            let data = try Data(contentsOf: candidate)
            return try JSONDecoder().decode(GlobalConfig.self, from: data)
        }

        return GlobalConfig(registry: defaultRegistryBaseURL, token: nil)
    }

    private func readLockfile(at workspaceURL: URL) throws -> Lockfile {
        let fileManager = FileManager.default
        let candidates = [
            workspaceURL.appendingPathComponent(".clawhub/lock.json"),
            workspaceURL.appendingPathComponent(".clawdhub/lock.json")
        ]

        for candidate in candidates where fileManager.fileExists(atPath: candidate.path) {
            let data = try Data(contentsOf: candidate)
            return try JSONDecoder().decode(Lockfile.self, from: data)
        }

        return Lockfile(version: 1, skills: [:])
    }

    private func readOrigin(at skillDirectoryURL: URL) -> SkillOrigin? {
        let fileManager = FileManager.default
        let candidates = [
            skillDirectoryURL.appendingPathComponent(".clawhub/origin.json"),
            skillDirectoryURL.appendingPathComponent(".clawdhub/origin.json")
        ]

        for candidate in candidates where fileManager.fileExists(atPath: candidate.path) {
            guard let data = try? Data(contentsOf: candidate),
                  let origin = try? JSONDecoder().decode(SkillOrigin.self, from: data) else {
                continue
            }
            return origin
        }

        return nil
    }

    private static func mapRemoteSkill(from item: CatalogSkillListItem) -> RemoteSkill {
        let tags = (item.tags ?? [:]).keys.sorted()
        return RemoteSkill(
            slug: item.slug,
            displayName: item.displayName,
            summary: item.summary,
            version: item.latestVersion?.version,
            updatedAt: Date(timeIntervalSince1970: item.updatedAt / 1000),
            downloads: item.stats?.downloads,
            stars: item.stats?.stars,
            tags: tags
        )
    }

    private static func mapRemoteSkill(from item: CatalogSearchItem) -> RemoteSkill {
        RemoteSkill(
            slug: item.slug ?? "unknown-skill",
            displayName: item.displayName ?? item.slug ?? "未命名 Skill",
            summary: item.summary,
            version: item.version,
            updatedAt: item.updatedAt.map { Date(timeIntervalSince1970: $0 / 1000) },
            downloads: nil,
            stars: nil,
            tags: []
        )
    }
}

private extension ClawHubMarketplaceService {
    struct GlobalConfig: Codable {
        let registry: URL?
        let token: String?
    }

    struct Lockfile: Codable {
        struct Entry: Codable {
            let version: String?
            let installedAt: Double
        }

        let version: Int
        let skills: [String: Entry]
    }

    struct SkillOrigin: Codable {
        let version: Int
        let registry: String
        let slug: String
        let installedVersion: String
        let installedAt: Double
    }

    struct WhoAmIResponse: Codable {
        struct User: Codable {
            let handle: String?
            let displayName: String?
            let image: String?
        }

        let user: User
    }

    struct CatalogListResponse: Codable {
        let items: [CatalogSkillListItem]
        let nextCursor: String?
    }

    struct CatalogSearchResponse: Codable {
        let results: [CatalogSearchItem]
    }

    struct CatalogSkillListItem: Codable {
        struct LatestVersion: Codable {
            let version: String
            let createdAt: Double
            let changelog: String
            let license: String?
        }

        struct Stats: Codable {
            let downloads: Int?
            let stars: Int?
            let versions: Int?
            let comments: Int?
        }

        let slug: String
        let displayName: String
        let summary: String?
        let tags: [String: String]?
        let stats: Stats?
        let createdAt: Double
        let updatedAt: Double
        let latestVersion: LatestVersion?
    }

    struct CatalogSearchItem: Codable {
        let slug: String?
        let displayName: String?
        let summary: String?
        let version: String?
        let score: Double
        let updatedAt: Double?
    }
}
