//
//  MemoryWriter.swift
//  MacAssistant
//
//  自动保存对话记忆到 memory/ 目录
//

import Foundation

/// 记忆条目
struct MemoryEntry: Codable {
    let id: String
    let timestamp: Date
    let category: MemoryCategory
    let title: String
    let content: String
    let sourceConversation: String?
    let tags: [String]
    
    enum MemoryCategory: String, Codable, CaseIterable {
        case userProfile = "user-profile"
        case teamInfo = "team-info"
        case projectInfo = "project-info"
        case preferences = "preferences"
        case todo = "todo"
        case context = "context"
        case general = "general"
        
        var displayName: String {
            switch self {
            case .userProfile: return "用户档案"
            case .teamInfo: return "团队信息"
            case .projectInfo: return "项目信息"
            case .preferences: return "偏好设置"
            case .todo: return "待办事项"
            case .context: return "上下文"
            case .general: return "一般信息"
            }
        }
        
        var icon: String {
            switch self {
            case .userProfile: return "person.fill"
            case .teamInfo: return "person.2.fill"
            case .projectInfo: return "folder.fill"
            case .preferences: return "gearshape.fill"
            case .todo: return "checklist"
            case .context: return "context"
            case .general: return "doc.text.fill"
            }
        }
    }
}

/// 记忆写入器 - 自动保存对话中的重要信息
actor MemoryWriter {
    static let shared = MemoryWriter()
    
    private let fileManager = FileManager.default
    private let maxEntriesPerFile = 50
    private let autoSaveDelay: TimeInterval = 2.0
    
    private var pendingEntries: [MemoryEntry] = []
    private var saveTask: Task<Void, Never>?
    
    // MARK: - 公共接口
    
    /// 立即保存一条记忆
    func saveEntry(_ entry: MemoryEntry) async throws {
        try await writeEntryToFile(entry)
        LogInfo("Memory saved: \(entry.title) [\(entry.category.displayName)]")
    }
    
    /// 延迟批量保存（用于自动保存）
    func queueEntry(_ entry: MemoryEntry) {
        pendingEntries.append(entry)
        
        // 取消之前的保存任务
        saveTask?.cancel()
        
        // 创建新的延迟保存任务
        saveTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(autoSaveDelay * 1_000_000_000))
            
            guard !Task.isCancelled else { return }
            
            let entriesToSave = pendingEntries
            pendingEntries.removeAll()
            
            for entry in entriesToSave {
                try? await writeEntryToFile(entry)
            }
            
            if !entriesToSave.isEmpty {
                LogInfo("Memory batch saved: \(entriesToSave.count) entries")
            }
        }
    }
    
    /// 从对话内容自动提取并保存记忆
    func autoSaveFromConversation(
        userMessage: String,
        assistantResponse: String,
        conversationId: String? = nil
    ) async {
        // 检查是否包含值得记忆的信息
        guard shouldRemember(userMessage, assistantResponse) else {
            return
        }
        
        // 提取关键信息
        if let entry = extractMemoryEntry(
            userMessage: userMessage,
            assistantResponse: assistantResponse,
            conversationId: conversationId
        ) {
            queueEntry(entry)
        }
    }
    
    /// 获取所有记忆文件列表
    func listMemoryFiles() async throws -> [URL] {
        let memoryDir = try memoryDirectory()
        let contents = try fileManager.contentsOfDirectory(
            at: memoryDir,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        )
        return contents.filter { $0.pathExtension == "md" }
            .sorted { url1, url2 in
                let date1 = (try? url1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
                let date2 = (try? url2.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
                return date1 > date2
            }
    }
    
    /// 读取记忆文件内容
    func readMemoryFile(_ url: URL) async throws -> String {
        return try String(contentsOf: url, encoding: .utf8)
    }
    
    /// 删除记忆文件
    func deleteMemoryFile(_ url: URL) async throws {
        try fileManager.removeItem(at: url)
    }
    
    // MARK: - 私有方法
    
    private func shouldRemember(_ userMessage: String, _ assistantResponse: String) -> Bool {
        let combined = (userMessage + " " + assistantResponse).lowercased()
        
        // 记忆触发关键词
        let memorySignals = [
            "我是", "我叫", "我负责", "我的团队", "我们团队",
            "项目名称", "业务线", "负责", "成员", "角色",
            "偏好", "习惯", "喜欢", "不喜欢",
            "待办", "todo", "任务", "计划",
            "请记住", "记下来", "保存"
        ]
        
        return memorySignals.contains { combined.contains($0) }
    }
    
    private func extractMemoryEntry(
        userMessage: String,
        assistantResponse: String,
        conversationId: String?
    ) -> MemoryEntry? {
        let combined = userMessage + " " + assistantResponse
        let lowercased = combined.lowercased()
        
        // 确定类别
        let category: MemoryEntry.MemoryCategory
        if lowercased.contains("团队") || lowercased.contains("成员") {
            category = .teamInfo
        } else if lowercased.contains("项目") || lowercased.contains("业务") {
            category = .projectInfo
        } else if lowercased.contains("我是") || lowercased.contains("我叫") {
            category = .userProfile
        } else if lowercased.contains("偏好") || lowercased.contains("喜欢") {
            category = .preferences
        } else if lowercased.contains("待办") || lowercased.contains("todo") {
            category = .todo
        } else {
            category = .general
        }
        
        // 生成标题
        let title = generateTitle(for: category, from: userMessage)
        
        // 生成内容摘要
        let content = generateContentSummary(
            userMessage: userMessage,
            assistantResponse: assistantResponse
        )
        
        // 提取标签
        let tags = extractTags(from: combined)
        
        return MemoryEntry(
            id: UUID().uuidString,
            timestamp: Date(),
            category: category,
            title: title,
            content: content,
            sourceConversation: conversationId,
            tags: tags
        )
    }
    
    private func generateTitle(for category: MemoryEntry.MemoryCategory, from message: String) -> String {
        let lines = message.components(separatedBy: .newlines)
        let firstLine = lines.first?.trimmingCharacters(in: .whitespaces) ?? ""
        
        // 提取关键短语作为标题
        if firstLine.count > 5 && firstLine.count < 50 {
            return firstLine
        }
        
        // 根据类别生成默认标题
        let dateStr = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none)
        return "\(category.displayName) - \(dateStr)"
    }
    
    private func generateContentSummary(userMessage: String, assistantResponse: String) -> String {
        var parts: [String] = []
        
        // 用户输入
        let trimmedUser = userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedUser.isEmpty {
            parts.append("**用户**: \(trimmedUser)")
        }
        
        // AI 回复（取前200字符）
        let trimmedAssistant = assistantResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        let shortResponse = trimmedAssistant.count > 200
            ? String(trimmedAssistant.prefix(200)) + "..."
            : trimmedAssistant
        if !shortResponse.isEmpty {
            parts.append("**AI回复**: \(shortResponse)")
        }
        
        return parts.joined(separator: "\n\n")
    }
    
    private func extractTags(from text: String) -> [String] {
        var tags: [String] = []
        let lowercased = text.lowercased()
        
        // 提取关键标签
        let tagMappings: [(keyword: String, tag: String)] = [
            ("团队", "团队"),
            ("项目", "项目"),
            ("代码", "代码"),
            ("设计", "设计"),
            ("会议", "会议"),
            ("需求", "需求"),
            ("bug", "Bug"),
            ("待办", "待办"),
            ("重要", "重要"),
            ("紧急", "紧急")
        ]
        
        for (keyword, tag) in tagMappings {
            if lowercased.contains(keyword) && !tags.contains(tag) {
                tags.append(tag)
            }
        }
        
        return tags
    }
    
    private func writeEntryToFile(_ entry: MemoryEntry) async throws {
        let memoryDir = try memoryDirectory()
        
        // 按类别和日期组织文件
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM"
        let monthKey = dateFormatter.string(from: entry.timestamp)
        
        let fileName = "\(entry.category.rawValue)-\(monthKey).md"
        let fileURL = memoryDir.appendingPathComponent(fileName)
        
        // 格式化条目为 Markdown
        let entryMarkdown = formatEntryAsMarkdown(entry)
        
        // 追加或创建文件
        if fileManager.fileExists(atPath: fileURL.path) {
            let existingContent = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
            let newContent = entryMarkdown + "\n---\n\n" + existingContent
            try newContent.write(to: fileURL, atomically: true, encoding: .utf8)
        } else {
            let header = "# \(entry.category.displayName)\n\n> 自动生成于 \(monthKey)\n\n---\n\n"
            let fullContent = header + entryMarkdown + "\n---\n\n"
            try fullContent.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }
    
    private func formatEntryAsMarkdown(_ entry: MemoryEntry) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        let dateStr = dateFormatter.string(from: entry.timestamp)
        
        var lines: [String] = [
            "## \(entry.title)",
            "",
            "- **时间**: \(dateStr)",
            "- **类别**: \(entry.category.displayName)",
            "- **标签**: \(entry.tags.joined(separator: ", "))"
        ]
        
        if let conversationId = entry.sourceConversation {
            lines.append("- **会话**: \(conversationId)")
        }
        
        lines.append("")
        lines.append(entry.content)
        
        return lines.joined(separator: "\n")
    }
    
    private func memoryDirectory() throws -> URL {
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let appSupport = paths.first!
        let memoryDir = appSupport
            .appendingPathComponent("MacAssistant/runtime/openclaw/profiles/default/workspace/memory")
        
        try fileManager.createDirectory(at: memoryDir, withIntermediateDirectories: true)
        return memoryDir
    }
}

