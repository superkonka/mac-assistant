//
//  OpenClawStatusViewModel.swift
//  MacAssistant
//
//  OpenClaw 状态面板 ViewModel
//

import SwiftUI
import Combine
import AppKit

@MainActor
class OpenClawStatusViewModel: ObservableObject {
    // MARK: - 发布属性
    
    @Published var status: OpenClawRuntimeStatus = .unknown
    @Published var isChecking = false
    @Published var isRepairing = false
    @Published var isReinstalling = false
    @Published var showTechnicalDetails = false
    
    // 技术详情
    @Published var versionInfo = "--"
    @Published var responseTimeText = "--"
    @Published var lastCheckTimeText = "--"
    @Published var errorCount = 0
    @Published var lastErrorMessage: String? = nil
    @Published var totalRequests = 0
    @Published var successRateText = "--"
    @Published var uptimeText: String? = nil
    
    // 配置信息
    @Published var installPath = "--"
    @Published var configPath = "--"
    @Published var logPath = "--"
    @Published var gatewayPort = 18889
    
    // 自愈历史
    @Published var healingHistory: [HealingRecord] = []
    
    // MARK: - 私有属性
    
    private let healthChecker = OpenClawHealthChecker.shared
    private let dependencyManager = DependencyManager.shared
    private let runtimeManager = OpenClawGatewayRuntimeManager.shared
    private var checkTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    
    private var lastCheckTime: Date?
    private var consecutiveErrors = 0
    private var maxConsecutiveErrors = 3
    
    // MARK: - 公共方法
    
