//
//  DependencyManager.swift
//  MacAssistant
//
//  管理 OpenClaw 运行时的检测、安装和自动配置
//

import AppKit
import Foundation

/// 依赖状态
enum DependencyStatus: Equatable {
    case notInstalled
    case bundledAvailable
    case installing
    case installed(path: String)
    case error(String)
}

enum OpenClawBinarySource: Equatable {
    case managedInstall
    case legacyInstall
    case systemPath
    case bundledOnly
    case missing

    var displayName: String {
        switch self {
        case .managedInstall:
            return "应用运行时"
        case .legacyInstall:
            return "~/.local/bin"
        case .systemPath:
            return "系统 PATH"
        case .bundledOnly:
            return "App Bundle"
        case .missing:
            return "未找到"
        }
    }
}

struct OpenClawBinaryInspection: Equatable {
    let source: OpenClawBinarySource
    let executablePath: String?
    let version: String?
    let issue: String?
    let bundledPath: String?
    let bundledVersion: String?
    let bundledIssue: String?
    let managedInstallPath: String
    let legacyInstallPath: String
    let systemPath: String?

    var canInstallFromBundle: Bool {
        bundledPath != nil && bundledIssue == nil
    }

    var isUsable: Bool {
        executablePath != nil && issue == nil
    }

    var isPreferredSource: Bool {
        source == .managedInstall
    }

    var isExternalSource: Bool {
        source == .legacyInstall || source == .systemPath
    }
}

private struct OpenClawCandidateInspection {
    let source: OpenClawBinarySource
    let path: String
    let version: String?
    let issue: String?

    var isUsable: Bool {
        issue == nil
    }
}

/// 依赖管理器 - 确保 OpenClaw CLI 可用
@MainActor
class DependencyManager: ObservableObject {
    static let shared = DependencyManager()

    @Published private(set) var openclawStatus: DependencyStatus = .notInstalled
    @Published private(set) var isInstalling: Bool = false

    private let bundledRuntimeDirectoryName = "openclaw-runtime"
    private let bundledExecutableRelativePath = "bin/openclaw"
    private let managedRuntimeRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MacAssistant/runtime/openclaw", isDirectory: true)
    private let managedBinDir: URL
    private let managedNodeBinDir: URL
    private let legacyInstallDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/bin", isDirectory: true)
    private let managedInstallPath: String
    private let legacyInstallPath: String

    private init() {
        self.managedBinDir = managedRuntimeRoot.appendingPathComponent("bin", isDirectory: true)
        self.managedNodeBinDir = managedRuntimeRoot
            .appendingPathComponent("tools/node/bin", isDirectory: true)
        self.managedInstallPath = managedBinDir.appendingPathComponent("openclaw").path
        self.legacyInstallPath = legacyInstallDir.appendingPathComponent("openclaw").path
    }

    // MARK: - 公共接口

    /// 检查并确保 OpenClaw 可用
    /// - Returns: OpenClaw 可执行文件的完整路径
    /// - Throws: 如果无法安装或找到 OpenClaw
    func ensureOpenClawAvailable() async throws -> String {
        if let managed = await inspectCandidate(at: managedInstallPath, source: .managedInstall),
           managed.isUsable {
            LogInfo("✅ 使用应用运行时 OpenClaw: \(managed.path)")
            self.openclawStatus = .installed(path: managed.path)
            return managed.path
        }

        var bundleInstallError: Error?
        if let bundledCandidate = await inspectBundledCandidate() {
            self.openclawStatus = .bundledAvailable
            if bundledCandidate.isUsable {
                do {
                    return try await installFromBundle()
                } catch {
                    bundleInstallError = error
                    LogError("安装 bundle 内 OpenClaw runtime 失败，尝试外部回退", error: error)
                }
            } else {
                let reason = bundledCandidate.issue ?? "无法验证 bundle 内 OpenClaw runtime"
                bundleInstallError = DependencyError.installFailed("App Bundle 内置 OpenClaw runtime 不可用: \(reason)")
                LogError("bundle 内 OpenClaw runtime 不可用，尝试外部回退: \(reason)")
            }
        }

        if let legacy = await inspectCandidate(at: legacyInstallPath, source: .legacyInstall),
           legacy.isUsable {
            LogInfo("✅ 使用兼容路径 OpenClaw: \(legacy.path)")
            self.openclawStatus = .installed(path: legacy.path)
            return legacy.path
        }

        if let systemPath = await findSystemOpenClaw(),
           let system = await inspectCandidate(at: systemPath, source: .systemPath),
           system.isUsable {
            LogInfo("✅ 使用系统 OpenClaw: \(system.path)")
            self.openclawStatus = .installed(path: system.path)
            return system.path
        }

        let errorMessage: String
        if let bundleInstallError {
            errorMessage = bundleInstallError.localizedDescription
        } else if bundledRuntimeRootURL() == nil {
            errorMessage = "OpenClaw runtime 未打包在 App Bundle 中"
        } else {
            errorMessage = "找不到可用的 OpenClaw 可执行文件"
        }

        self.openclawStatus = .error(errorMessage)

        if bundleInstallError != nil {
            throw DependencyError.installFailed(errorMessage)
        }
        throw DependencyError.bundledNotFound
    }

