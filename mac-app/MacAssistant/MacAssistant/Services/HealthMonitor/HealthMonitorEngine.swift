//
//  HealthMonitorEngine.swift
//  MacAssistant
//
//  健康监控引擎 - 实时监控服务健康状态
//

import Foundation
import Combine

// MARK: - 健康状态
enum HealthStatus: Equatable {
    case healthy              // 健康
    case unhealthy(reason: String, severity: HealthSeverity)  // 不健康
    case recovering          // 恢复中
    case flapping            // 状态震荡（频繁切换）
    case unknown             // 未知
    
    var isHealthy: Bool {
        if case .healthy = self { return true }
        return false
    }
    
    var displayName: String {
        switch self {
        case .healthy: return "健康"
        case .unhealthy: return "不健康"
        case .recovering: return "恢复中"
        case .flapping: return "状态震荡"
        case .unknown: return "未知"
        }
    }
    
    var color: String {
        switch self {
        case .healthy: return "green"
        case .unhealthy(let _, let severity):
            return severity == .critical ? "red" : "orange"
        case .recovering: return "yellow"
        case .flapping: return "purple"
        case .unknown: return "gray"
        }
    }
}

enum HealthSeverity: String, CaseIterable, Codable {
    case info = "info"
    case warning = "warning"
    case error = "error"
    case critical = "critical"
    
    var displayName: String {
        switch self {
        case .info: return "信息"
        case .warning: return "警告"
        case .error: return "错误"
        case .critical: return "严重"
        }
    }
}

// MARK: - 健康检查类型
enum HealthCheckType {
    case http(endpoint: String, expectedStatus: Int)
    case tcp(port: Int)
    case process(pid: Int?)
    case custom(check: () async -> HealthCheckResult)
}

// MARK: - 健康检查结果扩展
extension HealthCheckResult {
    static func healthy(responseTimeMs: Int? = nil, message: String? = nil) -> HealthCheckResult {
        HealthCheckResult(
            timestamp: Date(),
            isHealthy: true,
            responseTimeMs: responseTimeMs,
            message: message,
            metadata: [:]
        )
    }
    
    static func unhealthy(message: String, metadata: [String: String] = [:]) -> HealthCheckResult {
        HealthCheckResult(
            timestamp: Date(),
            isHealthy: false,
            responseTimeMs: nil,
            message: message,
            metadata: metadata
        )
    }
}

// MARK: - 健康检查策略
struct HealthCheckPolicy {
    let checkType: HealthCheckType
    let interval: TimeInterval      // 检查间隔（默认30秒）
    let timeout: TimeInterval       // 超时时间（默认10秒）
    let retryCount: Int             // 失败重试次数（默认3次）
    let retryInterval: TimeInterval // 重试间隔（默认5秒）
    
    // 不健康时的处理策略
    let unhealthyPolicy: UnhealthyPolicy
    
    // 状态震荡检测
    let flappingThreshold: Int      // 多少次状态变更视为震荡（默认5次/10分钟）
    let flappingWindow: TimeInterval // 震荡检测窗口（默认10分钟）
    
    static let `default` = HealthCheckPolicy(
        checkType: .tcp(port: 0),
        interval: 30,
        timeout: 10,
        retryCount: 3,
        retryInterval: 5,
        unhealthyPolicy: .notifyOnly,
        flappingThreshold: 5,
        flappingWindow: 600
    )
}

// MARK: - 不健康处理策略
enum UnhealthyPolicy {
    case notifyOnly              // 仅通知
    case autoRestart(maxRetries: Int, cooldown: TimeInterval)  // 自动重启
    case aiDiagnosis             // AI 诊断
    case escalate(to: String)    // 升级到指定 Agent
    case custom(action: (ServiceDefinition) async -> Void)  // 自定义动作
}

// MARK: - 健康状态变更记录
struct HealthStatusChange {
    let serviceID: String
    let serviceName: String
    let from: HealthStatus
    let to: HealthStatus
    let timestamp: Date
    let details: String
    let checkResult: HealthCheckResult?
}

