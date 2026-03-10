//
//  AutoAgent.swift
//  AutoAgent - 主动环境感知与通知系统 v4.0.0
//

import Foundation
import Combine
import AppKit
#if canImport(UserNotifications)
import UserNotifications
#endif
import IOKit.ps

// MARK: - 数据模型

struct UserContext {
    let timestamp: Date
    let cpuUsage: Double
    let memoryUsage: Double
    let activeApps: [String]
    let frontmostApp: String
    let diskUsage: Double
    let networkStatus: NetworkStatus
    let batteryLevel: Double?
    let isCharging: Bool?
}

enum NetworkStatus: String {
    case connected = "已连接"
    case disconnected = "未连接"
    case limited = "受限"
}

struct AgentNotification: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let title: String
    let message: String
    let type: NotificationType
    let priority: Priority
    let actions: [NotificationAction]
    let metadata: [String: String]
    
    // 用于ContentView的便捷属性
    var action: (() -> Void)? {
        return actions.first?.action
    }
    
    static func == (lhs: AgentNotification, rhs: AgentNotification) -> Bool {
        lhs.id == rhs.id
    }
}

enum NotificationType: String {
    case systemAlert = "系统警报"
    case suggestion = "建议"
    case insight = "洞察"
    case reminder = "提醒"
    case automation = "自动化"
    
    // 兼容ContentView的枚举值
    case info = "信息"
    case warning = "警告"
    case action = "动作"
    case alert = "警报"
}

enum Priority: Int {
    case low = 0
    case medium = 1
    case high = 2
    case critical = 3
}

struct NotificationAction: Identifiable {
    let id = UUID()
    let title: String
    let action: () -> Void
}

// MARK: - AutoAgent

enum AgentState {
    case idle, observing, analyzing, acting, notifying
}

class AutoAgent: ObservableObject {
    static let shared = AutoAgent()
    
    // MARK: Published Properties
    @Published var notifications: [AgentNotification] = []
    @Published var currentContext: UserContext?
    @Published var isAnalyzing = false
    @Published var lastAnalysisResult: AnalysisResult?
    @Published var state: AgentState = .idle
    @Published var pendingNotifications: [AgentNotification] = []
    @Published var lastAnalysis: AnalysisResult?
    
    // MARK: Private Properties
    private var cancellables = Set<AnyCancellable>()
    private let notificationCenter = UNUserNotificationCenter.current()
    
    // 定时器
    private var urgentScanTimer: Timer?
    private var deepAnalysisTimer: Timer?
    
    // 配置
    private let urgentScanInterval: TimeInterval = 30      // 30秒检查一次紧急问题
    private let deepAnalysisInterval: TimeInterval = 300   // 5分钟深度分析
    private let confidenceThreshold = 0.6
    
    // 去重缓存
    private var recentNotifications: [String: Date] = [:]
    private let notificationCooldown: TimeInterval = 1800  // 30分钟内不重复通知同类问题
    
    // MARK: Initialization
    
    private init() {
        LogInfo("🤖 AutoAgent 初始化开始")
        requestNotificationPermissions()
        setupTimers()
        LogInfo("✅ AutoAgent 初始化完成")
    }
    
    deinit {
        urgentScanTimer?.invalidate()
        deepAnalysisTimer?.invalidate()
        LogDebug("AutoAgent deinit")
    }
    
    // MARK: - 权限申请
    
    private func requestNotificationPermissions() {
        LogInfo("🔔 申请通知权限")
        notificationCenter.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] (granted: Bool, error: Error?) in
            if let error = error {
                LogError("通知权限申请失败", error: error)
            } else {
                LogInfo(granted ? "✅ 通知权限已授权" : "⚠️ 通知权限被拒绝")
            }
            