    func inspectOpenClawInstallation() async -> OpenClawBinaryInspection {
        let bundledCandidate = await inspectBundledCandidate()
        let bundledPath = bundledCandidate?.path
        let systemPath = await findSystemOpenClaw()
        let managed = await inspectCandidate(at: managedInstallPath, source: .managedInstall)

        if let managed, managed.isUsable {
            return OpenClawBinaryInspection(
                source: managed.source,
                executablePath: managed.path,
                version: managed.version,
                issue: nil,
                bundledPath: bundledPath,
                bundledVersion: bundledCandidate?.version,
                bundledIssue: bundledCandidate?.issue,
                managedInstallPath: managedInstallPath,
                legacyInstallPath: legacyInstallPath,
                systemPath: systemPath
            )
        }

        if let legacy = await inspectCandidate(at: legacyInstallPath, source: .legacyInstall),
           legacy.isUsable {
            return OpenClawBinaryInspection(
                source: legacy.source,
                executablePath: legacy.path,
                version: legacy.version,
                issue: nil,
                bundledPath: bundledPath,
                bundledVersion: bundledCandidate?.version,
                bundledIssue: bundledCandidate?.issue,
                managedInstallPath: managedInstallPath,
                legacyInstallPath: legacyInstallPath,
                systemPath: systemPath
            )
        }

        if let systemPath,
           let system = await inspectCandidate(at: systemPath, source: .systemPath),
           system.isUsable {
            return OpenClawBinaryInspection(
                source: system.source,
                executablePath: system.path,
                version: system.version,
                issue: nil,
                bundledPath: bundledPath,
                bundledVersion: bundledCandidate?.version,
                bundledIssue: bundledCandidate?.issue,
                managedInstallPath: managedInstallPath,
                legacyInstallPath: legacyInstallPath,
                systemPath: systemPath
            )
        }

        if let managed {
            return OpenClawBinaryInspection(
                source: managed.source,
                executablePath: nil,
                version: managed.version,
                issue: managed.issue,
                bundledPath: bundledPath,
                bundledVersion: bundledCandidate?.version,
                bundledIssue: bundledCandidate?.issue,
                managedInstallPath: managedInstallPath,
                legacyInstallPath: legacyInstallPath,
                systemPath: systemPath
            )
        }

        if let bundledCandidate {
            return OpenClawBinaryInspection(
                source: .bundledOnly,
                executablePath: nil,
                version: nil,
                issue: nil,
                bundledPath: bundledCandidate.path,
                bundledVersion: bundledCandidate.version,
                bundledIssue: bundledCandidate.issue,
                managedInstallPath: managedInstallPath,
                legacyInstallPath: legacyInstallPath,
                systemPath: systemPath
            )
        }

        return OpenClawBinaryInspection(
            source: .missing,
            executablePath: nil,
            version: nil,
            issue: "App Bundle 中没有可用的 OpenClaw runtime。",
            bundledPath: nil,
            bundledVersion: nil,
            bundledIssue: "App Bundle 中没有可用的 OpenClaw runtime。",
            managedInstallPath: managedInstallPath,
            legacyInstallPath: legacyInstallPath,
            systemPath: systemPath
        )
    }

    func reinstallManagedOpenClaw() async throws -> String {
        guard await inspectBundledCandidate() != nil else {
            self.openclawStatus = .error("OpenClaw runtime 未打包在 App Bundle 中")
            throw DependencyError.bundledNotFound
        }

        if FileManager.default.fileExists(atPath: managedRuntimeRoot.path) {
            try? FileManager.default.removeItem(at: managedRuntimeRoot)
        }

        return try await installFromBundle()
    }

    /// 检查是否需要首次设置
    var needsFirstTimeSetup: Bool {
        get async {
            let agentStore = AgentStore.shared
            return agentStore.usableAgents.isEmpty
        }
    }

    /// 获取安装进度状态
    var currentStatus: DependencyStatus {
        openclawStatus
    }

    var managedRuntimeExecutablePath: String {
        managedInstallPath
    }

    // MARK: - 私有方法

    /// 在系统 PATH 中查找 openclaw
    private func findSystemOpenClaw() async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["openclaw"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                return nil
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)

            guard let validPath = path, !validPath.isEmpty else {
                return nil
            }

