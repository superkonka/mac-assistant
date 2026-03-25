//
//  SmartToolbar.swift
//  MacAssistant
//
//  智能工具栏 - 统一的微状态入口管理
//

import SwiftUI
import Combine

// MARK: - 工具栏入口类型

enum ToolbarEntryType: String, CaseIterable {
    case task = "任务"
    case service = "服务"
    case disk = "磁盘"
    case skills = "技能"
    
    var icon: String {
        switch self {
        case .task: return "list.bullet.rectangle"
        case .service: return "server.rack"
        case .disk: return "internaldrive"
        case .skills: return "sparkles"
        }
    }
    
    var activeIcon: String {
        switch self {
        case .task: return "list.bullet.rectangle.fill"
        case .service: return "server.rack.fill"
        case .disk: return "internaldrive.fill"
        case .skills: return "sparkles"
        }
    }
}

// MARK: - 入口状态

enum EntryState: Equatable {
    case idle
    case checking
    case active(count: Int)
    case warning(count: Int)
    case error(count: Int)
    
    var isIdle: Bool {
        if case .idle = self { return true }
        return false
    }
    
    var isChecking: Bool {
        if case .checking = self { return true }
        return false
    }
    
    var count: Int {
        switch self {
        case .active(let c), .warning(let c), .error(let c):
            return c
        default:
            return 0
        }
    }
}

// MARK: - 工具栏状态管理器

@MainActor
final class SmartToolbarState: ObservableObject {
    static let shared = SmartToolbarState()
    
    @Published var taskState: EntryState = .idle
    @Published var serviceState: EntryState = .idle
    @Published var diskState: EntryState = .idle
    @Published var skillsState: EntryState = .idle
    
    // 订阅管理
    private var cancellables = Set<AnyCancellable>()
    
    // 依赖管理器
    private let taskManager = UnifiedTaskManager.shared
    private let serviceManager = ServiceManager.shared
    
    private init() {
        setupSubscriptions()
        initialCheck()
    }
    
    // MARK: - 订阅设置
    
    private func setupSubscriptions() {
        // 订阅任务状态变化
        taskManager.$statistics
            .receive(on: DispatchQueue.main)
            .sink { [weak self] stats in
                self?.updateTaskState(stats: stats)
            }
            .store(in: &cancellables)
        
        // 订阅服务状态变化
        serviceManager.$services
            .receive(on: DispatchQueue.main)
            .sink { [weak self] services in
                self?.updateServiceState(services: services)
            }
            .store(in: &cancellables)
        
        serviceManager.$isOperating
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isOperating in
                if isOperating {
                    self?.serviceState = .checking
                }
            }
            .store(in: &cancellables)
        
        // 磁盘状态定期检查
        Timer.publish(every: 5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.checkDiskState()
            }
            .store(in: &cancellables)
        
        // AI 通知监听
        NotificationCenter.default.publisher(for: .init("AIStateChanged"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleAINotification(notification)
            }
            .store(in: &cancellables)
    }
    
    // MARK: - 初始检查
    
    private func initialCheck() {
        // 任务初始状态
        updateTaskState(stats: taskManager.statistics)
        
        // 服务初始状态
        updateServiceState(services: serviceManager.services)
        
        // 磁盘初始状态
        checkDiskState()
        
        // 技能初始状态（总是活跃，显示可用技能数）
        updateSkillsState()
    }
    
    // MARK: - 状态更新
    
    private func updateTaskState(stats: TaskStatistics) {
        let activeCount = stats.pending + stats.running + stats.failed
        
        if activeCount == 0 {
            taskState = .idle
        } else if stats.failed > 0 {
            taskState = .error(count: activeCount)
        } else if stats.running > 0 {
            taskState = .active(count: activeCount)
        } else {
            taskState = .warning(count: activeCount)
        }
    }
    
    private func updateServiceState(services: [ServiceStateSnapshot]) {
        guard !serviceManager.isOperating else { return }
        
        let runningCount = services.filter { $0.state == .running }.count
        let errorCount = services.filter { $0.state == .error }.count
        
        if errorCount > 0 {
            serviceState = .error(count: errorCount)
        } else if runningCount > 0 {
            serviceState = .active(count: runningCount)
        } else {
            serviceState = .idle
        }
    }
    