// MARK: - 健康监控事件
enum HealthMonitorEvent {
    case statusChanged(HealthStatusChange)
    case checkPerformed(serviceID: String, result: HealthCheckResult)
    case unhealthyDetected(serviceID: String, severity: HealthSeverity, message: String)
    case autoRestartInitiated(serviceID: String, attempt: Int, maxRetries: Int)
    case autoRestartSucceeded(serviceID: String, duration: TimeInterval)
    case autoRestartFailed(serviceID: String, error: String)
    case aiDiagnosisStarted(serviceID: String)
    case aiDiagnosisCompleted(serviceID: String, diagnosis: String, suggestions: [String])
    case flappingDetected(serviceID: String, changeCount: Int, window: TimeInterval)
}

// MARK: - 服务健康监控器
actor ServiceHealthMonitor {
    let service: ServiceDefinition
    let policy: HealthCheckPolicy
    
    private var isRunning = false
    private var checkTask: Task<Void, Never>?
    private var consecutiveFailures = 0
    private var consecutiveSuccesses = 0
    private var statusHistory: [(timestamp: Date, status: HealthStatus)] = []
    private var lastRestartAttempt: Date?
    private var restartCount = 0
    
    var onStatusChange: ((HealthStatusChange) -> Void)?
    var onCheckPerformed: ((HealthCheckResult) -> Void)?
    var onUnhealthy: ((HealthSeverity, String) -> Void)?
    
    init(service: ServiceDefinition, policy: HealthCheckPolicy) {
        self.service = service
        self.policy = policy
    }
    
    func start() {
        guard !isRunning else { return }
        isRunning = true
        
        checkTask = Task {
            while !Task.isCancelled && isRunning {
                await performCheck()
                try? await Task.sleep(nanoseconds: UInt64(policy.interval * 1_000_000_000))
            }
        }
    }
    
    func stop() {
        isRunning = false
        checkTask?.cancel()
        checkTask = nil
    }
    
    private func performCheck() async {
        let result = await executeHealthCheck()
        onCheckPerformed?(result)
        
        // 更新历史记录
        let newStatus: HealthStatus = result.isHealthy ? .healthy : .unhealthy(
            reason: result.message ?? "健康检查失败",
            severity: determineSeverity()
        )
        
        updateStatusHistory(newStatus)
        
        // 检测状态变更
        if let lastStatus = statusHistory.dropLast().last?.status,
           lastStatus != newStatus {
            let change = HealthStatusChange(
                serviceID: service.id,
                serviceName: service.name,
                from: lastStatus,
                to: newStatus,
                timestamp: Date(),
                details: result.message ?? "",
                checkResult: result
            )
            onStatusChange?(change)
            
            // 如果不健康，触发处理
            if case .unhealthy(let reason, let severity) = newStatus {
                onUnhealthy?(severity, reason)
            }
        }
        
        // 检测状态震荡
        if isFlapping() {
            handleFlapping()
        }
    }
    
    private func executeHealthCheck() async -> HealthCheckResult {
        switch policy.checkType {
        case .http(let endpoint, let expectedStatus):
            return await checkHTTP(endpoint: endpoint, expectedStatus: expectedStatus)
        case .tcp(let port):
            return await checkTCP(port: port)
        case .process(let pid):
            return await checkProcess(pid: pid)
        case .custom(let check):
            return await check()
        }
    }
    
    private func checkHTTP(endpoint: String, expectedStatus: Int) async -> HealthCheckResult {
        guard let url = URL(string: endpoint) else {
            return .unhealthy(message: "无效的 URL: \(endpoint)")
        }
        
        let startTime = Date()
        
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            let responseTime = Int(Date().timeIntervalSince(startTime) * 1000)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                return .unhealthy(message: "非 HTTP 响应")
            }
            
            if httpResponse.statusCode == expectedStatus {
                consecutiveSuccesses += 1
                consecutiveFailures = 0
                return .healthy(responseTimeMs: responseTime)
            } else {
                consecutiveFailures += 1
                consecutiveSuccesses = 0
                return .unhealthy(
                    message: "HTTP 状态码异常: \(httpResponse.statusCode)",
                    metadata: ["statusCode": "\(httpResponse.statusCode)"]
                )
            }
        } catch {
            consecutiveFailures += 1
            consecutiveSuccesses = 0
            return .unhealthy(message: "HTTP 请求失败: \(error.localizedDescription)")
        }
    }
    
    private func checkTCP(port: Int) async -> HealthCheckResult {
        let startTime = Date()
        
        let task = Process()
        task.launchPath = "/usr/bin/nc"
        task.arguments = ["-z", "-G", "5", "127.0.0.1", String(port)]
        
        return await withCheckedContinuation { continuation in
            task.terminationHandler = { [weak self] process in
                let responseTime = Int(Date().timeIntervalSince(startTime) * 1000)
                
                Task {
                    if process.terminationStatus == 0 {
                        await self?.recordSuccess()
                        continuation.resume(returning: .healthy(responseTimeMs: responseTime))
                    } else {
                        await self?.recordFailure()
                        continuation.resume(returning: .unhealthy(
                            message: "端口 \(port) 未响应",
                            metadata: ["port": "\(port)"]
                        ))
                    }
                }
            }
            
            do {
                try task.run()
            } catch {
                Task {
                    await self.recordFailure()
                    continuation.resume(returning: .unhealthy(
                        message: "检查执行失败: \(error.localizedDescription)"
                    ))
                }
            }
        }
    }
    
    private func checkProcess(pid: Int?) async -> HealthCheckResult {
        let checkPID = pid ?? service.startCommand.flatMap { getPID(from: $0) }
        
        guard let pidToCheck = checkPID else {
            return .unhealthy(message: "无法获取进程 PID")
        }
        
        let task = Process()
        task.launchPath = "/bin/kill"
        task.arguments = ["-0", String(pidToCheck)]
        
        return await withCheckedContinuation { continuation in
            task.terminationHandler = { [weak self] process in
                Task {
                    if process.terminationStatus == 0 {
                        await self?.recordSuccess()
                        continuation.resume(returning: .healthy())
                    } else {
                        await self?.recordFailure()
                        continuation.resume(returning: .unhealthy(
                            message: "进程 \(pidToCheck) 不存在",
                            metadata: ["pid": "\(pidToCheck)"]
                        ))
                    }
                }
            }
            
            do {
                try task.run()
            } catch {
                Task {
                    await self.recordFailure()
                    continuation.resume(returning: .unhealthy(
                        message: "检查执行失败: \(error.localizedDescription)"
                    ))
                }
            }
        }
    }
    
    /// 记录成功检查
    private func recordSuccess() {
        consecutiveSuccesses += 1
        consecutiveFailures = 0
    }
    
    /// 记录失败检查
    private func recordFailure() {
        consecutiveFailures += 1
        consecutiveSuccesses = 0
    }
    
    private func getPID(from command: String) -> Int? {
        let processName = command.components(separatedBy: " ").first ?? command
        
        let task = Process()
        task.launchPath = "/usr/bin/pgrep"
        task.arguments = ["-x", processName]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        
        do {
            try task.run()
            task.waitUntilExit()
            
            if task.terminationStatus == 0,
               let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8),
               let pid = Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return pid
            }
        } catch {
            LogError("[ServiceHealthMonitor] 获取 PID 失败: \(error)")
        }
        
        return nil
    }
    
    private func determineSeverity() -> HealthSeverity {
        if consecutiveFailures >= policy.retryCount * 2 {
            return .critical
        } else if consecutiveFailures >= policy.retryCount {
            return .error
        } else if consecutiveFailures >= 2 {
            return .warning
        }
        return .info
    }
    
    private func updateStatusHistory(_ status: HealthStatus) {
        statusHistory.append((timestamp: Date(), status: status))
        
        // 清理过期记录
        let cutoff = Date().addingTimeInterval(-policy.flappingWindow)
        statusHistory.removeAll { $0.timestamp < cutoff }
    }
    
    private func isFlapping() -> Bool {
        guard statusHistory.count >= policy.flappingThreshold else { return false }
        
        // 计算状态变更次数
        var changes = 0
        var lastStatus: HealthStatus?
        for entry in statusHistory {
            if let last = lastStatus, last != entry.status {
                changes += 1
            }
            lastStatus = entry.status
        }
        
        return changes >= policy.flappingThreshold
    }
    
    private func handleFlapping() {
        // 状态震荡处理 - 延长检查间隔
        LogWarning("[ServiceHealthMonitor] 服务 \(service.name) 状态震荡检测")
    }
    
    // MARK: - 自愈相关
    
    func canAttemptRestart() -> Bool {
        guard case .autoRestart(let maxRetries, let cooldown) = policy.unhealthyPolicy else {
            return false
        }
        
        if restartCount >= maxRetries {
            return false
        }
        
        if let lastAttempt = lastRestartAttempt,
           Date().timeIntervalSince(lastAttempt) < cooldown {
            return false
        }
        
        return true
    }
    
    func recordRestartAttempt() {
        lastRestartAttempt = Date()
        restartCount += 1
    }
    
    func resetRestartCount() {
        restartCount = 0
    }
}

