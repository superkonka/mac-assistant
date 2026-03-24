//
//  HealthMonitorConfig.swift
//  MacAssistant
//
//  健康监控配置和设置
//

import Foundation
import SwiftUI

// MARK: - 健康监控配置
struct HealthMonitorConfig: Codable, Equatable {
    var isEnabled: Bool = false
    var globalPolicy: HealthCheckPolicyConfig = .default
    var servicePolicies: [String: HealthCheckPolicyConfig] = [:]  // 服务特定的策略
    var notificationSettings: NotificationSettings = .default
    var aiDiagnosisSettings: AIDiagnosisSettings = .default
    
    static let `default` = HealthMonitorConfig()
}

// MARK: - 健康检查策略配置（可序列化版本）
struct HealthCheckPolicyConfig: Codable, Equatable {
    var checkType: HealthCheckTypeConfig
    var interval: TimeInterval
    var timeout: TimeInterval
    var retryCount: Int
    var retryInterval: TimeInterval
    var unhealthyPolicy: UnhealthyPolicyConfig
    var flappingThreshold: Int
    var flappingWindow: TimeInterval
    
    static let `default` = HealthCheckPolicyConfig(
        checkType: .tcp(port: 0),
        interval: 30,
        timeout: 10,
        retryCount: 3,
        retryInterval: 5,
        unhealthyPolicy: .notifyOnly,
        flappingThreshold: 5,
        flappingWindow: 600
    )
    
    /// 转换为运行时策略
    func toPolicy(for service: ServiceDefinition) -> HealthCheckPolicy {
        let checkType: HealthCheckType
        switch self.checkType {
        case .http(let endpoint, let expectedStatus):
            checkType = .http(endpoint: endpoint, expectedStatus: expectedStatus)
        case .tcp(let port):
            let actualPort = port == 0 ? service.port : port
            checkType = .tcp(port: actualPort ?? 0)
        case .process:
            checkType = .process(pid: nil)
        }
        
        let unhealthyPolicy: UnhealthyPolicy
        switch self.unhealthyPolicy {
        case .notifyOnly:
            unhealthyPolicy = .notifyOnly
        case .autoRestart(let maxRetries, let cooldown):
            unhealthyPolicy = .autoRestart(maxRetries: maxRetries, cooldown: cooldown)
        case .aiDiagnosis:
            unhealthyPolicy = .aiDiagnosis
        case .escalate(let agentID):
            unhealthyPolicy = .escalate(to: agentID)
        }
        
        return HealthCheckPolicy(
            checkType: checkType,
            interval: interval,
            timeout: timeout,
            retryCount: retryCount,
            retryInterval: retryInterval,
            unhealthyPolicy: unhealthyPolicy,
            flappingThreshold: flappingThreshold,
            flappingWindow: flappingWindow
        )
    }
}

enum HealthCheckTypeConfig: Codable, Equatable {
    case http(endpoint: String, expectedStatus: Int)
    case tcp(port: Int)
    case process
}

enum UnhealthyPolicyConfig: Codable, Equatable, Hashable {
    case notifyOnly
    case autoRestart(maxRetries: Int, cooldown: TimeInterval)
    case aiDiagnosis
    case escalate(to: String)
}

// MARK: - 通知设置
struct NotificationSettings: Codable, Equatable {
    var notifyOnUnhealthy: Bool = true
    var notifyOnRecovery: Bool = true
    var notifyOnFlapping: Bool = true
    var notifyOnAutoRestart: Bool = true
    var showInMainChat: Bool = true
    var showBanner: Bool = true
    var playSound: Bool = false
    
    static let `default` = NotificationSettings()
}

// MARK: - AI 诊断设置
struct AIDiagnosisSettings: Codable, Equatable {
    var isEnabled: Bool = true
    var autoTriggerOnSeverity: HealthSeverity = .error
    var includeLogs: Bool = true
    var maxLogLines: Int = 100
    var timeout: TimeInterval = 60
    
    static let `default` = AIDiagnosisSettings()
}

// MARK: - 健康监控设置存储
@MainActor
final class HealthMonitorSettingsStore: ObservableObject {
    static let shared = HealthMonitorSettingsStore()
    
    @Published var config: HealthMonitorConfig = .default
    
    private let configKey = "health_monitor_config"
    
    private init() {
        loadConfig()
        syncToEngine()
    }
    
    /// 加载配置
    private func loadConfig() {
        guard let data = UserDefaults.standard.data(forKey: configKey),
              let config = try? JSONDecoder().decode(HealthMonitorConfig.self, from: data) else {
            self.config = .default
            return
        }
        self.config = config
    }
    