    private func checkDiskState() {
        // 简化的磁盘检查
        do {
            let fileURL = URL(fileURLWithPath: NSHomeDirectory())
            let values = try fileURL.resourceValues(forKeys: [.volumeAvailableCapacityKey])
            if let capacity = values.volumeAvailableCapacity {
                let gb = Double(capacity) / 1_000_000_000
                if gb < 5 {
                    diskState = .error(count: Int(gb))
                } else if gb < 20 {
                    diskState = .warning(count: Int(gb))
                } else {
                    diskState = .active(count: Int(gb))
                }
            }
        } catch {
            diskState = .idle
        }
    }
    
    private func updateSkillsState() {
        // 技能入口总是显示可用技能数量
        let skillCount = SkillCatalog.shared.skills.count
        skillsState = .active(count: skillCount)
    }
    
    // MARK: - AI 通知处理
    
    private func handleAINotification(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let type = userInfo["type"] as? String else { return }
        
        switch type {
        case "task":
            if let state = userInfo["state"] as? String {
                updateTaskStateFromAI(state)
            }
        case "service":
            if let state = userInfo["state"] as? String {
                updateServiceStateFromAI(state)
            }
        default:
            break
        }
    }
    
    private func updateTaskStateFromAI(_ state: String) {
        switch state {
        case "checking":
            taskState = .checking
        case "active":
            let count = taskManager.statistics.running + taskManager.statistics.pending
            taskState = .active(count: count)
        default:
            updateTaskState(stats: taskManager.statistics)
        }
    }
    
    private func updateServiceStateFromAI(_ state: String) {
        switch state {
        case "checking":
            serviceState = .checking
        case "active":
            let count = serviceManager.services.filter { $0.state == .running }.count
            serviceState = .active(count: count)
        default:
            updateServiceState(services: serviceManager.services)
        }
    }
    
    // MARK: - 公共方法
    
    func forceRefresh() {
        initialCheck()
    }
    
    func setChecking(_ type: ToolbarEntryType) {
        switch type {
        case .task:
            taskState = .checking
        case .service:
            serviceState = .checking
        case .disk:
            diskState = .checking
        case .skills:
            skillsState = .checking
        }
    }
}

// MARK: - 智能工具栏视图

struct SmartToolbar: View {
    @StateObject private var state = SmartToolbarState.shared
    
