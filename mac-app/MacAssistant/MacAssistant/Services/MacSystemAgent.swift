import AppKit
import Foundation
import Network

actor MacSystemAgent {
    static let shared = MacSystemAgent()

    private final class PortCheckState: @unchecked Sendable {
        var finished = false
    }

    private enum AppAction {
        case launch
        case quit
        case status
        case list
    }

    private struct AppCommand: Sendable {
        let action: AppAction
        let query: String?
    }

    private struct AppRecord: Hashable, Sendable {
        let displayName: String
        let normalizedName: String
        let bundleIdentifier: String?
        let bundleURL: URL
        let aliases: [String]
    }

    private struct RunningAppSnapshot: Sendable {
        let bundleIdentifier: String?
        let localizedName: String
        let processIdentifier: Int32
        let activationPolicyRegular: Bool
    }

    private let appCatalogTTL: TimeInterval = 60
    private let openDPorts: [UInt16] = [35352, 35351, 33133]
    private var cachedApplications: [AppRecord] = []
    private var lastCatalogRefreshAt = Date.distantPast

    func suggestedSkillName(for command: String) async -> String? {
        if self.parseFutuCommand(command) != nil {
            return "futu"
        }

        guard let parsed = self.parseAppCommand(command) else {
            return nil
        }

        if parsed.action == .list {
            return "app"
        }

        if self.containsExplicitAppNoun(command) {
            return "app"
        }

        guard let query = parsed.query else {
            return nil
        }

        let matches = self.topMatches(for: query, limit: 2)
        return matches.isEmpty ? nil : "app"
    }

    func handleAppCommand(_ command: String) async -> String {
        guard let parsed = self.parseAppCommand(command) else {
            return """
            我可以直接用 macOS 原生接口处理应用操作。

            你可以这样说：
            • 打开 Safari
            • 启动 FutuOpenD
            • 查看 Cursor 状态
            • 列出应用
            """
        }

        switch parsed.action {
        case .list:
            return await self.listApplications(matching: parsed.query)
        case .launch:
            guard let query = parsed.query else {
                return await self.listApplications(matching: nil)
            }
            return await self.launchApplication(query: query)
        case .quit:
            guard let query = parsed.query else {
                return "请告诉我要退出哪个应用，例如“退出 Safari”。"
            }
            return await self.quitApplication(query: query)
        case .status:
            guard let query = parsed.query else {
                return await self.listRunningApplications()
            }
            return await self.applicationStatus(query: query)
        }
    }

    func handleFutuCommand(_ command: String) async -> String {
        guard let parsed = self.parseFutuCommand(command) else {
            return await self.futuStatus()
        }

        switch parsed.action {
        case .launch:
            return await self.launchFutuOpenD()
        case .quit:
            return await self.quitApplication(query: "FutuOpenD")
        case .status, .list:
            return await self.futuStatus()
        }
    }

    private func parseAppCommand(_ command: String) -> AppCommand? {
        let normalized = command.lowercased()

        guard !self.isLikelyDocumentOrWebRequest(normalized) else {
            return nil
        }

        let launchHints = ["启动", "打开", "运行"]
        let launchEnglishHints = ["launch", "open", "start"]
        let quitHints = ["退出", "关闭"]
        let quitEnglishHints = ["quit", "close", "terminate"]
        let statusHints = ["状态", "在吗", "运行中", "是否启动", "检查", "查看"]
        let statusEnglishHints = ["status", "check"]
        let listHints = ["列出", "全部应用", "应用列表", "运行中的应用", "运行中的程序", "当前应用"]
        let listEnglishHints = ["list"]

        let action: AppAction?
        if self.containsAny(quitHints, in: normalized) || self.containsStandaloneEnglishWord(from: quitEnglishHints, in: normalized) {
            action = .quit
        } else if self.containsAny(launchHints, in: normalized) || self.containsStandaloneEnglishWord(from: launchEnglishHints, in: normalized) {
            action = .launch
        } else if self.containsAny(listHints, in: normalized) || self.containsStandaloneEnglishWord(from: listEnglishHints, in: normalized) {
            action = .list
        } else if self.containsAny(statusHints, in: normalized) || self.containsStandaloneEnglishWord(from: statusEnglishHints, in: normalized) {
            action = .status
        } else {
            action = nil
        }

        guard let action else {
            return nil
        }

        let query = self.extractQuery(from: command, action: action)
        if action == .list {
            guard self.hasExplicitAppListingIntent(command) else {
                return nil
            }
            return AppCommand(action: action, query: query)
        }

        if action == .status, let query, query.isEmpty == false {
            return AppCommand(action: action, query: query)
        }

        if action == .launch || action == .quit {
            return AppCommand(action: action, query: query)
        }

        if self.containsExplicitAppNoun(command) || query != nil {
            return AppCommand(action: action, query: query)
        }

        return nil
    }

    private func parseFutuCommand(_ command: String) -> AppCommand? {
        let normalized = command.lowercased()
        let futuHints = ["futu", "富途", "opend", "open d", "牛牛"]
        guard self.containsAny(futuHints, in: normalized) else {
            return nil
        }

        // 文档/API/能力扩展类请求不应该被误判成“检查 FutuOpenD 状态”
        let nonOperationalHints = [
            "http://", "https://", "网页", "页面", "文档", "docs", "api", "openapi",
            "链接", "url", "读取", "读一下", "分析", "学习", "扩展", "能力",
            "mcp", "接口", "endpoint", "丰富", "搜索"
        ]
        if self.containsAny(nonOperationalHints, in: normalized) {
            return nil
        }

        if normalized.contains("退出") || normalized.contains("关闭") || normalized.contains("quit") {
            return AppCommand(action: .quit, query: "FutuOpenD")
        }
        if normalized.contains("启动") || normalized.contains("打开") || normalized.contains("launch") || normalized.contains("start") {
            return AppCommand(action: .launch, query: "FutuOpenD")
        }
        if normalized.contains("列表") || normalized.contains("list") {
            return AppCommand(action: .list, query: "FutuOpenD")
        }
        if normalized.contains("状态") || normalized.contains("检查") || normalized.contains("查看") || normalized.contains("运行") {
            return AppCommand(action: .status, query: "FutuOpenD")
        }

        // 只有非常短、明显指向 OpenD 本体的请求，才把它当作状态查询兜底。
        let compact = normalized
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let bareFutuQueries = ["futu", "futuopend", "opend", "富途", "牛牛"]
        if bareFutuQueries.contains(compact) {
            return AppCommand(action: .status, query: "FutuOpenD")
        }

        return nil
    }

    private func containsExplicitAppNoun(_ command: String) -> Bool {
        let normalized = command.lowercased()
        if ["应用", "程序", "软件"].contains(where: { normalized.contains($0) }) {
            return true
        }
        return self.containsStandaloneEnglishWord(from: ["app", "application"], in: normalized)
    }

    private func hasExplicitAppListingIntent(_ command: String) -> Bool {
        let normalized = command.lowercased()

        if self.containsExplicitAppNoun(command) {
            return true
        }

        let explicitListingPhrases = [
            "运行中的", "前台应用", "当前应用", "打开了哪些", "哪些应用", "列出应用", "应用列表"
        ]
        if self.containsAny(explicitListingPhrases, in: normalized) {
            return true
        }

        return false
    }

    private func containsAny(_ candidates: [String], in text: String) -> Bool {
        candidates.contains { text.contains($0) }
    }

    private func containsStandaloneEnglishWord(from candidates: [String], in text: String) -> Bool {
        candidates.contains { self.containsStandaloneEnglishWord($0, in: text) }
    }

    private func containsStandaloneEnglishWord(_ candidate: String, in text: String) -> Bool {
        let pattern = "(?i)(?:^|[^a-z0-9])" + NSRegularExpression.escapedPattern(for: candidate) + "(?:$|[^a-z0-9])"
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    private func isLikelyDocumentOrWebRequest(_ text: String) -> Bool {
        if text.contains("http://") || text.contains("https://") || text.contains("www.") {
            return true
        }

        let documentHints = [
            "网页", "页面", "文档", "链接", "读取", "读一下", "分析", "学习", "总结",
            "扩展", "能力", "搜索", "检索", "github", "仓库", "repo", "文章"
        ]
        if self.containsAny(documentHints, in: text) {
            return true
        }

        let webEnglishHints = [
            "api", "openapi", "docs", "doc", "url", "link", "web",
            "browser", "mcp", "endpoint", "github", "repo", "read"
        ]
        return self.containsStandaloneEnglishWord(from: webEnglishHints, in: text)
    }

    private func extractQuery(from command: String, action: AppAction) -> String? {
        var value = command
        let tokens = [
            "/app", "/futu",
            "请帮我", "帮我", "请", "一下", "一下子",
            "打开", "启动", "运行", "退出", "关闭",
            "查看", "检查", "确认", "列出", "显示",
            "status", "check", "launch", "open", "start", "quit", "close", "list",
            "应用程序", "应用", "app", "程序", "软件",
            "mac上", "mac 的", "mac的", "mac", "一下吧"
        ]

        for token in tokens {
            value = value.replacingOccurrences(of: token, with: " ", options: [.caseInsensitive])
        }

        value = value
            .replacingOccurrences(of: "？", with: " ")
            .replacingOccurrences(of: "?", with: " ")
            .replacingOccurrences(of: "。", with: " ")
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: "，", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let compacted = value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")

        if compacted.isEmpty {
            return action == .list ? nil : nil
        }
        return compacted
    }

    private func launchApplication(query: String) async -> String {
        switch self.resolveApplication(query: query) {
        case .none(let suggestions):
            return self.notFoundMessage(for: query, suggestions: suggestions)
        case .ambiguous(let matches):
            return self.ambiguousMatchMessage(for: query, matches: matches)
        case .matched(let app):
            if let snapshot = await self.runningSnapshot(for: app) {
                return """
                ✅ \(app.displayName) 已经在运行
                • PID: \(snapshot.processIdentifier)
                • Bundle ID: \(app.bundleIdentifier ?? "未知")
                """
            }

            do {
                try await self.openApplication(at: app.bundleURL)
            } catch {
                return """
                ❌ 无法启动 \(app.displayName)
                • 原因: \(error.localizedDescription)
                • 路径: \(app.bundleURL.path)
                """
            }

            try? await Task.sleep(nanoseconds: 2_000_000_000)

            if let snapshot = await self.runningSnapshot(for: app) {
                return """
                ✅ 已启动 \(app.displayName)
                • PID: \(snapshot.processIdentifier)
                • Bundle ID: \(app.bundleIdentifier ?? "未知")
                """
            }

            return """
            ⚠️ \(app.displayName) 尝试启动过，但进程没有保持运行
            • 路径: \(app.bundleURL.path)
            • 这通常说明应用自身配置、权限、签名校验或本地依赖有问题

            我不会把这次操作算作“启动成功”。
            """
        }
    }

    private func quitApplication(query: String) async -> String {
        switch self.resolveApplication(query: query) {
        case .none(let suggestions):
            return self.notFoundMessage(for: query, suggestions: suggestions)
        case .ambiguous(let matches):
            return self.ambiguousMatchMessage(for: query, matches: matches)
        case .matched(let app):
            guard let snapshot = await self.runningSnapshot(for: app) else {
                return "ℹ️ \(app.displayName) 当前没有在运行。"
            }

            let requested = await self.requestQuit(for: app)
            guard requested else {
                return """
                ⚠️ 没有成功向 \(app.displayName) 发出退出请求
                • PID: \(snapshot.processIdentifier)
                • 可能是应用拒绝退出，或者当前没有足够权限
                """
            }

            for _ in 0..<15 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if await self.runningSnapshot(for: app) == nil {
                    return "✅ 已退出 \(app.displayName)。"
                }
            }

            return """
            ⚠️ 已请求 \(app.displayName) 退出，但它仍在运行
            • PID: \(snapshot.processIdentifier)
            """
        }
    }

    private func applicationStatus(query: String) async -> String {
        switch self.resolveApplication(query: query) {
        case .none(let suggestions):
            return self.notFoundMessage(for: query, suggestions: suggestions)
        case .ambiguous(let matches):
            return self.ambiguousMatchMessage(for: query, matches: matches)
        case .matched(let app):
            if let snapshot = await self.runningSnapshot(for: app) {
                return """
                ✅ \(app.displayName) 正在运行
                • PID: \(snapshot.processIdentifier)
                • Bundle ID: \(app.bundleIdentifier ?? "未知")
                • 路径: \(app.bundleURL.path)
                """
            }

            return """
            ℹ️ \(app.displayName) 已安装，但当前没有在运行
            • Bundle ID: \(app.bundleIdentifier ?? "未知")
            • 路径: \(app.bundleURL.path)
            """
        }
    }

    private func listApplications(matching query: String?) async -> String {
        let catalog = self.applicationCatalog()

        if let query, !query.isEmpty {
            let matches = self.topMatches(for: query, limit: 12)
            guard !matches.isEmpty else {
                return self.notFoundMessage(for: query, suggestions: [])
            }

            let lines = await self.formatApplicationLines(matches)
            return """
            📱 与“\(query)”最接近的应用
            \(lines.joined(separator: "\n"))
            """
        }

        let running = await self.runningApplications()
            .filter(\.activationPolicyRegular)
            .sorted { $0.localizedName.localizedCaseInsensitiveCompare($1.localizedName) == .orderedAscending }

        if !running.isEmpty {
            let lines = running.prefix(15).map { snapshot in
                "• \(snapshot.localizedName) (PID \(snapshot.processIdentifier))"
            }
            return """
            📱 当前运行中的应用
            \(lines.joined(separator: "\n"))

            如果要启动特定应用，可以直接说“打开 Safari”或“启动 FutuOpenD”。
            """
        }

        let lines = catalog.prefix(15).map { app in
            "• \(app.displayName)"
        }
        return """
        📦 已发现的应用（前 15 个）
        \(lines.joined(separator: "\n"))
        """
    }

    private func listRunningApplications() async -> String {
        let running = await self.runningApplications()
            .filter(\.activationPolicyRegular)
            .sorted { $0.localizedName.localizedCaseInsensitiveCompare($1.localizedName) == .orderedAscending }

        guard !running.isEmpty else {
            return "当前没有检测到前台常规应用在运行。"
        }

        let lines = running.map { snapshot in
            "• \(snapshot.localizedName) (PID \(snapshot.processIdentifier))"
        }
        return """
        📱 当前运行中的应用
        \(lines.joined(separator: "\n"))
        """
    }

    private func futuStatus() async -> String {
        switch self.resolveApplication(query: "FutuOpenD") {
        case .none:
            return "❌ 没有在标准应用目录里发现 FutuOpenD。"
        case .ambiguous(let matches):
            return self.ambiguousMatchMessage(for: "FutuOpenD", matches: matches)
        case .matched(let app):
            let running = await self.runningSnapshot(for: app)
            let ports = await self.reachablePorts(self.openDPorts)

            if let running {
                if ports.count == self.openDPorts.count {
                    return """
                    ✅ FutuOpenD 正在运行且 OpenAPI 端口已就绪
                    • PID: \(running.processIdentifier)
                    • 端口: \(self.formatPorts(ports))
                    """
                }

                return """
                ⚠️ FutuOpenD 进程在运行，但 OpenAPI 端口还没完全就绪
                • PID: \(running.processIdentifier)
                • 已监听端口: \(self.formatPorts(ports))
                • 期望端口: \(self.formatPorts(self.openDPorts))

                这通常表示还需要在 OpenD 窗口里登录、授权或手动启用 OpenAPI。
                """
            }

            return """
            ℹ️ FutuOpenD 已安装，但当前没有在运行
            • 路径: \(app.bundleURL.path)
            """
        }
    }

    private func launchFutuOpenD() async -> String {
        switch self.resolveApplication(query: "FutuOpenD") {
        case .none(let suggestions):
            return self.notFoundMessage(for: "FutuOpenD", suggestions: suggestions)
        case .ambiguous(let matches):
            return self.ambiguousMatchMessage(for: "FutuOpenD", matches: matches)
        case .matched(let app):
            let launchResult = await self.launchApplication(query: app.displayName)
            guard await self.runningSnapshot(for: app) != nil else {
                return launchResult
            }

            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let ports = await self.reachablePorts(self.openDPorts)
            if ports.count == self.openDPorts.count {
                return """
                ✅ FutuOpenD 已启动且 OpenAPI 端口已就绪
                • 端口: \(self.formatPorts(ports))
                """
            }

            return """
            ⚠️ FutuOpenD 进程已启动，但 OpenAPI 端口尚未就绪
            • 已监听端口: \(self.formatPorts(ports))
            • 期望端口: \(self.formatPorts(self.openDPorts))

            我不会把这算成“启动成功”。通常还需要在 OpenD 窗口里完成登录、授权或启用 OpenAPI。
            """
        }
    }

    private func applicationCatalog() -> [AppRecord] {
        if Date().timeIntervalSince(self.lastCatalogRefreshAt) < self.appCatalogTTL,
           !self.cachedApplications.isEmpty {
            return self.cachedApplications
        }

        let fileManager = FileManager.default
        let searchDirectories = [
            "/Applications",
            "/Applications/Utilities",
            "/System/Applications",
            "/System/Applications/Utilities",
            "\(NSHomeDirectory())/Applications",
        ]

        var discovered: [AppRecord] = []
        var seenPaths = Set<String>()

        for directory in searchDirectories {
            let baseURL = URL(fileURLWithPath: directory, isDirectory: true)
            guard fileManager.fileExists(atPath: baseURL.path) else {
                continue
            }

            guard let enumerator = fileManager.enumerator(
                at: baseURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            while let item = enumerator.nextObject() as? URL {
                guard item.pathExtension.lowercased() == "app" else {
                    continue
                }
                enumerator.skipDescendants()

                let path = item.path
                guard seenPaths.insert(path).inserted else {
                    continue
                }

                let bundle = Bundle(url: item)
                let displayName =
                    (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ??
                    (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String) ??
                    item.deletingPathExtension().lastPathComponent
                let bundleIdentifier = bundle?.bundleIdentifier
                let normalizedName = Self.normalize(displayName)
                let aliases = self.aliases(for: displayName, bundleIdentifier: bundleIdentifier)
                discovered.append(
                    AppRecord(
                        displayName: displayName,
                        normalizedName: normalizedName,
                        bundleIdentifier: bundleIdentifier,
                        bundleURL: item,
                        aliases: aliases
                    )
                )
            }
        }

        self.cachedApplications = discovered.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        self.lastCatalogRefreshAt = Date()
        return self.cachedApplications
    }

    private enum AppResolution {
        case matched(AppRecord)
        case ambiguous([AppRecord])
        case none([AppRecord])
    }

    private func resolveApplication(query: String) -> AppResolution {
        let matches = self.topMatches(for: query, limit: 6)
        guard let best = matches.first else {
            return .none([])
        }

        if matches.count > 1 {
            let bestScore = self.score(query: query, record: best)
            let secondScore = self.score(query: query, record: matches[1])
            if bestScore - secondScore <= 5 {
                return .ambiguous(matches)
            }
        }

        if self.score(query: query, record: best) < 45 {
            return .none(matches)
        }

        return .matched(best)
    }

    private func topMatches(for query: String, limit: Int) -> [AppRecord] {
        let catalog = self.applicationCatalog()
        return catalog
            .map { ($0, self.score(query: query, record: $0)) }
            .filter { $0.1 > 0 }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 {
                    return lhs.1 > rhs.1
                }
                return lhs.0.displayName.localizedCaseInsensitiveCompare(rhs.0.displayName) == .orderedAscending
            }
            .prefix(limit)
            .map(\.0)
    }

    private func score(query: String, record: AppRecord) -> Int {
        let normalizedQuery = Self.normalize(query)
        guard !normalizedQuery.isEmpty else {
            return 0
        }

        let normalizedBundleID = Self.normalize(record.bundleIdentifier ?? "")
        let normalizedAliases = record.aliases.map(Self.normalize)
        let candidates = [record.normalizedName, normalizedBundleID] + normalizedAliases

        if candidates.contains(normalizedQuery) {
            return 100
        }
        if candidates.contains(where: { $0.hasPrefix(normalizedQuery) }) {
            return 88
        }
        if candidates.contains(where: { $0.contains(normalizedQuery) }) {
            return 72
        }
        if record.normalizedName.count >= 3, normalizedQuery.contains(record.normalizedName) {
            return 54
        }

        return 0
    }

    private func aliases(for displayName: String, bundleIdentifier: String?) -> [String] {
        let normalizedName = Self.normalize(displayName)
        let normalizedBundleID = Self.normalize(bundleIdentifier ?? "")

        if normalizedName.contains("futu") || normalizedBundleID.contains("futu") {
            return ["富途", "牛牛", "Futu", "OpenD", "FutuOpenD"]
        }
        if normalizedName.contains("chrome") {
            return ["Chrome", "谷歌浏览器", "Google Chrome"]
        }
        if normalizedName.contains("safari") {
            return ["Safari", "浏览器"]
        }
        if normalizedName.contains("visualstudiocode") || normalizedName == "code" {
            return ["Code", "VSCode", "Visual Studio Code", "vscode"]
        }
        if normalizedName.contains("cursor") {
            return ["Cursor"]
        }
        if normalizedName.contains("terminal") {
            return ["Terminal", "终端"]
        }
        if normalizedName.contains("iterm") {
            return ["iTerm", "iTerm2"]
        }
        if normalizedName.contains("wechat") {
            return ["微信", "WeChat"]
        }

        return [displayName]
    }

    private static func normalize(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: ".app", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "应用程序", with: "")
            .replacingOccurrences(of: "应用", with: "")
    }

    private func notFoundMessage(for query: String, suggestions: [AppRecord]) -> String {
        if suggestions.isEmpty {
            return "❌ 没找到和“\(query)”对应的应用。你可以先说“列出应用”或给我更准确的名称。"
        }

        let lines = suggestions.prefix(5).map { "• \($0.displayName)" }
        return """
        ❌ 没找到“\(query)”的精确匹配
        你可能想找：
        \(lines.joined(separator: "\n"))
        """
    }

    private func ambiguousMatchMessage(for query: String, matches: [AppRecord]) -> String {
        let lines = matches.prefix(5).map { "• \($0.displayName)" }
        return """
        ⚠️ “\(query)”对应多个应用
        请指定更准确的名称：
        \(lines.joined(separator: "\n"))
        """
    }

    private func formatPorts(_ ports: [UInt16]) -> String {
        if ports.isEmpty {
            return "无"
        }
        return ports.map(String.init).joined(separator: "/")
    }

    private func formatApplicationLines(_ apps: [AppRecord]) async -> [String] {
        var lines: [String] = []
        for app in apps {
            let suffix: String
            if let running = await self.runningSnapshot(for: app) {
                suffix = " (运行中, PID \(running.processIdentifier))"
            } else {
                suffix = ""
            }
            lines.append("• \(app.displayName)\(suffix)")
        }
        return lines
    }

    private func reachablePorts(_ ports: [UInt16]) async -> [UInt16] {
        var reachable: [UInt16] = []
        for port in ports {
            if await self.isLocalPortReachable(port) {
                reachable.append(port)
            }
        }
        return reachable
    }

    private func isLocalPortReachable(_ port: UInt16) async -> Bool {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            return false
        }

        return await withCheckedContinuation { continuation in
            let connection = NWConnection(host: "127.0.0.1", port: endpointPort, using: .tcp)
            let queue = DispatchQueue(label: "MacSystemAgent.PortCheck.\(port)")
            let state = PortCheckState()

            let finish: @Sendable (Bool) -> Void = { result in
                guard !state.finished else { return }
                state.finished = true
                connection.cancel()
                continuation.resume(returning: result)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(true)
                case .failed:
                    finish(false)
                default:
                    break
                }
            }

            queue.asyncAfter(deadline: .now() + 0.6) {
                finish(false)
            }

            connection.start(queue: queue)
        }
    }

    private func runningApplications() async -> [RunningAppSnapshot] {
        await MainActor.run {
            NSWorkspace.shared.runningApplications.map { app in
                RunningAppSnapshot(
                    bundleIdentifier: app.bundleIdentifier,
                    localizedName: app.localizedName ?? "Unknown",
                    processIdentifier: app.processIdentifier,
                    activationPolicyRegular: app.activationPolicy == .regular
                )
            }
        }
    }

    private func runningSnapshot(for app: AppRecord) async -> RunningAppSnapshot? {
        let snapshots = await self.runningApplications()
        return snapshots.first { snapshot in
            if let bundleIdentifier = app.bundleIdentifier,
               snapshot.bundleIdentifier == bundleIdentifier {
                return true
            }
            return Self.normalize(snapshot.localizedName) == app.normalizedName
        }
    }

    @MainActor
    private func openApplication(at url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true

            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: ())
            }
        }
    }

    @MainActor
    private func requestQuit(for app: AppRecord) -> Bool {
        guard let runningApp = NSWorkspace.shared.runningApplications.first(where: { running in
            if let bundleIdentifier = app.bundleIdentifier,
               running.bundleIdentifier == bundleIdentifier {
                return true
            }
            return Self.normalize(running.localizedName ?? "") == app.normalizedName
        }) else {
            return false
        }

        return runningApp.terminate()
    }
}