            DispatchQueue.main.async {
                if granted {
                    self?.setupNotificationActions()
                }
            }
        }
    }
    
    private func setupNotificationActions() {
        let actions = [
            UNNotificationAction(identifier: "VIEW", title: "查看详情", options: .foreground),
            UNNotificationAction(identifier: "DISMISS", title: "忽略", options: .destructive),
            UNNotificationAction(identifier: "AUTO_FIX", title: "自动修复", options: .foreground)
        ]
        
        let category = UNNotificationCategory(
            identifier: "AGENT_NOTIFICATION",
            actions: actions,
            intentIdentifiers: [],
            options: []
        )
        
        notificationCenter.setNotificationCategories([category])
        LogDebug("通知动作设置完成")
    }
    
    // MARK: - 定时器设置
    
    private func setupTimers() {
        LogInfo("⏱️ 设置环境扫描定时器 - 紧急扫描: \(urgentScanInterval)s, 深度分析: \(deepAnalysisInterval)s")
        
        // 紧急扫描 - 检查CPU/内存异常
        urgentScanTimer = Timer.scheduledTimer(withTimeInterval: urgentScanInterval, repeats: true) { [weak self] _ in
            self?.performUrgentScan()
        }
        
        // 深度分析 - AI驱动的建议
        deepAnalysisTimer = Timer.scheduledTimer(withTimeInterval: deepAnalysisInterval, repeats: true) { [weak self] _ in
            self?.performDeepAnalysis()
        }
        
        // 立即执行一次扫描
        performUrgentScan()
    }
    
    // MARK: - 环境扫描
    
    func performUrgentScan() {
        LogDebug("🔍 执行紧急环境扫描")
        
        let context = collectSystemContext()
        currentContext = context
        
        // 检查紧急问题
        var urgentIssues: [(String, String, Priority)] = []
        
        // CPU 检查
        if context.cpuUsage > 90 {
            urgentIssues.append(("CPU 使用率过高", "当前CPU使用率 \(Int(context.cpuUsage))%，建议检查占用资源较多的应用", .critical))
        } else if context.cpuUsage > 70 {
            urgentIssues.append(("CPU 使用率偏高", "当前CPU使用率 \(Int(context.cpuUsage))%，注意系统响应可能变慢", .medium))
        }
        
        // 内存检查 - 暂时禁用，避免频繁打扰用户
        // 如需启用，取消下面注释
        /*
        let memoryStatus = getMemoryStatus()
        if memoryStatus.pressure == .critical {
            urgentIssues.append(("内存严重不足", "系统内存严重不足，建议关闭部分应用", .critical))
        } else if memoryStatus.pressure == .warning {
            urgentIssues.append(("内存压力警告", "系统内存压力较高，可用内存 \(memoryStatus.availableMB)MB", .high))
        }
        */
        
        // 磁盘检查
        if context.diskUsage >= 98 {
            urgentIssues.append(("磁盘空间不足", "磁盘使用率超过98%，请立即清理磁盘空间", .critical))
        } else if context.diskUsage >= 90 {
            urgentIssues.append(("磁盘空间告急", "磁盘使用率 \(Int(context.diskUsage))%，建议清理", .medium))
        }
        
        // 电池检查（如果是笔记本）
        if let batteryLevel = context.batteryLevel, !context.isCharging! {
            if batteryLevel < 10 {
                urgentIssues.append(("电量极低", "电池剩余 \(Int(batteryLevel))%，请立即连接电源", .critical))
            } else if batteryLevel < 20 {
                urgentIssues.append(("电量不足", "电池剩余 \(Int(batteryLevel))%，建议连接电源", .high))
            }
        }
        
        // 发送通知
        for (title, message, priority) in urgentIssues {
            let hour = Int(Date().timeIntervalSince1970 / 3600)
            let notificationKey = "\(title)-\(hour)"
            if shouldNotifyUser(for: notificationKey, priority: priority) {
                LogWarning("⚠️ 检测到紧急问题: \(title)")
                pushLocalNotification(
                    title: title,
                    message: message,
                    priority: priority,
                    type: .systemAlert
                )
                recordNotification(key: notificationKey)
            }
        }
        
        LogDebug("✅ 紧急扫描完成，发现问题: \(urgentIssues.count)个")
    }
    
    func performDeepAnalysis() {
        guard !isAnalyzing else {
            LogDebug("已有分析任务在进行中，跳过")
            return
        }
        
        // 简化深度分析：只记录系统状态，不做主动 AI 分析
        // AI 分析由用户主动触发（通过对话）
        let context = currentContext ?? collectSystemContext()
        LogDebug("📊 系统状态记录: CPU \(Int(context.cpuUsage))%, 内存 \(Int(context.memoryUsage))%")
    }
    
    // MARK: - AI 分析（简化）
    
    // 注意：AI 分析功能已移至 CommandRunner
    // AutoAgent 只负责轻量级系统监控，不主动调用 AI
    
    // MARK: - 通知管理
    
    private func shouldNotifyUser(for key: String, priority: Priority) -> Bool {
        // 高优先级总是通知
        if priority == .critical { return true }
        
        // 检查冷却时间
        if let lastTime = recentNotifications[key],
           Date().timeIntervalSince(lastTime) < notificationCooldown {
            return false
        }
        
        return true
    }
    
    private func shouldNotifyUserAbout(result: AnalysisResult) -> Bool {
        guard result.confidence >= confidenceThreshold else {
            LogDebug("置信度不足: \(result.confidence) < \(confidenceThreshold)")
            return false
        }
        
        return shouldNotifyUser(for: result.title, priority: result.priority)
    }
    
    private func recordNotification(key: String) {
        recentNotifications[key] = Date()
        
        // 清理过期记录
        let cutoff = Date().addingTimeInterval(-notificationCooldown * 2)
        recentNotifications = recentNotifications.filter { $0.value > cutoff }
    }
    
    private func pushLocalNotification(title: String, message: String, priority: Priority, type: NotificationType) {
        LogInfo("🔔 发送通知 [\(type.rawValue)] \(title): \(message.prefix(50))...")
        
        let content = UNMutableNotificationContent()
        content.title = "\(type.emoji) \(title)"
        content.body = message
        content.sound = priority == .critical ? .defaultCritical : .default
        content.categoryIdentifier = "AGENT_NOTIFICATION"
        content.userInfo = ["priority": priority.rawValue, "type": type.rawValue]
        
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil // 立即显示
        )
        
        notificationCenter.add(request) { error in
            if let error = error {
                LogError("通知发送失败", error: error)
            } else {
                LogDebug("✅ 通知已发送")
            }
        }
        
        // 对于非系统警报类型，同时添加到应用内通知列表
        // 系统警报（如内存不足）只发送系统通知，避免打扰用户界面
        guard type != .systemAlert else {
            LogDebug("系统警报不显示在应用内: \(title)")
            return
        }
        
        DispatchQueue.main.async {
            let notification = AgentNotification(
                timestamp: Date(),
                title: title,
                message: message,
                type: type,
                priority: priority,
                actions: self.createActions(for: type),
                metadata: ["source": "AutoAgent"]
            )
            self.notifications.insert(notification, at: 0)
            
            // 只保留最近50条
            if self.notifications.count > 50 {
                self.notifications = Array(self.notifications.prefix(50))
            }
        }
    }
    
    private func createActions(for type: NotificationType) -> [NotificationAction] {
        switch type {
        case .systemAlert:
            return [
                NotificationAction(title: "查看详情", action: { /* 打开系统监控 */ }),
                NotificationAction(title: "忽略", action: { /* 忽略 */ })
            ]
        case .suggestion:
            return [
                NotificationAction(title: "了解更多", action: { /* 打开详情 */ }),
                NotificationAction(title: "稍后再说", action: { /* 延迟提醒 */ })
            ]
        case .automation:
            return [
                NotificationAction(title: "执行", action: { /* 执行自动化 */ }),
                NotificationAction(title: "取消", action: { /* 取消 */ })
            ]
        default:
            return []
        }
    }
    
    // MARK: - 系统信息采集
    
    private func collectSystemContext() -> UserContext {
        let workspace = NSWorkspace.shared
        let runningApps = workspace.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map { $0.localizedName ?? "Unknown" }
        
        let frontmostApp = workspace.frontmostApplication?.localizedName ?? "Unknown"
        
        let context = UserContext(
            timestamp: Date(),
            cpuUsage: getCPUUsage(),
            memoryUsage: getMemoryUsage(),
            activeApps: Array(runningApps.prefix(10)),
            frontmostApp: frontmostApp,
            diskUsage: getDiskUsage(),
            networkStatus: checkNetworkStatus(),
            batteryLevel: getBatteryLevel(),
            isCharging: isCharging()
        )
        
        LogDebug("📊 系统状态 - CPU: \(Int(context.cpuUsage))%, 内存: \(Int(context.memoryUsage))%, 应用: \(runningApps.count)个")
        
        return context
    }
    
    // MARK: - 系统指标获取
    
    private func getCPUUsage() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size)/4
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        
        guard kerr == KERN_SUCCESS else {
            LogDebug("获取CPU信息失败")
            return 0.0
        }
        
        let totalTicks = Double(info.cpu_ticks.0 + info.cpu_ticks.1 + info.cpu_ticks.2)
        let userTicks = Double(info.cpu_ticks.0)
        
        return totalTicks > 0 ? (userTicks / totalTicks) * 100 : 0.0
    }
    
    private func getMemoryUsage() -> Double {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        
        let result: kern_return_t = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        
        guard result == KERN_SUCCESS else {
            LogDebug("获取内存信息失败")
            return 0.0
        }
        
        let used = Double(stats.active_count + stats.inactive_count + stats.wire_count)
        let total = Double(stats.active_count + stats.inactive_count + stats.wire_count + stats.free_count)
        
        return total > 0 ? (used / total) * 100 : 0.0
    }
    
    private func getMemoryStatus() -> (pressure: MemoryPressure, availableMB: Int) {
        // 简化实现，实际应使用更精确的API
        let usage = getMemoryUsage()
        let pressure: MemoryPressure
        // 进一步放宽阈值：>=98% 严重，>=95% 警告
        if usage >= 98 {
            pressure = .critical
        } else if usage >= 95 {
            pressure = .warning
        } else {
            pressure = .normal
        }
        
        // 估算可用内存
        let availableMB = Int((100 - usage) * 16) // 假设16GB总内存
        
        return (pressure, availableMB)
    }
    
    enum MemoryPressure {
        case normal, warning, critical
    }
    
    private func getDiskUsage() -> Double {
        do {
            let attributes = try FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
            if let total = attributes[.systemSize] as? NSNumber,
               let free = attributes[.systemFreeSize] as? NSNumber {
                let used = total.doubleValue - free.doubleValue
                return (used / total.doubleValue) * 100
            }
        } catch {
            LogError("获取磁盘信息失败", error: error)
        }
        return 0.0
    }
    
    private func checkNetworkStatus() -> NetworkStatus {
        // 简化实现，实际应使用 NWPathMonitor
        return .connected
    }
    
    private func getBatteryLevel() -> Double? {
        // 仅适用于笔记本
        let powerSource = IOPSCopyPowerSourcesInfo()?.takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(powerSource)?.takeRetainedValue() as? [CFTypeRef]
        
        guard let source = sources?.first else { return nil }
        
        if let info = IOPSGetPowerSourceDescription(powerSource, source)?.takeUnretainedValue() as? [String: Any],
           let capacity = info[kIOPSCurrentCapacityKey] as? Int,
           let maxCapacity = info[kIOPSMaxCapacityKey] as? Int,
           maxCapacity > 0 {
            return Double(capacity) / Double(maxCapacity) * 100
        }
        
        return nil
    }
    
    private func isCharging() -> Bool? {
        let powerSource = IOPSCopyPowerSourcesInfo()?.takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(powerSource)?.takeRetainedValue() as? [CFTypeRef]
        
        guard let source = sources?.first else { return nil }
        
        if let info = IOPSGetPowerSourceDescription(powerSource, source)?.takeUnretainedValue() as? [String: Any],
           let isCharging = info[kIOPSPowerSourceStateKey] as? String {
            return isCharging == kIOPSACPowerValue
        }
        
        return nil
    }
    
    // MARK: - 公共方法
    
    func recordUserInput(_ input: String) {
        LogDebug("📝 记录用户输入: \(input.prefix(30))...")
        state = .observing
        
        // 更新待处理通知列表（用于UI显示）
        updatePendingNotifications()
    }
    
    func dismissNotification(_ notification: AgentNotification) {
        notifications.removeAll { $0.id == notification.id }
        pendingNotifications.removeAll { $0.id == notification.id }
    }
    
    func clearAllNotifications() {
        notifications.removeAll()
        pendingNotifications.removeAll()
    }
    
    func forceAnalysis() {
        LogInfo("🔄 用户触发强制分析")
        performDeepAnalysis()
    }
    
    func requestImmediateAnalysis() {
        LogInfo("🔄 请求立即分析")
        performUrgentScan()
        performDeepAnalysis()
    }
    
    func getLogFilePath() -> String {
        return FileLogger.shared.getLogFilePath()
    }
    
    private func updatePendingNotifications() {
        // 将高优先级通知显示在pendingNotifications中
        pendingNotifications = notifications.filter { 
            $0.priority == .high || $0.priority == .critical 
        }
    }
}

// MARK: - Analysis Result

struct AnalysisResult {
    let title: String
    let message: String
    let priority: Priority
    let type: NotificationType
    let confidence: Double
    var findings: [Finding] = []
    
    struct Finding: Identifiable {
        let id = UUID()
        let content: String
        let source: FindingSource
    }
    
    enum FindingSource {
        case openclaw
        case kimi
    }
}

// MARK: - NotificationType Extension

extension NotificationType {
    var emoji: String {
        switch self {
        case .systemAlert: return "🚨"
        case .suggestion: return "💡"
        case .insight: return "🔍"
        case .reminder: return "⏰"
        case .automation: return "⚡️"
        case .info: return "ℹ️"
        case .warning: return "⚠️"
        case .action: return "🔔"
        case .alert: return "🚨"
        }
    }
}