    var body: some View {
        HStack(spacing: 8) {
            Spacer()
            
            // 四个入口靠右排列
            EntryButton(
                type: .task,
                state: state.taskState
            ) {
                // 任务面板操作
            }
            
            EntryButton(
                type: .service,
                state: state.serviceState
            ) {
                // 服务面板操作
            }
            
            EntryButton(
                type: .disk,
                state: state.diskState
            ) {
                // 磁盘面板操作
            }
            
            EntryButton(
                type: .skills,
                state: state.skillsState
            ) {
                // 技能面板操作
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - 入口按钮

struct EntryButton: View {
    let type: ToolbarEntryType
    let state: EntryState
    let action: () -> Void
    
    @State private var isHovered = false
    @State private var rotationAngle: Double = 0
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                // 图标
                ZStack {
                    Image(systemName: iconName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(foregroundColor)
                        .rotationEffect(.degrees(state.isChecking ? rotationAngle : 0))
                        .animation(
                            state.isChecking 
                                ? .linear(duration: 2).repeatForever(autoreverses: false)
                                : .default,
                            value: rotationAngle
                        )
                        .onAppear {
                            if state.isChecking {
                                rotationAngle = 360
                            }
                        }
                        .onChange(of: state.isChecking) { isChecking in
                            rotationAngle = isChecking ? 360 : 0
                        }
                }
                .frame(width: 16, height: 16)
                
                // 标签
                Text(type.rawValue)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                
                // 徽章或脉冲
                if state.isChecking {
                    PulsingDot(color: foregroundColor)
                } else if state.count > 0 {
                    SmartBadge(count: state.count, state: state)
                }
            }
            .foregroundColor(foregroundColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(backgroundColor)
                    .shadow(
                        color: shadowColor.opacity(isHovered ? 0.2 : 0.1),
                        radius: isHovered ? 3 : 2,
                        x: 0,
                        y: isHovered ? 1 : 0.5
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(borderColor.opacity(0.3), lineWidth: 1)
            )
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isHovered)
        }
        .buttonStyle(.plain)
        .help(helpText)
        .onHover { hovering in
            isHovered = hovering
        }
    }
    
    // MARK: - 视觉属性
    
    private var iconName: String {
        switch state {
        case .active, .warning, .error:
            return type.activeIcon
        default:
            return type.icon
        }
    }
    
    private var foregroundColor: Color {
        switch state {
        case .idle, .checking:
            return .primary
        case .active:
            return .white
        case .warning:
            return .orange
        case .error:
            return .white
        }
    }
    
    private var backgroundColor: Color {
        switch state {
        case .idle:
            return Color.secondary.opacity(0.1)
        case .checking:
            return Color.secondary.opacity(0.08)
        case .active:
            return Color.blue
        case .warning:
            return Color.orange.opacity(0.15)
        case .error:
            return Color.red.opacity(0.9)
        }
    }
    
    private var borderColor: Color {
        switch state {
        case .idle, .checking:
            return .secondary
        case .active:
            return .blue
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }
    
    private var shadowColor: Color {
        switch state {
        case .idle, .checking:
            return .gray
        case .active:
            return .blue
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }
    
    private var helpText: String {
        switch state {
        case .idle:
            return "\(type.rawValue) - 无活动"
        case .checking:
            return "\(type.rawValue) - 检查中..."
        case .active(let count):
            return "\(type.rawValue) - \(count) 个活动"
        case .warning(let count):
            return "\(type.rawValue) - \(count) 个警告"
        case .error(let count):
            return "\(type.rawValue) - \(count) 个错误"
        }
    }
}

// MARK: - 智能徽章

struct SmartBadge: View {
    let count: Int
    let state: EntryState
    
    var body: some View {
        Text("\(min(count, 99))")
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(foregroundColor)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                Capsule(style: .continuous)
                    .fill(backgroundColor)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(strokeColor.opacity(0.3), lineWidth: 0.5)
            )
    }
    
    private var foregroundColor: Color {
        switch state {
        case .active, .error:
            return .white
        case .warning:
            return .orange
        default:
            return .primary
        }
    }
    
    private var backgroundColor: Color {
        switch state {
        case .active:
            return Color.white.opacity(0.3)
        case .warning:
            return Color.orange.opacity(0.2)
        case .error:
            return Color.white.opacity(0.2)
        default:
            return Color.secondary.opacity(0.15)
        }
    }
    
    private var strokeColor: Color {
        switch state {
        case .active:
            return .white
        case .warning:
            return .orange
        case .error:
            return .white
        default:
            return .secondary
        }
    }
}



// MARK: - 简化版 ChatView 工具栏

struct ChatTopBar: View {
    @StateObject private var orchestrator = AgentOrchestrator.shared
    @State private var showingAgentList = false
    @State private var showingSkills = false
    
    var body: some View {
        HStack(spacing: 0) {
            // 左侧：Agent 选择器
            HStack(spacing: 8) {
                Button(action: { showingAgentList = true }) {
                    HStack(spacing: 4) {
                        Text(orchestrator.currentAgent?.emoji ?? "🤖")
                        Text(orchestrator.currentAgent?.name ?? "选择 Agent")
                            .font(.system(size: 13, weight: .medium))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9))
                    }
                    .foregroundColor(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.secondary.opacity(0.12))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }
            
            // 中间： spacer
            Spacer()
            
            // 右侧：四个入口
            SmartToolbar()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(AppColors.controlBackground)
        .sheet(isPresented: $showingAgentList) {
            AgentDashboardView()
        }
    }
}

// MARK: - Preview

#Preview("SmartToolbar") {
    VStack(spacing: 20) {
        SmartToolbar()
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
        
        // 不同状态展示
        HStack(spacing: 12) {
            EntryButton(type: .task, state: .idle) {}
            EntryButton(type: .task, state: .checking) {}
            EntryButton(type: .task, state: .active(count: 5)) {}
            EntryButton(type: .task, state: .error(count: 3)) {}
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }
    .padding()
}
