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
    case notInstalled      // 未安装
    case bundledAvailable  // Bundle 中有可用版本
    case installing        // 正在安装
    case installed(path: String)  // 已安装，包含路径
    case error(String)     // 安装错误
}

/// 依赖管理器 - 确保 OpenClaw CLI 可用
actor DependencyManager: ObservableObject {
    static let shared = DependencyManager()
    
    @Published private(set) var openclawStatus: DependencyStatus = .notInstalled
    @Published private(set) var isInstalling: Bool = false
    
    private let bundledOpenClawName = "openclaw"
    private let installDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/bin")
    private let installPath: String
    
    private init() {
        self.installPath = installDir.appendingPathComponent("openclaw").path
    }
    
    // MARK: - 公共接口
    
    /// 检查并确保 OpenClaw 可用
    /// - Returns: OpenClaw 可执行文件的完整路径
    /// - Throws: 如果无法安装或找到 OpenClaw
    func ensureOpenClawAvailable() async throws -> String {
        // 1. 首先检查系统 PATH 中是否已有 openclaw
        if let systemPath = await findSystemOpenClaw() {
            LogInfo("✅ 使用系统 OpenClaw: \(systemPath)")
            await MainActor.run {
                self.openclawStatus = .installed(path: systemPath)
            }
            return systemPath
        }
        
        // 2. 检查我们安装的路径
        if FileManager.default.isExecutableFile(atPath: installPath) {
            LogInfo("✅ 使用已安装的 OpenClaw: \(installPath)")
            await MainActor.run {
                self.openclawStatus = .installed(path: installPath)
            }
            return installPath
        }
        
        // 3. 检查 Bundle 中是否有打包版本
        guard let bundledPath = bundledOpenClawPath() else {
            let error = "OpenClaw 未打包在 App Bundle 中"
            LogError(error)
            await MainActor.run {
                self.openclawStatus = .error(error)
            }
            throw DependencyError.bundledNotFound
        }
        
        await MainActor.run {
            self.openclawStatus = .bundledAvailable
        }
        
        // 4. 从 Bundle 安装到用户目录
        return try await installFromBundle(bundledPath: bundledPath)
    }
    
    /// 检查是否需要首次设置
    var needsFirstTimeSetup: Bool {
        get async {
            // 检查是否有可用的 Agent 配置
            let agentStore = AgentStore.shared
            return agentStore.usableAgents.isEmpty
        }
    }
    
    /// 获取安装进度状态
    var currentStatus: DependencyStatus {
        get async {
            return openclawStatus
        }
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
            
            // 验证是否可执行
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
        // 1. 先检查 Resources 目录
        if let resourcePath = Bundle.main.path(forResource: bundledOpenClawName, ofType: nil) {
            return resourcePath
        }
        
        // 2. 检查辅助可执行文件
        if let auxiliaryPath = Bundle.main.url(forAuxiliaryExecutable: bundledOpenClawName)?.path {
            return auxiliaryPath
        }
        
        // 3. 检查 Frameworks
        let frameworksPath = Bundle.main.privateFrameworksPath
        let frameworkPath = frameworksPath?.appending("/\(bundledOpenClawName)")
        if let path = frameworkPath, FileManager.default.fileExists(atPath: path) {
            return path
        }
        
        return nil
    }
    
    /// 从 Bundle 安装到用户目录
    private func installFromBundle(bundledPath: String) async throws -> String {
        await MainActor.run {
            self.isInstalling = true
            self.openclawStatus = .installing
        }
        
        defer {
            Task { @MainActor in
                self.isInstalling = false
            }
        }
        
        LogInfo("📦 正在安装 OpenClaw...")
        
        do {
            // 1. 创建安装目录
            try FileManager.default.createDirectory(
                at: installDir,
                withIntermediateDirectories: true,
                attributes: nil
            )
            
            // 2. 复制文件
            let sourceURL = URL(fileURLWithPath: bundledPath)
            let destURL = URL(fileURLWithPath: installPath)
            
            // 如果已存在，先删除
            if FileManager.default.fileExists(atPath: installPath) {
                try FileManager.default.removeItem(at: destURL)
            }
            
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
            
            // 3. 设置可执行权限
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: installPath
            )
            
            // 4. 验证安装
            guard FileManager.default.isExecutableFile(atPath: installPath) else {
                throw DependencyError.installFailed("文件不可执行")
            }
            
            // 5. 测试运行
            let version = try await verifyOpenClaw(at: installPath)
            LogInfo("✅ OpenClaw 安装成功: v\(version)")
            
            await MainActor.run {
                self.openclawStatus = .installed(path: installPath)
            }
            
            return installPath
            
        } catch {
            LogError("OpenClaw 安装失败", error: error)
            await MainActor.run {
                self.openclawStatus = .error(error.localizedDescription)
            }
            throw DependencyError.installFailed(error.localizedDescription)
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
        let version = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        return version
    }
    
    /// 获取 PATH 环境变量（包含我们的安装目录）
    func pathEnvironment() -> String {
        let localBin = installDir.path
        let defaultPath = "\(localBin):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
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
            return "请尝试删除 ~/.local/bin/openclaw 后重启应用。"
        }
    }
}