    func startMonitoring() {
        // 初始检查
        checkHealth()
        
        // 定时检查
        checkTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkHealth()
            }
        }
        
        // 监听健康检查器状态变化
        healthChecker.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateFromHealthChecker()
            }
            .store(in: &cancellables)
        
        // 加载配置信息
        loadConfigurationInfo()
    }
    
    func stopMonitoring() {
        checkTimer?.invalidate()
        checkTimer = nil
    }
    
    func checkHealth() {
        guard !isChecking else { return }
        
        isChecking = true
        lastCheckTime = Date()
        
        Task {
            let startTime = Date()
            
            // 检查依赖状态
            let dependencyStatus = await checkDependencyStatus()
            
            // 检查 Gateway 状态
            let gatewayStatus = await checkGatewayStatus()
            
            let responseTime = Date().timeIntervalSince(startTime)
            
            await MainActor.run {
                updateStatus(
                    dependencyStatus: dependencyStatus,
                    gatewayStatus: gatewayStatus,
                    responseTime: responseTime
                )
                self.isChecking = false
            }
        }
    }
    
    func attemptRepair() {
        guard !isRepairing else { return }
        
        isRepairing = true
        status = .repairing
        
        logHealingAttempt(action: "自动修复")
        
        Task {
            var success = false
            
            // 修复步骤 1: 重启 Gateway
            do {
                _ = try await runtimeManager.forceRestart()
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 等待 2 秒
                
                // 验证是否恢复
                let healthStatus = await healthChecker.checkHealth()
                if healthStatus != .unhealthy {
                    success = true
                }
            } catch {
                LogError("Gateway 重启失败", error: error)
            }
            
            // 修复步骤 2: 如果 Gateway 重启失败，尝试重置配置
            if !success {
                do {
                    try await resetConfiguration()
                    _ = try? await runtimeManager.forceRestart()
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    
                    let healthStatus = await healthChecker.checkHealth()
                    if healthStatus != .unhealthy {
                        success = true
                    }
                } catch {
                    LogError("配置重置失败", error: error)
                }
            }
            
            await MainActor.run {
                self.isRepairing = false
                self.logHealingResult(action: "自动修复", success: success)
                
                if success {
                    self.status = .healthy
                    self.consecutiveErrors = 0
                } else {
                    self.status = .needsReinstall
                    self.lastErrorMessage = "自动修复失败，建议重装 OpenClaw"
                }
                
                self.updateDisplayInfo()
            }
        }
    }
    
    func reinstallOpenClaw() {
        guard !isReinstalling else { return }
        
        isReinstalling = true
        logHealingAttempt(action: "重新安装")
        
        Task {
            let success = await performReinstall()
            
            await MainActor.run {
                self.isReinstalling = false
                self.logHealingResult(action: "重新安装", success: success)
                
                if success {
                    self.status = .healthy
                    self.consecutiveErrors = 0
                    self.lastErrorMessage = nil
                } else {
                    self.status = .unhealthy
                    self.lastErrorMessage = "重装失败，请检查磁盘空间和权限"
                }
                
                self.loadConfigurationInfo()
                self.updateDisplayInfo()
            }
        }
    }
    
    func restartGateway() {
        Task {
            do {
                _ = try await runtimeManager.forceRestart()
                logHealingRecord(
                    action: "重启 Gateway",
                    success: true,
                    message: "Gateway 已重启"
                )
                
                // 刷新状态
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                checkHealth()
            } catch {
                logHealingRecord(
                    action: "重启 Gateway",
                    success: false,
                    message: error.localizedDescription
                )
            }
        }
    }
    
    func openLogFile() {
        let logURL = runtimeManager.gatewayLogPath()
        NSWorkspace.shared.open(logURL.deletingLastPathComponent())
    }
    
    func openConfigDirectory() {
        let configDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openclaw-macassistant")
        NSWorkspace.shared.open(configDir)
    }
    
    // MARK: - 私有方法
    
    private func checkDependencyStatus() async -> DependencyStatusResult {
        // 检查 OpenClaw 可执行文件
        let executablePath = findOpenClawExecutable()
        guard let path = executablePath else {
            return .notFound
        }
        
        // 验证可执行性
        if !FileManager.default.isExecutableFile(atPath: path) {
            return .notExecutable
        }
        
        // 检查版本
        do {
            let version = try await getOpenClawVersion(at: path)
            return .ok(version: version, path: path)
        } catch {
            return .verificationFailed(error: error.localizedDescription)
        }
    }
    
    private func checkGatewayStatus() async -> GatewayStatusResult {
        let healthStatus = await healthChecker.checkHealth()
        
        switch healthStatus {
        case .healthy:
            return .healthy
        case .degraded:
            return .degraded
        case .unhealthy:
            return .unhealthy
        case .unknown:
            return .unknown
        }
    }
    
    private func updateStatus(
        dependencyStatus: DependencyStatusResult,
        gatewayStatus: GatewayStatusResult,
        responseTime: TimeInterval
    ) {
        // 更新响应时间显示
        responseTimeText = String(format: "%.2f s", responseTime)
        
        // 处理依赖状态
        switch dependencyStatus {
        case .notFound, .notExecutable:
            status = .needsReinstall
            consecutiveErrors += 1
            lastErrorMessage = "OpenClaw 可执行文件缺失或损坏"
            
        case .verificationFailed(let error):
            status = .needsReinstall
            consecutiveErrors += 1
            lastErrorMessage = "验证失败: \(error)"
            
        case .ok(let version, let path):
            versionInfo = version
            installPath = path
            
            // 依赖正常，检查 Gateway 状态
            switch gatewayStatus {
            case .healthy:
                status = .healthy
                consecutiveErrors = 0
                lastErrorMessage = nil
                
            case .degraded:
                status = .degraded
                consecutiveErrors = 0
                
            case .unhealthy:
                consecutiveErrors += 1
                if consecutiveErrors >= maxConsecutiveErrors {
                    status = .unhealthy
                    lastErrorMessage = "Gateway 连续 \(consecutiveErrors) 次检查失败"
                } else {
                    status = .degraded
                }
                
            case .unknown:
                status = .unknown
            }
        }
        
        // 更新错误计数
        if status == .unhealthy || status == .needsReinstall {
            errorCount += 1
        }
        
        // 更新最后检查时间
        updateLastCheckTime()
        
        // 更新成功率
        updateSuccessRate()
    }
    
    private func performReinstall() async -> Bool {
        do {
            // 1. 停止 Gateway
            _ = try? await runtimeManager.stopGatewayIfNeeded()
            
            // 2. 删除现有安装
            let localBin = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin/openclaw")
            if FileManager.default.fileExists(atPath: localBin.path) {
                try FileManager.default.removeItem(at: localBin)
            }
            
            // 3. 重置状态
            consecutiveErrors = 0
            
            // 4. 重新安装
            _ = try await dependencyManager.ensureOpenClawAvailable()
            
            // 5. 启动 Gateway
            _ = try await runtimeManager.ensureGatewayReadyWithDependencies()
            
            return true
        } catch {
            LogError("重装 OpenClaw 失败", error: error)
            return false
        }
    }
    
    private func resetConfiguration() async throws {
        let configDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openclaw-macassistant")
        
        // 备份旧配置
        let backupDir = configDir.appendingPathExtension("backup.\(Int(Date().timeIntervalSince1970))")
        if FileManager.default.fileExists(atPath: configDir.path) {
            try? FileManager.default.moveItem(at: configDir, to: backupDir)
        }
        
        // 创建新配置目录
        try FileManager.default.createDirectory(
            at: configDir,
            withIntermediateDirectories: true
        )
    }
    
    private func findOpenClawExecutable() -> String? {
        // 检查系统 PATH
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
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            
            return path?.isEmpty == false ? path : nil
        } catch {
            return nil
        }
    }
    
    private func getOpenClawVersion(at path: String) async throws -> String {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["--version"]
            
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            
            try process.run()
            process.waitUntilExit()
            
            guard process.terminationStatus == 0 else {
                throw NSError(domain: "OpenClawStatusViewModel", code: 1)
            }
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        }.value
    }
    
    private func updateFromHealthChecker() {
        // 从健康检查器同步状态
        switch healthChecker.status {
        case .healthy:
            if status != .repairing && status != .reinstalling && status != .needsReinstall {
                status = .healthy
            }
        case .degraded:
            if status != .repairing && status != .reinstalling && status != .needsReinstall {
                status = .degraded
            }
        case .unhealthy:
            if status != .repairing && status != .reinstalling && status != .needsReinstall {
                status = .unhealthy
            }
        case .unknown:
            break
        }
        
        updateDisplayInfo()
    }
    
    private func updateDisplayInfo() {
        // 更新最后检查时间
        updateLastCheckTime()
        
        // 更新响应时间
        if healthChecker.averageResponseTime > 0 {
            responseTimeText = String(format: "%.2f s", healthChecker.averageResponseTime)
        }
        
        // 更新错误计数
        errorCount = healthChecker.errorCount
    }
    
    private func updateLastCheckTime() {
        guard let lastCheck = lastCheckTime else {
            lastCheckTimeText = "--"
            return
        }
        
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        lastCheckTimeText = formatter.localizedString(for: lastCheck, relativeTo: Date())
    }
    
    private func updateSuccessRate() {
        let total = totalRequests + errorCount
        guard total > 0 else {
            successRateText = "--"
            return
        }
        
        let rate = Double(totalRequests) / Double(total) * 100
        successRateText = String(format: "%.1f%%", rate)
    }
    
    private func loadConfigurationInfo() {
        installPath = dependencyManager.currentStatus.path ?? "未安装"
        configPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openclaw-macassistant/openclaw.json")
            .path
        logPath = runtimeManager.gatewayLogPath().path
        gatewayPort = 18889
    }
    
    // MARK: - 自愈历史记录
    
    private func logHealingAttempt(action: String) {
        let record = HealingRecord(
            timestamp: Date(),
            action: action,
            success: false, // 初始为 false，完成后更新
            message: "正在进行..."
        )
        healingHistory.insert(record, at: 0)
    }
    
    private func logHealingResult(action: String, success: Bool) {
        // 找到最近的相同操作记录并更新
        if let index = healingHistory.firstIndex(where: { $0.action == action && !$0.success }) {
            let updatedRecord = HealingRecord(
                timestamp: healingHistory[index].timestamp,
                action: action,
                success: success,
                message: success ? "完成" : "失败"
            )
            healingHistory[index] = updatedRecord
        } else {
            // 添加新记录
            logHealingRecord(action: action, success: success, message: nil)
        }
        
        // 只保留最近 50 条记录
        if healingHistory.count > 50 {
            healingHistory = Array(healingHistory.prefix(50))
        }
    }
    
    private func logHealingRecord(action: String, success: Bool, message: String?) {
        let record = HealingRecord(
            timestamp: Date(),
            action: action,
            success: success,
            message: message
        )
        healingHistory.insert(record, at: 0)
        
        // 只保留最近 50 条记录
        if healingHistory.count > 50 {
            healingHistory = Array(healingHistory.prefix(50))
        }
    }
}

// MARK: - 辅助类型

enum DependencyStatusResult {
    case notFound
    case notExecutable
    case verificationFailed(error: String)
    case ok(version: String, path: String)
}

enum GatewayStatusResult {
    case healthy
    case degraded
    case unhealthy
    case unknown
}

// MARK: - DependencyStatus 扩展

extension DependencyStatus {
    var path: String? {
        switch self {
        case .installed(let path):
            return path
        default:
            return nil
        }
    }
}