// MARK: - 健康监控引擎
@MainActor
final class HealthMonitorEngine: ObservableObject {
    static let shared = HealthMonitorEngine()
    
    // MARK: - 配置
    @Published var isEnabled = false
    @Published var globalPolicy: HealthCheckPolicy = .default
    
    // MARK: - 状态
    @Published var monitorStatuses: [String: HealthStatus] = [:]
    @Published var lastCheckResults: [String: HealthCheckResult] = [:]
    @Published var recentEvents: [HealthEventRecord] = []
    
    // MARK: - 事件流
    let eventPublisher = PassthroughSubject<HealthMonitorEvent, Never>()
    
    // MARK: - 公开属性
    var monitorCount: Int { monitors.count }
    
    /// 检查服务是否正在被监控
    func isMonitoring(serviceID: String) -> Bool {
        monitors[serviceID] != nil
    }
    
    // MARK: - Private
    private var monitors: [String: ServiceHealthMonitor] = [:]
    private var cancellables = Set<AnyCancellable>()
    private let maxRecentEvents = 100
    
    private init() {
        setupUnifiedStateSync()
    }
    
    // MARK: - 统一状态同步
    private func setupUnifiedStateSync() {
        UnifiedServiceState.shared.eventPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] event in
                self?.handleUnifiedStateEvent(event)
            }
            .store(in: &cancellables)
    }
    
    private func handleUnifiedStateEvent(_ event: ServiceEvent) {
        switch event {
        case .statusChanged(let serviceID, let from, let to, let source, _):
            // 如果从 stopped 变为 running，启动健康监控
            if from == .stopped && to == .running {
                startMonitoring(serviceID: serviceID)
            }
            // 如果从 running 变为 stopped，停止健康监控
            else if to == .stopped {
                stopMonitoring(serviceID: serviceID)
            }
        default:
            break
        }
    }
    
    // MARK: - 公共 API
    
    /// 启动全局健康监控
    func startGlobalMonitoring() {
        guard isEnabled else { return }
        
        for service in ServiceManager.shared.services {
            startMonitoring(service: service)
        }
        
        LogInfo("[HealthMonitorEngine] 全局健康监控已启动")
    }
    
    /// 停止全局健康监控
    func stopGlobalMonitoring() {
        for (serviceID, monitor) in monitors {
            Task {
                await monitor.stop()
            }
        }
        monitors.removeAll()
        
        LogInfo("[HealthMonitorEngine] 全局健康监控已停止")
    }
    
    /// 为指定服务启动监控
    func startMonitoring(service: ServiceDefinition) {
        guard isEnabled else { return }
        guard monitors[service.id] == nil else { return }
        
        let policy = createPolicy(for: service)
        
        let monitor = ServiceHealthMonitor(service: service, policy: policy)
        
        // 设置回调
        Task {
            await monitor.setCallbacks(
                onStatusChange: { [weak self] change in
                    self?.handleStatusChange(change)
                },
                onCheckPerformed: { [weak self] result in
                    self?.handleCheckPerformed(serviceID: service.id, result: result)
                },
                onUnhealthy: { [weak self] severity, message in
                    self?.handleUnhealthy(service: service, severity: severity, message: message)
                }
            )
            
            await monitor.start()
        }
        
        monitors[service.id] = monitor
        monitorStatuses[service.id] = .unknown
        
        LogInfo("[HealthMonitorEngine] 开始监控服务: \(service.name)")
    }
    
    /// 为指定服务启动监控（通过 ID）
    func startMonitoring(serviceID: String) {
        guard let service = ServiceManager.shared.services.first(where: { $0.id == serviceID }) else {
            return
        }
        startMonitoring(service: service)
    }
    
    /// 停止指定服务的监控
    func stopMonitoring(serviceID: String) {
        guard let monitor = monitors[serviceID] else { return }
        
        Task {
            await monitor.stop()
        }
        
        monitors.removeValue(forKey: serviceID)
        monitorStatuses.removeValue(forKey: serviceID)
        
        LogInfo("[HealthMonitorEngine] 停止监控服务: \(serviceID)")
    }
    
    /// 立即检查指定服务
    func checkNow(serviceID: String) async -> HealthCheckResult? {
        guard let monitor = monitors[serviceID] else { return nil }
        
        // 触发一次检查
        // 注意：这里需要通过某种方式触发检查，可能需要修改 ServiceHealthMonitor
        // 简化起见，返回最后一次结果
        return lastCheckResults[serviceID]
    }
    
    /// 获取服务健康状态
    func status(for serviceID: String) -> HealthStatus {
        return monitorStatuses[serviceID] ?? .unknown
    }
    
    /// 手动触发 AI 诊断
    func triggerAIDiagnosis(serviceID: String) {
        guard let service = ServiceManager.shared.services.first(where: { $0.id == serviceID }) else {
            return
        }
        
        performAIDiagnosis(service: service)
    }
    
    // MARK: - 私有方法
    
    private func createPolicy(for service: ServiceDefinition) -> HealthCheckPolicy {
        var policy = globalPolicy
        
        // 根据服务类型调整策略
        switch service.healthCheck?.type {
        case .http:
            if let port = service.port {
                policy = HealthCheckPolicy(
                    checkType: .http(
                        endpoint: "http://127.0.0.1:\(port)\(service.healthCheck?.endpoint ?? "/health")",
                        expectedStatus: 200
                    ),
                    interval: policy.interval,
                    timeout: policy.timeout,
                    retryCount: policy.retryCount,
                    retryInterval: policy.retryInterval,
                    unhealthyPolicy: policy.unhealthyPolicy,
                    flappingThreshold: policy.flappingThreshold,
                    flappingWindow: policy.flappingWindow
                )
            }
        case .port:
            if let port = service.port {
                policy = HealthCheckPolicy(
                    checkType: .tcp(port: port),
                    interval: policy.interval,
                    timeout: policy.timeout,
                    retryCount: policy.retryCount,
                    retryInterval: policy.retryInterval,
                    unhealthyPolicy: policy.unhealthyPolicy,
                    flappingThreshold: policy.flappingThreshold,
                    flappingWindow: policy.flappingWindow
                )
            }
        case .process:
            policy = HealthCheckPolicy(
                checkType: .process(pid: nil),
                interval: policy.interval,
                timeout: policy.timeout,
                retryCount: policy.retryCount,
                retryInterval: policy.retryInterval,
                unhealthyPolicy: policy.unhealthyPolicy,
                flappingThreshold: policy.flappingThreshold,
                flappingWindow: policy.flappingWindow
            )
        default:
            break
        }
        
        return policy
    }
    
    private func handleStatusChange(_ change: HealthStatusChange) {
        monitorStatuses[change.serviceID] = change.to
        
        // 发布事件
        eventPublisher.send(.statusChanged(change))
        
        // 记录事件
        recordEvent(.statusChanged(change))
        
        // 同步到 UnifiedServiceState
        syncToUnifiedState(change)
        
        LogInfo("[HealthMonitorEngine] 服务 \(change.serviceName) 状态变更: \(change.from.displayName) -> \(change.to.displayName)")
    }
    
    private func handleCheckPerformed(serviceID: String, result: HealthCheckResult) {
        lastCheckResults[serviceID] = result
        eventPublisher.send(.checkPerformed(serviceID: serviceID, result: result))
    }
    
    private func handleUnhealthy(service: ServiceDefinition, severity: HealthSeverity, message: String) {
        eventPublisher.send(.unhealthyDetected(
            serviceID: service.id,
            severity: severity,
            message: message
        ))
        
        recordEvent(.unhealthyDetected(
            serviceID: service.id,
            severity: severity,
            message: message
        ))
        
        // 根据策略处理
        let policy = createPolicy(for: service)
        handleUnhealthyPolicy(service: service, policy: policy.unhealthyPolicy, severity: severity, message: message)
    }
    
    private func handleUnhealthyPolicy(
        service: ServiceDefinition,
        policy: UnhealthyPolicy,
        severity: HealthSeverity,
        message: String
    ) {
        switch policy {
        case .notifyOnly:
            notifyMainSession(service: service, severity: severity, message: message)
            
        case .autoRestart(let maxRetries, _):
            Task {
                await attemptAutoRestart(service: service, maxRetries: maxRetries)
            }
            
        case .aiDiagnosis:
            performAIDiagnosis(service: service)
            
        case .escalate(let agentID):
            escalateToAgent(service: service, agentID: agentID, issue: message)
            
        case .custom(let action):
            Task {
                await action(service)
            }
        }
    }
    
    private func notifyMainSession(service: ServiceDefinition, severity: HealthSeverity, message: String) {
        let notification: [String: Any] = [
            "type": "service_unhealthy",
            "service_id": service.id,
            "service_name": service.name,
            "severity": severity.rawValue,
            "message": message,
            "timestamp": Date()
        ]
        
        NotificationCenter.default.post(
            name: .healthMonitorAlert,
            object: nil,
            userInfo: notification
        )
    }
    
    private func attemptAutoRestart(service: ServiceDefinition, maxRetries: Int) async {
        guard let monitor = monitors[service.id] else { return }
        
        guard await monitor.canAttemptRestart() else {
            LogWarning("[HealthMonitorEngine] 服务 \(service.name) 重启次数已达上限")
            return
        }
        
        await monitor.recordRestartAttempt()
        
        let attempt = await { () -> Int in
            // 这里需要实现获取重启次数的逻辑
            return 1
        }()
        
        eventPublisher.send(.autoRestartInitiated(
            serviceID: service.id,
            attempt: attempt,
            maxRetries: maxRetries
        ))
        
        LogInfo("[HealthMonitorEngine] 尝试自动重启服务 \(service.name) (\(attempt)/\(maxRetries))")
        
        // 调用 ServiceManager 重启服务
        ServiceManager.shared.restartService(service)
        
        // 等待重启结果
        // 简化起见，这里不等待，实际应该监听状态变化
    }
    
    private func performAIDiagnosis(service: ServiceDefinition) {
        eventPublisher.send(.aiDiagnosisStarted(serviceID: service.id))
        
        // 触发 AI 诊断
        LogInfo("[HealthMonitorEngine] 触发 AI 诊断: \(service.name)")
        
        // 通知主会话
        NotificationCenter.default.post(
            name: .healthMonitorAIDiagnosis,
            object: nil,
            userInfo: [
                "service_id": service.id,
                "service_name": service.name
            ]
        )
    }
    
    private func escalateToAgent(service: ServiceDefinition, agentID: String, issue: String) {
        // 将问题升级到指定 Agent
        LogInfo("[HealthMonitorEngine] 升级问题到 Agent \(agentID): \(service.name) - \(issue)")
    }
    
    private func syncToUnifiedState(_ change: HealthStatusChange) {
        let status: ServiceRuntimeStatus
        switch change.to {
        case .healthy:
            status = .running
        case .unhealthy:
            status = .error
        case .recovering:
            status = .starting
        case .flapping:
            status = .error
        case .unknown:
            status = .unknown
        }
        
        UnifiedServiceState.shared.updateServiceState(
            serviceID: change.serviceID,
            status: status,
            source: .healthCheck,
            metadata: [
                "health_status": change.to.displayName,
                "details": change.details,
                "response_time": change.checkResult?.responseTimeMs?.description ?? ""
            ]
        )
    }
    
    private func recordEvent(_ event: HealthMonitorEvent) {
        let record = HealthEventRecord(
            id: UUID().uuidString,
            event: event,
            timestamp: Date()
        )
        
        recentEvents.insert(record, at: 0)
        
        if recentEvents.count > maxRecentEvents {
            recentEvents.removeLast(recentEvents.count - maxRecentEvents)
        }
    }
}

// MARK: - 扩展
extension ServiceHealthMonitor {
    func setCallbacks(
        onStatusChange: ((HealthStatusChange) -> Void)?,
        onCheckPerformed: ((HealthCheckResult) -> Void)?,
        onUnhealthy: ((HealthSeverity, String) -> Void)?
    ) {
        self.onStatusChange = onStatusChange
        self.onCheckPerformed = onCheckPerformed
        self.onUnhealthy = onUnhealthy
    }
}

// MARK: - 健康事件记录
struct HealthEventRecord: Identifiable {
    let id: String
    let event: HealthMonitorEvent
    let timestamp: Date
}

// MARK: - 通知名称
extension Notification.Name {
    static let healthMonitorAlert = Notification.Name("healthMonitorAlert")
    static let healthMonitorAIDiagnosis = Notification.Name("healthMonitorAIDiagnosis")
}
