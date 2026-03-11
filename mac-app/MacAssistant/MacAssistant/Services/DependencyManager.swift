//
//  DependencyManager.swift
//  MacAssistant
//
//  管理外部依赖（OpenClaw CLI）的检测、安装和自动配置
//

import Foundation
import AppKit

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
    let managedInstallPath: String
    let legacyInstallPath: String
    let systemPath: String?

    var canInstallFromBundle: Bool {
        bundledPath != nil
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

    private let bundledOpenClawName = "openclaw"
    private let managedInstallDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MacAssistant/runtime/bin", isDirectory: true)
    private let legacyInstallDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/bin", isDirectory: true)
    private let managedInstallPath: String
    private let legacyInstallPath: String

    private init() {
        self.managedInstallPath = managedInstallDir.appendingPathComponent("openclaw").path
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
        if let bundledPath = bundledOpenClawPath() {
            self.openclawStatus = .bundledAvailable
            do {
                return try await installFromBundle(bundledPath: bundledPath)
            } catch {
                bundleInstallError = error
                LogError("安装 bundle 内 OpenClaw 失败，尝试外部回退", error: error)
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
        } else if bundledOpenClawPath() == nil {
            errorMessage = "OpenClaw 未打包在 App Bundle 中"
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
        let bundledPath = bundledOpenClawPath()
        let systemPath = await findSystemOpenClaw()
        let managed = await inspectCandidate(at: managedInstallPath, source: .managedInstall)

        if let managed, managed.isUsable {
            return OpenClawBinaryInspection(
                source: managed.source,
                executablePath: managed.path,
                version: managed.version,
                issue: nil,
                bundledPath: bundledPath,
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
                managedInstallPath: managedInstallPath,
                legacyInstallPath: legacyInstallPath,
                systemPath: systemPath
            )
        }

        if bundledPath != nil {
            return OpenClawBinaryInspection(
                source: .bundledOnly,
                executablePath: nil,
                version: nil,
                issue: nil,
                bundledPath: bundledPath,
                managedInstallPath: managedInstallPath,
                legacyInstallPath: legacyInstallPath,
                systemPath: systemPath
            )
        }

        return OpenClawBinaryInspection(
            source: .missing,
            executablePath: nil,
            version: nil,
            issue: "App Bundle 中没有可用的 OpenClaw。",
            bundledPath: nil,
            managedInstallPath: managedInstallPath,
            legacyInstallPath: legacyInstallPath,
            systemPath: systemPath
        )
    }

    func reinstallManagedOpenClaw() async throws -> String {
        guard let bundledPath = bundledOpenClawPath() else {
            self.openclawStatus = .error("OpenClaw 未打包在 App Bundle 中")
            throw DependencyError.bundledNotFound
        }

        let managedURL = URL(fileURLWithPath: managedInstallPath)
        if FileManager.default.fileExists(atPath: managedInstallPath) {
            try? FileManager.default.removeItem(at: managedURL)
        }

        return try await installFromBundle(bundledPath: bundledPath)
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

    /// 获取 Bundle 中的 openclaw 路径
    private func bundledOpenClawPath() -> String? {
        if let resourcePath = Bundle.main.path(forResource: bundledOpenClawName, ofType: nil) {
            return resourcePath
        }

        if let auxiliaryPath = Bundle.main.url(forAuxiliaryExecutable: bundledOpenClawName)?.path {
            return auxiliaryPath
        }

        let frameworksPath = Bundle.main.privateFrameworksPath
        let frameworkPath = frameworksPath?.appending("/\(bundledOpenClawName)")
        if let path = frameworkPath, FileManager.default.fileExists(atPath: path) {
            return path
        }

        return nil
    }

    /// 从 Bundle 安装到应用管理目录
    private func installFromBundle(bundledPath: String) async throws -> String {
        self.isInstalling = true
        self.openclawStatus = .installing

        defer {
            self.isInstalling = false
        }

        LogInfo("📦 正在安装 OpenClaw...")

        do {
            try FileManager.default.createDirectory(
                at: managedInstallDir,
                withIntermediateDirectories: true,
                attributes: nil
            )

            let sourceURL = URL(fileURLWithPath: bundledPath)
            let destURL = URL(fileURLWithPath: managedInstallPath)

            if FileManager.default.fileExists(atPath: managedInstallPath) {
                try FileManager.default.removeItem(at: destURL)
            }

            try FileManager.default.copyItem(at: sourceURL, to: destURL)

            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: managedInstallPath
            )

            guard FileManager.default.isExecutableFile(atPath: managedInstallPath) else {
                throw DependencyError.installFailed("文件不可执行")
            }

            let version = try await verifyOpenClaw(at: managedInstallPath)
            LogInfo("✅ OpenClaw 安装成功: v\(version)")

            self.openclawStatus = .installed(path: managedInstallPath)
            return managedInstallPath

        } catch {
            LogError("OpenClaw 安装失败", error: error)
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
        let managedBin = managedInstallDir.path
        let legacyBin = legacyInstallDir.path
        let defaultPath = "\(managedBin):\(legacyBin):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
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
            return "OpenClaw 未包含在应用中，请重新下载应用或联系支持。"
        case .installFailed(let reason):
            return "安装 OpenClaw 失败: \(reason)"
        case .verificationFailed:
            return "无法验证 OpenClaw 安装，文件可能损坏。"
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
