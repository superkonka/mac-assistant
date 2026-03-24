//
//  DesktopAppLauncher.swift
//  MacAssistant
//
//  通用桌面App启动器 - 让AI智能体能够智能地使用Mac应用
//

import Foundation
import AppKit

// MARK: - 桌面应用信息
struct DesktopAppInfo: Identifiable, Codable {
    let id: String                    // bundle ID 或应用名
    let name: String                  // 显示名称
    let bundleIdentifier: String?     // 如 com.apple.Safari
    let appPath: String?              // 完整路径
    let executablePath: String?       // 可执行文件路径
    let isBuiltin: Bool               // 是否为系统应用
    let category: AppCategory
    let supportedActions: [AppAction]
    
    enum AppCategory: String, Codable, CaseIterable {
        case browser = "browser"           // 浏览器
        case editor = "editor"             // 编辑器
        case terminal = "terminal"         // 终端
        case communication = "communication" // 通讯
        case media = "media"               // 媒体
        case productivity = "productivity" // 生产力
        case development = "development"   // 开发
        case system = "system"             // 系统
        case other = "other"               // 其他
        
        var displayName: String {
            switch self {
            case .browser: return "浏览器"
            case .editor: return "编辑器"
            case .terminal: return "终端"
            case .communication: return "通讯"
            case .media: return "媒体"
            case .productivity: return "生产力"
            case .development: return "开发"
            case .system: return "系统"
            case .other: return "其他"
            }
        }
    }
    
    enum AppAction: String, Codable, CaseIterable {
        case open = "open"                 // 打开应用
        case quit = "quit"                 // 退出应用
        case activate = "activate"         // 激活窗口
        case openURL = "openURL"           // 打开URL
        case openFile = "openFile"         // 打开文件
        case newWindow = "newWindow"       // 新建窗口
        case newTab = "newTab"             // 新建标签页
        
        var displayName: String {
            switch self {
            case .open: return "打开"
            case .quit: return "退出"
            case .activate: return "激活"
            case .openURL: return "打开链接"
            case .openFile: return "打开文件"
            case .newWindow: return "新建窗口"
            case .newTab: return "新建标签"
            }
        }
    }
}

// MARK: - 应用启动结果
enum AppLaunchResult {
    case success(pid: Int)
    case alreadyRunning(pid: Int)
    case notFound
    case permissionDenied
    case failed(error: String)
    
    var isSuccess: Bool {
        switch self {
        case .success, .alreadyRunning:
            return true
        default:
            return false
        }
    }
}

// MARK: - 桌面应用启动器
@MainActor
final class DesktopAppLauncher: ObservableObject {
    static let shared = DesktopAppLauncher()
    
    // MARK: - Published
    @Published var installedApps: [DesktopAppInfo] = []
    @Published var runningApps: [NSRunningApplication] = []
    @Published var recentLaunches: [LaunchRecord] = []
    
    // MARK: - Private
    private var scanTimer: Timer?
    private let recentLaunchesLimit = 20
    
    struct LaunchRecord: Identifiable {
        let id = UUID()
        let timestamp: Date
        let appName: String
        let action: String
        let result: String
    }
    
    private init() {
        scanInstalledApps()
        startMonitoring()
    }
    
    // MARK: - 扫描已安装应用
    func scanInstalledApps() {
        var apps: [DesktopAppInfo] = []
        
        // 1. 扫描 /Applications
        apps.append(contentsOf: scanAppsInDirectory("/Applications"))
        
        // 2. 扫描 ~/Applications
        apps.append(contentsOf: scanAppsInDirectory(NSHomeDirectory() + "/Applications"))
        
        // 3. 扫描系统应用
        apps.append(contentsOf: scanAppsInDirectory("/System/Applications"))
        apps.append(contentsOf: scanAppsInDirectory("/System/Library/CoreServices"))
        
        // 4. 添加常用内置应用（确保始终可用）
        apps.append(contentsOf: builtinApps())
        
        // 去重并按名称排序
        var uniqueApps: [String: DesktopAppInfo] = [:]
        for app in apps {
            uniqueApps[app.id] = app
        }
        
        installedApps = uniqueApps.values.sorted { $0.name < $1.name }
        
        LogInfo("[DesktopAppLauncher] 扫描到 \(installedApps.count) 个应用")
    }
    