    /// 保存配置
    func saveConfig() {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: configKey)
        }
        syncToEngine()
    }
    
    /// 同步到引擎
    private func syncToEngine() {
        HealthMonitorEngine.shared.isEnabled = config.isEnabled
        HealthMonitorEngine.shared.globalPolicy = config.globalPolicy.toPolicy(
            for: ServiceDefinition(
                id: "default",
                name: "Default",
                category: .other,
                type: .process,
                description: nil,
                path: nil,
                port: nil,
                startCommand: nil,
                stopCommand: nil,
                healthCheck: nil,
                env: nil,
                autoStart: false,
                dependencies: nil
            )
        )
    }
    
    /// 更新全局策略
    func updateGlobalPolicy(_ policy: HealthCheckPolicyConfig) {
        config.globalPolicy = policy
        saveConfig()
    }
    
    /// 更新服务特定策略
    func updateServicePolicy(serviceID: String, policy: HealthCheckPolicyConfig) {
        config.servicePolicies[serviceID] = policy
        saveConfig()
    }
    
    /// 获取服务策略（优先使用特定策略，否则使用全局）
    func policy(for serviceID: String) -> HealthCheckPolicyConfig {
        return config.servicePolicies[serviceID] ?? config.globalPolicy
    }
    
    /// 启用/禁用健康监控
    func setEnabled(_ enabled: Bool) {
        config.isEnabled = enabled
        saveConfig()
        
        if enabled {
            HealthMonitorEngine.shared.startGlobalMonitoring()
        } else {
            HealthMonitorEngine.shared.stopGlobalMonitoring()
        }
    }
}

// MARK: - 健康监控设置视图
struct HealthMonitorSettingsView: View {
    @StateObject private var settings = HealthMonitorSettingsStore.shared
    @StateObject private var engine = HealthMonitorEngine.shared
    @State private var showingAdvancedSettings = false
    
