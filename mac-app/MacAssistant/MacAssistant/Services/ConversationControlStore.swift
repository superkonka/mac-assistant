import Foundation
import Combine

/// 会话拓扑信息
struct ConversationTopology {
    let mainSessionId: UUID
    let mainSessionKey: String
    let mainSessionLabel: String?
    let activeTaskSessions: [AgentTaskSession]
    let currentGatewaySessionKey: String?
    
    init(
        mainSessionId: UUID = UUID(),
        mainSessionKey: String = "",
        mainSessionLabel: String? = nil,
        activeTaskSessions: [AgentTaskSession] = [],
        currentGatewaySessionKey: String? = nil
    ) {
        self.mainSessionId = mainSessionId
        self.mainSessionKey = mainSessionKey
        self.mainSessionLabel = mainSessionLabel
        self.activeTaskSessions = activeTaskSessions
        self.currentGatewaySessionKey = currentGatewaySessionKey
    }
    
    func taskSessionKey(for sessionID: String) -> String {
        return "task-\(sessionID)-\(mainSessionId.uuidString.prefix(8))"
    }
}

/// 会话控制存储，管理活跃会话状态
class ConversationControlStore: ObservableObject {
    static let shared = ConversationControlStore()
    
    @Published private(set) var activeConversationIds: Set<UUID> = []
    @Published private(set) var suspendedConversations: [UUID: SuspendedConversationState] = [:]
    @Published private(set) var currentMainSessionId: UUID?
    @Published private(set) var currentMainSessionKey: String?
    @Published private(set) var currentMainSessionLabel: String?
    @Published private(set) var taskSessions: [AgentTaskSession] = []
    @Published private(set) var gatewaySessionKey: String?
    
    private init() {}
    
    /// 获取当前拓扑
    func currentTopology() -> ConversationTopology {
        return ConversationTopology(
            mainSessionId: currentMainSessionId ?? UUID(),
            mainSessionKey: currentMainSessionKey ?? "",
            mainSessionLabel: currentMainSessionLabel,
            activeTaskSessions: taskSessions.filter { $0.dismissedAt == nil },
            currentGatewaySessionKey: gatewaySessionKey
        )
    }
    
    /// 重置会话
    func resetConversation() {
        currentMainSessionId = UUID()
        currentMainSessionKey = nil
        currentMainSessionLabel = nil
        taskSessions.removeAll()
        gatewaySessionKey = nil
        activeConversationIds.removeAll()
        suspendedConversations.removeAll()
    }
    
    /// 设置主会话信息
    func setMainSession(id: UUID, key: String, label: String?) {
        currentMainSessionId = id
        currentMainSessionKey = key
        currentMainSessionLabel = label
    }
    
    /// 设置主会话ID
    func setMainSessionId(_ id: UUID) {
        currentMainSessionId = id
    }
    
    /// 设置 Gateway Session Key
    func setGatewaySessionKey(_ key: String?) {
        gatewaySessionKey = key
    }
    
    /// 添加任务会话
    func addTaskSession(_ session: AgentTaskSession) {
        taskSessions.append(session)
    }
    
    /// 更新任务会话
    func updateTaskSession(_ session: AgentTaskSession) {
        if let index = taskSessions.firstIndex(where: { $0.id == session.id }) {
            taskSessions[index] = session
        }
    }
    
    /// 标记会话为活跃
    func markActive(_ id: UUID) {
        activeConversationIds.insert(id)
    }
    
    /// 标记会话为非活跃
    func markInactive(_ id: UUID) {
        activeConversationIds.remove(id)
    }
    
    /// 检查会话是否活跃
    func isActive(_ id: UUID) -> Bool {
        activeConversationIds.contains(id)
    }
    
    /// 挂起会话
    func suspend(_ id: UUID, state: SuspendedConversationState) {
        suspendedConversations[id] = state
        markInactive(id)
    }
    
    /// 恢复会话
    func resume(_ id: UUID) -> SuspendedConversationState? {
        let state = suspendedConversations.removeValue(forKey: id)
        if state != nil {
            markActive(id)
        }
        return state
    }
    
    /// 清除所有状态
    func clearAll() {
        activeConversationIds.removeAll()
        suspendedConversations.removeAll()
        taskSessions.removeAll()
        currentMainSessionId = nil
        currentMainSessionKey = nil
        currentMainSessionLabel = nil
        gatewaySessionKey = nil
    }
}

/// 挂起的会话状态
struct SuspendedConversationState {
    let lastMessageId: UUID?
    let contextSnapshot: ConversationContextSnapshot?
    let timestamp: Date
}

/// 会话上下文快照
struct ConversationContextSnapshot {
    let messageCount: Int
    let lastUserMessage: String?
    let accumulatedToolResults: [ToolResult]
}

/// 工具结果
struct ToolResult {
    let toolName: String
    let result: String
    let timestamp: Date
}