    private func scanAppsInDirectory(_ path: String) -> [DesktopAppInfo] {
        let fileManager = FileManager.default
        var apps: [DesktopAppInfo] = []
        
        guard let contents = try? fileManager.contentsOfDirectory(atPath: path) else {
            return []
        }
        
        for item in contents where item.hasSuffix(".app") {
            let fullPath = "\(path)/\(item)"
            if let appInfo = parseAppBundle(fullPath) {
                apps.append(appInfo)
            }
        }
        
        return apps
    }
    
    private func parseAppBundle(_ path: String) -> DesktopAppInfo? {
        let infoPlistPath = "\(path)/Contents/Info.plist"
        let fileManager = FileManager.default
        
        guard fileManager.fileExists(atPath: infoPlistPath),
              let plist = NSDictionary(contentsOfFile: infoPlistPath) else {
            return nil
        }
        
        let bundleID = plist["CFBundleIdentifier"] as? String
        let displayName = plist["CFBundleDisplayName"] as? String
        let bundleName = plist["CFBundleName"] as? String
        let executable = plist["CFBundleExecutable"] as? String
        
        let name = displayName ?? bundleName ?? (path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
        
        let executablePath = executable.map { "\(path)/Contents/MacOS/\($0)" }
        
        return DesktopAppInfo(
            id: bundleID ?? name,
            name: name,
            bundleIdentifier: bundleID,
            appPath: path,
            executablePath: executablePath,
            isBuiltin: false,
            category: guessCategory(name, bundleID: bundleID),
            supportedActions: guessSupportedActions(name)
        )
    }
    
    private func builtinApps() -> [DesktopAppInfo] {
        [
            DesktopAppInfo(
                id: "com.apple.Safari",
                name: "Safari",
                bundleIdentifier: "com.apple.Safari",
                appPath: "/Applications/Safari.app",
                executablePath: nil,
                isBuiltin: true,
                category: .browser,
                supportedActions: [.open, .quit, .activate, .openURL, .newWindow, .newTab]
            ),
            DesktopAppInfo(
                id: "com.apple.Terminal",
                name: "Terminal",
                bundleIdentifier: "com.apple.Terminal",
                appPath: "/System/Applications/Utilities/Terminal.app",
                executablePath: nil,
                isBuiltin: true,
                category: .terminal,
                supportedActions: [.open, .quit, .activate, .newWindow]
            ),
            DesktopAppInfo(
                id: "com.apple.TextEdit",
                name: "文本编辑",
                bundleIdentifier: "com.apple.TextEdit",
                appPath: "/System/Applications/TextEdit.app",
                executablePath: nil,
                isBuiltin: true,
                category: .editor,
                supportedActions: [.open, .quit, .activate, .openFile, .newWindow]
            ),
            DesktopAppInfo(
                id: "com.apple.Preview",
                name: "预览",
                bundleIdentifier: "com.apple.Preview",
                appPath: "/System/Applications/Preview.app",
                executablePath: nil,
                isBuiltin: true,
                category: .productivity,
                supportedActions: [.open, .quit, .activate, .openFile]
            ),
            DesktopAppInfo(
                id: "com.apple.finder",
                name: "Finder",
                bundleIdentifier: "com.apple.finder",
                appPath: "/System/Library/CoreServices/Finder.app",
                executablePath: nil,
                isBuiltin: true,
                category: .system,
                supportedActions: [.activate, .openFile]
            ),
            DesktopAppInfo(
                id: "com.apple.systempreferences",
                name: "系统设置",
                bundleIdentifier: "com.apple.systempreferences",
                appPath: "/System/Applications/System Settings.app",
                executablePath: nil,
                isBuiltin: true,
                category: .system,
                supportedActions: [.open, .quit, .activate]
            ),
            DesktopAppInfo(
                id: "com.apple.Notes",
                name: "备忘录",
                bundleIdentifier: "com.apple.Notes",
                appPath: "/System/Applications/Notes.app",
                executablePath: nil,
                isBuiltin: true,
                category: .productivity,
                supportedActions: [.open, .quit, .activate, .newWindow]
            ),
            DesktopAppInfo(
                id: "com.apple.mail",
                name: "邮件",
                bundleIdentifier: "com.apple.mail",
                appPath: "/System/Applications/Mail.app",
                executablePath: nil,
                isBuiltin: true,
                category: .communication,
                supportedActions: [.open, .quit, .activate, .newWindow]
            )
        ]
    }
    
    private func guessCategory(_ name: String, bundleID: String?) -> DesktopAppInfo.AppCategory {
        let lowercased = name.lowercased()
        let bundleLower = bundleID?.lowercased() ?? ""
        
        if lowercased.contains("safari") || lowercased.contains("chrome") || 
           lowercased.contains("firefox") || bundleLower.contains("browser") {
            return .browser
        } else if lowercased.contains("terminal") || lowercased.contains("iterm") ||
                  lowercased.contains("warp") || bundleLower.contains("terminal") {
            return .terminal
        } else if lowercased.contains("code") || lowercased.contains("xcode") ||
                  bundleLower.contains("developer") {
            return .development
        } else if lowercased.contains("wechat") || lowercased.contains("slack") ||
                  lowercased.contains("telegram") || bundleLower.contains("communication") {
            return .communication
        } else if lowercased.contains("preview") || lowercased.contains("photo") ||
                  lowercased.contains("video") {
            return .media
        } else if lowercased.contains("notes") || lowercased.contains("calendar") ||
                  lowercased.contains("reminder") {
            return .productivity
        }
        
        return .other
    }
    
    private func guessSupportedActions(_ name: String) -> [DesktopAppInfo.AppAction] {
        var actions: [DesktopAppInfo.AppAction] = [.open, .quit, .activate]
        
        let lowercased = name.lowercased()
        if lowercased.contains("safari") || lowercased.contains("chrome") {
            actions.append(contentsOf: [.openURL, .newWindow, .newTab])
        } else if lowercased.contains("terminal") || lowercased.contains("textedit") {
            actions.append(contentsOf: [.newWindow])
        }
        
        return actions
    }
    
    // MARK: - 启动监控
    private func startMonitoring() {
        // 每5秒更新一次运行中的应用列表
        scanTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateRunningApps()
            }
        }
        updateRunningApps()
    }
    
    private func updateRunningApps() {
        runningApps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
    }
    
    // MARK: - 应用操作
    
    /// 启动应用（通用方法）
    func launchApp(_ appInfo: DesktopAppInfo, options: LaunchOptions = .default) async -> AppLaunchResult {
        LogInfo("[DesktopAppLauncher] 启动应用: \(appInfo.name)")
        
        // 1. 检查是否已经在运行
        if let running = findRunningApp(appInfo) {
            if options.activateIfRunning {
                running.activate(options: .activateIgnoringOtherApps)
                recordLaunch(appInfo.name, action: "激活", result: "成功")
                return .alreadyRunning(pid: Int(running.processIdentifier))
            }
        }
        
        // 2. 获取应用URL
        guard let appURL = getAppURL(appInfo) else {
            recordLaunch(appInfo.name, action: "启动", result: "失败：找不到应用")
            return .notFound
        }
        
        // 3. 尝试启动
        do {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = options.activate
            configuration.createsNewApplicationInstance = options.newInstance
            
            let runningApp = try await NSWorkspace.shared.openApplication(
                at: appURL,
                configuration: configuration
            )
            
            let pid = runningApp.processIdentifier
            recordLaunch(appInfo.name, action: "启动", result: "成功")
            return .success(pid: Int(pid))
            
        } catch {
            // 4. 如果标准启动失败，尝试命令行方式
            return await launchViaCommandLine(appInfo, options: options)
        }
    }
    
    /// 通过命令行启动（用于特殊应用如 FutuOpenD）
    private func launchViaCommandLine(_ appInfo: DesktopAppInfo, options: LaunchOptions) async -> AppLaunchResult {
        LogInfo("[DesktopAppLauncher] 尝试命令行启动: \(appInfo.name)")
        
        // 获取可执行文件路径
        let executablePath: String?
        if let explicitPath = appInfo.executablePath {
            executablePath = explicitPath
        } else if let appPath = appInfo.appPath {
            executablePath = findExecutable(in: appPath)
        } else {
            executablePath = nil
        }
        
        guard let exePath = executablePath,
              FileManager.default.fileExists(atPath: exePath) else {
            recordLaunch(appInfo.name, action: "启动", result: "失败：找不到可执行文件")
            return .notFound
        }
        
        // 使用 open 命令启动
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = options.newInstance ? ["-n", exePath] : [exePath]
        
        return await withCheckedContinuation { continuation in
            task.terminationHandler = { process in
                if process.terminationStatus == 0 {
                    // 启动成功，等待一下获取PID
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        Task { @MainActor in
                            if let running = self.findRunningApp(appInfo) {
                                self.recordLaunch(appInfo.name, action: "启动(命令行)", result: "成功")
                                continuation.resume(returning: .success(pid: Int(running.processIdentifier)))
                            } else {
                                self.recordLaunch(appInfo.name, action: "启动(命令行)", result: "成功(无法获取PID)")
                                continuation.resume(returning: .success(pid: -1))
                            }
                        }
                    }
                } else {
                    Task { @MainActor in
                        self.recordLaunch(appInfo.name, action: "启动(命令行)", result: "失败：退出码 \(process.terminationStatus)")
                    }
                    continuation.resume(returning: .failed(error: "进程退出码: \(process.terminationStatus)"))
                }
            }
            
            do {
                try task.run()
            } catch {
                Task { @MainActor in
                    self.recordLaunch(appInfo.name, action: "启动", result: "失败：\(error.localizedDescription)")
                }
                continuation.resume(returning: .failed(error: error.localizedDescription))
            }
        }
    }
    
    /// 退出应用
    func quitApp(_ appInfo: DesktopAppInfo, force: Bool = false) async -> Bool {
        guard let running = findRunningApp(appInfo) else {
            return true // 已经退出
        }
        
        if force {
            running.forceTerminate()
        } else {
            running.terminate()
        }
        
        // 等待退出
        for _ in 0..<10 {
            if findRunningApp(appInfo) == nil {
                recordLaunch(appInfo.name, action: "退出", result: "成功")
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1秒
        }
        
        recordLaunch(appInfo.name, action: "退出", result: force ? "强制退出" : "优雅退出失败")
        return !running.isTerminated
    }
    
    /// 激活应用窗口
    func activateApp(_ appInfo: DesktopAppInfo) -> Bool {
        guard let running = findRunningApp(appInfo) else {
            return false
        }
        
        let result = running.activate(options: .activateIgnoringOtherApps)
        recordLaunch(appInfo.name, action: "激活", result: result ? "成功" : "失败")
        return result
    }
    
    /// 用应用打开URL（浏览器）
    func openURL(_ urlString: String, with appInfo: DesktopAppInfo? = nil) async -> Bool {
        guard let url = URL(string: urlString), url.scheme != nil else {
            return false
        }
        
        do {
            if let app = appInfo, let appURL = getAppURL(app) {
                // 使用指定应用打开
                _ = try await NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
            } else {
                // 使用默认应用
                NSWorkspace.shared.open(url)
            }
            return true
        } catch {
            return false
        }
    }
    
    /// 用应用打开文件
    func openFile(_ filePath: String, with appInfo: DesktopAppInfo? = nil) async -> Bool {
        let expandedPath = filePath.replacingOccurrences(of: "~", with: NSHomeDirectory())
        let url = URL(fileURLWithPath: expandedPath)
        
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            return false
        }
        
        do {
            if let app = appInfo, let appURL = getAppURL(app) {
                _ = try await NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
            } else {
                NSWorkspace.shared.open(url)
            }
            return true
        } catch {
            return false
        }
        
        return true
    }
    
    // MARK: - 辅助方法
    
    private func getAppURL(_ appInfo: DesktopAppInfo) -> URL? {
        if let path = appInfo.appPath {
            return URL(fileURLWithPath: path)
        }
        
        // 通过 bundle ID 查找
        if let bundleID = appInfo.bundleIdentifier,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url
        }
        
        return nil
    }
    
    private func findRunningApp(_ appInfo: DesktopAppInfo) -> NSRunningApplication? {
        // 通过 bundle ID 查找
        if let bundleID = appInfo.bundleIdentifier {
            return runningApps.first { $0.bundleIdentifier == bundleID }
        }
        
        // 通过名称查找
        return runningApps.first { $0.localizedName == appInfo.name }
    }
    
    private func findExecutable(in appPath: String) -> String? {
        let infoPlistPath = "\(appPath)/Contents/Info.plist"
        guard let plist = NSDictionary(contentsOfFile: infoPlistPath),
              let executable = plist["CFBundleExecutable"] as? String else {
            return nil
        }
        
        let fullPath = "\(appPath)/Contents/MacOS/\(executable)"
        return FileManager.default.fileExists(atPath: fullPath) ? fullPath : nil
    }
    
    private func recordLaunch(_ appName: String, action: String, result: String) {
        let record = LaunchRecord(
            timestamp: Date(),
            appName: appName,
            action: action,
            result: result
        )
        
        recentLaunches.insert(record, at: 0)
        if recentLaunches.count > recentLaunchesLimit {
            recentLaunches = Array(recentLaunches.prefix(recentLaunchesLimit))
        }
    }
    
    /// 根据名称查找应用
    func findApp(byName name: String) -> DesktopAppInfo? {
        let lowercased = name.lowercased()
        
        // 精确匹配
        if let exact = installedApps.first(where: { $0.name.lowercased() == lowercased }) {
            return exact
        }
        
        // 包含匹配
        return installedApps.first { $0.name.lowercased().contains(lowercased) }
    }
    
    /// 根据bundle ID查找应用
    func findApp(byBundleID bundleID: String) -> DesktopAppInfo? {
        installedApps.first { $0.bundleIdentifier == bundleID }
    }
}

// MARK: - 启动选项
struct LaunchOptions {
    var activate: Bool = true
    var activateIfRunning: Bool = true
    var newInstance: Bool = false
    
    static let `default` = LaunchOptions()
    static let background = LaunchOptions(activate: false, activateIfRunning: false)
    static let newWindow = LaunchOptions(newInstance: true)
}

// MARK: - 扩展
extension DesktopAppLauncher {
    /// 获取某类别的所有应用
    func apps(in category: DesktopAppInfo.AppCategory) -> [DesktopAppInfo] {
        installedApps.filter { $0.category == category }
    }
    
    /// 获取所有浏览器
    var browsers: [DesktopAppInfo] {
        apps(in: .browser)
    }
    
    /// 获取所有终端
    var terminals: [DesktopAppInfo] {
        apps(in: .terminal)
    }
    
    /// 检查应用是否正在运行
    func isRunning(_ appInfo: DesktopAppInfo) -> Bool {
        findRunningApp(appInfo) != nil
    }
}