// MARK: - 便捷扩展

extension MemoryWriter {
    /// 手动创建记忆条目
    func createManualEntry(
        title: String,
        content: String,
        category: MemoryEntry.MemoryCategory,
        tags: [String] = []
    ) async throws {
        let entry = MemoryEntry(
            id: UUID().uuidString,
            timestamp: Date(),
            category: category,
            title: title,
            content: content,
            sourceConversation: nil,
            tags: tags
        )
        try await saveEntry(entry)
    }
    
    /// 保存用户档案信息
    func saveUserProfile(key: String, value: String) async throws {
        let entry = MemoryEntry(
            id: UUID().uuidString,
            timestamp: Date(),
            category: .userProfile,
            title: "用户档案: \(key)",
            content: "**\(key)**: \(value)",
            sourceConversation: nil,
            tags: ["档案", key]
        )
        try await saveEntry(entry)
    }
    
    /// 保存待办事项
    func saveTodoItem(_ item: String, priority: String = "normal") async throws {
        let entry = MemoryEntry(
            id: UUID().uuidString,
            timestamp: Date(),
            category: .todo,
            title: "待办: \(item.prefix(30))...",
            content: "**待办事项**: \(item)\n\n**优先级**: \(priority)",
            sourceConversation: nil,
            tags: ["待办", priority]
        )
        try await saveEntry(entry)
    }
}
