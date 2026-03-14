import Foundation

/// 组装的会话上下文，用于传递完整的对话请求信息
struct AssembledConversationContext {
    let id: UUID
    let userMessage: String
    let attachedImages: [AttachedImage]
    let skills: [String]
    let preferredAgentId: UUID?
    let mode: ConversationMode
    let contextEnrichment: ContextEnrichment?
    let memoryRecall: MemoryRecallContext?
    let transcriptRepair: TranscriptRepairContext?
    let envelope: RequestEnvelope
    let text: String
    let images: [String]
    let sessionTopology: ConversationTopologySnapshot
    
    init(
        id: UUID = UUID(),
        userMessage: String,
        attachedImages: [AttachedImage] = [],
        skills: [String] = [],
        preferredAgentId: UUID? = nil,
        mode: ConversationMode = .standard,
        contextEnrichment: ContextEnrichment? = nil,
        memoryRecall: MemoryRecallContext? = nil,
        transcriptRepair: TranscriptRepairContext? = nil,
        envelope: RequestEnvelope? = nil,
        text: String? = nil,
        images: [String]? = nil,
        sessionTopology: ConversationTopologySnapshot? = nil
    ) {
        self.id = id
        self.userMessage = userMessage
        self.attachedImages = attachedImages
        self.skills = skills
        self.preferredAgentId = preferredAgentId
        self.mode = mode
        self.contextEnrichment = contextEnrichment
        self.memoryRecall = memoryRecall
        self.transcriptRepair = transcriptRepair
        self.envelope = envelope ?? RequestEnvelope(
            originalText: userMessage,
            images: attachedImages.map { $0.path },
            currentAgent: nil,
            needsInitialSetup: false,
            lastMessage: nil,
            creationFlowActive: false,
            resumableTaskSessionID: nil,
            activeWorkflowDesignContext: nil
        )
        self.text = text ?? userMessage
        self.images = images ?? attachedImages.map { $0.path }
        self.sessionTopology = sessionTopology ?? ConversationTopologySnapshot()
    }
}

/// 会话拓扑快照
struct ConversationTopologySnapshot {
    let mainSessionKey: String
    let mainSessionLabel: String?
    let activeTaskSessionKeys: [String]
    
    init(
        mainSessionKey: String = "",
        mainSessionLabel: String? = nil,
        activeTaskSessionKeys: [String] = []
    ) {
        self.mainSessionKey = mainSessionKey
        self.mainSessionLabel = mainSessionLabel
        self.activeTaskSessionKeys = activeTaskSessionKeys
    }
}

/// 附加图片
struct AttachedImage {
    let path: String
    let mimeType: String
    let description: String?
}

/// 会话模式
enum ConversationMode {
    case standard
    case planning
    case sideTask
    case memoryRecall
    case transcriptRepair
}

/// 上下文增强
struct ContextEnrichment {
    let webSearchResults: [WebSearchResult]?
    let fileContext: [FileContext]?
    let systemState: SystemStateContext?
}

/// 记忆回想上下文
struct MemoryRecallContext {
    let relevantSessionIds: [UUID]
    let preludeSummary: String?
    let keyFacts: [String]
}

/// 转录修复上下文
struct TranscriptRepairContext {
    let originalTranscriptId: UUID
    let repairType: TranscriptRepairType
    let correctionNotes: String
}

/// 转录修复类型
enum TranscriptRepairType {
    case missingToolResults
    case truncatedResponse
    case contextGap
    case userCorrection
}

/// 网页搜索结果
struct WebSearchResult {
    let title: String
    let url: String
    let snippet: String
}

/// 文件上下文
struct FileContext {
    let path: String
    let content: String
    let isDirectory: Bool
}

/// 系统状态上下文
struct SystemStateContext {
    let activeApps: [String]
    let clipboardContent: String?
    let recentFiles: [String]
}