            if FileManager.default.isExecutableFile(atPath: validPath) {
                return validPath
            }
            return nil
        } catch {
            return nil
        }
    }

    private func bundledRuntimeRootURL() -> URL? {
        guard let resourceURL = Bundle.main.resourceURL else {
            return nil
        }

        let candidate = resourceURL.appendingPathComponent(bundledRuntimeDirectoryName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            return nil
        }
        return candidate
    }

    /// 获取 Bundle 中的 openclaw 路径
    private func bundledOpenClawPath() -> String? {
        guard let bundledRuntimeRootURL = bundledRuntimeRootURL() else {
            return nil
        }

        return bundledRuntimeRootURL
            .appendingPathComponent(bundledExecutableRelativePath)
            .path
    }

    private func inspectBundledCandidate() async -> OpenClawCandidateInspection? {
        guard let bundledRuntimeRootURL = bundledRuntimeRootURL() else {
            return nil
        }

        let bundledPath = bundledRuntimeRootURL
            .appendingPathComponent(bundledExecutableRelativePath)
            .path

        if let inspection = await inspectCandidate(at: bundledPath, source: .bundledOnly) {
            return inspection
        }

        return OpenClawCandidateInspection(
            source: .bundledOnly,
            path: bundledPath,
            version: nil,
            issue: "App Bundle 中的 openclaw-runtime 缺少 bin/openclaw。"
        )
    }

    /// 从 Bundle 安装到应用管理目录
    private func installFromBundle() async throws -> String {
        self.isInstalling = true
        self.openclawStatus = .installing

        defer {
            self.isInstalling = false
        }

        LogInfo("📦 正在安装 OpenClaw runtime...")

        guard let bundledRuntimeRootURL = bundledRuntimeRootURL() else {
            throw DependencyError.bundledNotFound
        }

        do {
            let fileManager = FileManager.default
            let runtimeParent = managedRuntimeRoot.deletingLastPathComponent()

            try fileManager.createDirectory(
                at: runtimeParent,
                withIntermediateDirectories: true,
                attributes: nil
            )

            if fileManager.fileExists(atPath: managedRuntimeRoot.path) {
                try fileManager.removeItem(at: managedRuntimeRoot)
            }

            try fileManager.copyItem(at: bundledRuntimeRootURL, to: managedRuntimeRoot)

            if fileManager.fileExists(atPath: managedInstallPath) {
                try fileManager.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: managedInstallPath
                )
            }

            let managedNodePath = managedNodeBinDir.appendingPathComponent("node").path
            if fileManager.fileExists(atPath: managedNodePath) {
                try fileManager.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: managedNodePath
                )
            }

            guard fileManager.isExecutableFile(atPath: managedInstallPath) else {
                throw DependencyError.installFailed("openclaw-runtime/bin/openclaw 不可执行")
            }

            let version = try await verifyOpenClaw(at: managedInstallPath)
            LogInfo("✅ OpenClaw runtime 安装成功: v\(version)")

            self.openclawStatus = .installed(path: managedInstallPath)
            return managedInstallPath

        } catch {
            LogError("OpenClaw runtime 安装失败", error: error)
            self.openclawStatus = .error(error.localizedDescription)
            throw DependencyError.installFailed(error.localizedDescription)
        }
    }

    private func inspectCandidate(at path: String, source: OpenClawBinarySource) async -> OpenClawCandidateInspection? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path) else {
            return nil
        }

        guard fileManager.isExecutableFile(atPath: path) else {
            return OpenClawCandidateInspection(
                source: source,
                path: path,
                version: nil,
                issue: "文件存在但不可执行"
            )
        }

        do {
            let version = try await verifyOpenClaw(at: path)
            return OpenClawCandidateInspection(
                source: source,
                path: path,
                version: version,
                issue: nil
            )
        } catch {
            return OpenClawCandidateInspection(
                source: source,
                path: path,
                version: nil,
                issue: error.localizedDescription
            )
        }
    }

    /// 验证 OpenClaw 可执行文件
    private func verifyOpenClaw(at path: String) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw DependencyError.verificationFailed
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
    }

    /// 获取 PATH 环境变量（包含我们的安装目录）
    func pathEnvironment() -> String {
        let managedBin = managedBinDir.path
        let managedNodeBin = managedNodeBinDir.path
        let legacyBin = legacyInstallDir.path
        let defaultPath = "\(managedBin):\(managedNodeBin):\(legacyBin):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        return ProcessInfo.processInfo.environment["PATH"].map { "\($0):\(defaultPath)" } ?? defaultPath
    }
}

// MARK: - 错误类型

enum DependencyError: LocalizedError {
    case bundledNotFound
    case installFailed(String)
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .bundledNotFound:
            return "OpenClaw runtime 未包含在应用中，请重新下载应用或联系支持。"
        case .installFailed(let reason):
            return "安装 OpenClaw runtime 失败: \(reason)"
        case .verificationFailed:
            return "无法验证 OpenClaw runtime，文件可能损坏。"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .bundledNotFound:
            return "请从官方网站重新下载 Mac Assistant。"
        case .installFailed:
            return "请检查磁盘空间权限，或尝试重启应用。"
        case .verificationFailed:
            return "请尝试在应用内执行 OpenClaw 重装。"
        }
    }
}