    var body: some View {
        Form {
            // MARK: - 总开关
            Section {
                Toggle(isOn: $settings.config.isEnabled) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("启用健康监控")
                            .font(.system(size: 14, weight: .medium))
                        Text("自动检测服务健康状态并处理异常")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: settings.config.isEnabled) { newValue in
                    settings.setEnabled(newValue)
                }
            } header: {
                Text("总开关")
            }
            
            if settings.config.isEnabled {
                // MARK: - 监控状态
                Section {
                    HStack {
                        Text("当前监控服务数")
                            .font(.system(size: 13))
                        Spacer()
                        Text("\(engine.monitorCount)")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    
                    HStack {
                        Text("健康服务")
                            .font(.system(size: 13))
                        Spacer()
                        let healthyCount = engine.monitorStatuses.values.filter { $0 == .healthy }.count
                        Text("\(healthyCount)")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.green)
                    }
                    
                    HStack {
                        Text("异常服务")
                            .font(.system(size: 13))
                        Spacer()
                        let unhealthyCount = engine.monitorStatuses.values.filter {
                            if case .unhealthy = $0 { return true }
                            return false
                        }.count
                        Text("\(unhealthyCount)")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(unhealthyCount > 0 ? .red : .secondary)
                    }
                } header: {
                    Text("监控状态")
                }
                
                // MARK: - 全局策略
                Section {
                    NavigationLink(destination: PolicyConfigView(
                        policy: $settings.config.globalPolicy,
                        title: "全局策略"
                    )) {
                        HStack {
                            Text("健康检查策略")
                                .font(.system(size: 13))
                            Spacer()
                            Text(policySummary(settings.config.globalPolicy))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("全局配置")
                }
                
                // MARK: - 通知设置
                Section {
                    Toggle(isOn: $settings.config.notificationSettings.notifyOnUnhealthy) {
                        Text("服务不健康时通知")
                            .font(.system(size: 13))
                    }
                    
                    Toggle(isOn: $settings.config.notificationSettings.notifyOnRecovery) {
                        Text("服务恢复时通知")
                            .font(.system(size: 13))
                    }
                    
                    Toggle(isOn: $settings.config.notificationSettings.showInMainChat) {
                        Text("在主会话中显示通知")
                            .font(.system(size: 13))
                    }
                    
                    Toggle(isOn: $settings.config.notificationSettings.showBanner) {
                        Text("显示横幅通知")
                            .font(.system(size: 13))
                    }
                } header: {
                    Text("通知设置")
                }
                
                // MARK: - AI 诊断
                Section {
                    Toggle(isOn: $settings.config.aiDiagnosisSettings.isEnabled) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("启用 AI 诊断")
                                .font(.system(size: 13))
                            Text("服务异常时自动调用 AI 分析原因")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    if settings.config.aiDiagnosisSettings.isEnabled {
                        Picker("自动触发级别", selection: $settings.config.aiDiagnosisSettings.autoTriggerOnSeverity) {
                            ForEach([HealthSeverity.warning, .error, .critical], id: \.self) { severity in
                                Text(severity.displayName).tag(severity)
                            }
                        }
                        .font(.system(size: 13))
                    }
                } header: {
                    Text("AI 诊断")
                }
                
                // MARK: - 最近事件
                if !engine.recentEvents.isEmpty {
                    Section {
                        ForEach(engine.recentEvents.prefix(5)) { event in
                            EventRow(event: event)
                        }
                    } header: {
                        Text("最近事件")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("健康监控")
    }
    
    private func policySummary(_ policy: HealthCheckPolicyConfig) -> String {
        switch policy.unhealthyPolicy {
        case .notifyOnly:
            return "仅通知"
        case .autoRestart:
            return "自动重启"
        case .aiDiagnosis:
            return "AI 诊断"
        case .escalate:
            return "升级处理"
        }
    }
}

// MARK: - 策略配置视图
struct PolicyConfigView: View {
    @Binding var policy: HealthCheckPolicyConfig
    let title: String
    
    var body: some View {
        Form {
            Section {
                HStack {
                    Text("检查间隔")
                        .font(.system(size: 13))
                    Spacer()
                    TextField("秒", value: $policy.interval, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }
                
                HStack {
                    Text("超时时间")
                        .font(.system(size: 13))
                    Spacer()
                    TextField("秒", value: $policy.timeout, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }
                
                HStack {
                    Text("失败重试次数")
                        .font(.system(size: 13))
                    Spacer()
                    Stepper("\(policy.retryCount)", value: $policy.retryCount, in: 0...10)
                        .frame(width: 120)
                }
            } header: {
                Text("检查参数")
            }
            
            Section {
                Picker("不健康处理策略", selection: $policy.unhealthyPolicy) {
                    Text("仅通知").tag(UnhealthyPolicyConfig.notifyOnly)
                    Text("自动重启").tag(UnhealthyPolicyConfig.autoRestart(maxRetries: 3, cooldown: 300))
                    Text("AI 诊断").tag(UnhealthyPolicyConfig.aiDiagnosis)
                }
                .pickerStyle(.segmented)
                
                if case .autoRestart = policy.unhealthyPolicy {
                    HStack {
                        Text("最大重启次数")
                            .font(.system(size: 13))
                        Spacer()
                        Text("3")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    
                    HStack {
                        Text("重启冷却时间")
                            .font(.system(size: 13))
                        Spacer()
                        Text("5分钟")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("处理策略")
            }
            
            Section {
                HStack {
                    Text("震荡检测阈值")
                        .font(.system(size: 13))
                    Spacer()
                    Text("\(policy.flappingThreshold) 次/10分钟")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("高级")
            } footer: {
                Text("频繁状态变更会被识别为状态震荡")
                    .font(.system(size: 10))
            }
        }
        .formStyle(.grouped)
        .navigationTitle(title)
    }
}

// MARK: - 事件行视图
struct EventRow: View {
    let event: HealthEventRecord
    
    var body: some View {
        HStack(spacing: 8) {
            eventIcon
                .frame(width: 20)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(eventTitle)
                    .font(.system(size: 12))
                Text(eventTime)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
        }
        .padding(.vertical, 2)
    }
    
    private var eventIcon: some View {
        switch event.event {
        case .statusChanged:
            return Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.blue)
        case .unhealthyDetected:
            return Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .autoRestartInitiated:
            return Image(systemName: "arrow.clockwise")
                .foregroundStyle(.yellow)
        case .autoRestartSucceeded:
            return Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .autoRestartFailed:
            return Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        case .aiDiagnosisStarted:
            return Image(systemName: "brain.head.profile")
                .foregroundStyle(.purple)
        case .aiDiagnosisCompleted:
            return Image(systemName: "checkmark.shield.fill")
                .foregroundStyle(.green)
        case .flappingDetected:
            return Image(systemName: "waveform.path.ecg")
                .foregroundStyle(.red)
        default:
            return Image(systemName: "circle.fill")
                .foregroundStyle(.gray)
        }
    }
    
    private var eventTitle: String {
        switch event.event {
        case .statusChanged(let change):
            return "\(change.serviceName): \(change.from.displayName) → \(change.to.displayName)"
        case .unhealthyDetected(let serviceID, let severity, let message):
            return "不健康: \(message.prefix(20))..."
        case .autoRestartInitiated(let serviceID, let attempt, let maxRetries):
            return "自动重启 (\(attempt)/\(maxRetries))"
        case .autoRestartSucceeded:
            return "重启成功"
        case .autoRestartFailed:
            return "重启失败"
        case .aiDiagnosisStarted:
            return "AI 诊断开始"
        case .aiDiagnosisCompleted:
            return "AI 诊断完成"
        case .flappingDetected:
            return "状态震荡检测"
        default:
            return "未知事件"
        }
    }
    
    private var eventTime: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: event.timestamp, relativeTo: Date())
    }
}

// MARK: - HealthSeverity 支持 Picker
extension HealthSeverity: Identifiable {
    var id: String { rawValue }
}
