//
//  WarmStorage.swift
//  温数据层 - SQLite，短期历史、技能库、蒸馏内容
//

import Foundation
import SQLite3

class WarmStorage {
    private var db: OpaquePointer?
    private let dbPath: String
    
    init() {
        let documentsPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
        dbPath = documentsPath + "/mac_assistant_warm.db"
        
        openDatabase()
        createTables()
    }
    
    deinit {
        sqlite3_close(db)
    }
    
    // MARK: - 数据库初始化
    
    private func openDatabase() {
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            print("无法打开数据库: \(String(cString: sqlite3_errmsg(db)))")
        }
    }
    
    private func createTables() {
        let createMessagesTable = """
            CREATE TABLE IF NOT EXISTS messages (
                id TEXT PRIMARY KEY,
                role TEXT,
                content TEXT,
                timestamp REAL,
                priority INTEGER,
                lifetime INTEGER,
                access_count INTEGER DEFAULT 1,
                last_access REAL,
                tags TEXT,
                is_distilled INTEGER DEFAULT 0
            );
        """
        
        let createSkillsTable = """
            CREATE TABLE IF NOT EXISTS skills (
                id TEXT PRIMARY KEY,
                name TEXT,
                triggers TEXT,
                command_template TEXT,
                priority INTEGER,
                usage_count INTEGER DEFAULT 0,
                success_count INTEGER DEFAULT 0,
                fail_count INTEGER DEFAULT 0,
                improvement_suggestions TEXT,
                created_at REAL,
                updated_at REAL,
                version INTEGER DEFAULT 1
            );
        """
        
        let createDistilledTable = """
            CREATE TABLE IF NOT EXISTS distilled_content (
                id TEXT PRIMARY KEY,
                original_message_id TEXT,
                topic TEXT,
                intent TEXT,
                entities TEXT,
                conclusion TEXT,
                keywords TEXT,
                timestamp REAL,
                confidence REAL
            );
        """
        
        let createSkillUsageTable = """
            CREATE TABLE IF NOT EXISTS skill_usage (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                skill_id TEXT,
                timestamp REAL,
                success INTEGER,
                context TEXT,
                result TEXT
            );
        """
        
        _ = execute(createMessagesTable)
        _ = execute(createSkillsTable)
        _ = execute(createDistilledTable)
        _ = execute(createSkillUsageTable)
    }
    
    // MARK: - 消息存储
    
    func saveMessage(_ message: ChatMessage, metadata: StorageMetadata) {
        let sql = """
            INSERT OR REPLACE INTO messages 
            (id, role, content, timestamp, priority, lifetime, access_count, last_access, tags, is_distilled)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        
        let tagsString = metadata.tags.joined(separator: ",")
        
        execute(sql, params: [
            message.id.uuidString,
            message.role.rawValue,
            message.content,
            message.timestamp.timeIntervalSince1970,
            metadata.priority.rawValue,
            metadata.lifetime.hashValue,
            metadata.accessCount,
            metadata.lastAccess.timeIntervalSince1970,
            tagsString,
            0
        ])
    }

    func upsertRecentMessages(_ messages: [ChatMessage]) {
        for message in messages {
            let sql = """
                INSERT OR REPLACE INTO messages
                (id, role, content, timestamp, priority, lifetime, access_count, last_access, tags, is_distilled)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, COALESCE((SELECT is_distilled FROM messages WHERE id = ?), 0));
            """

            execute(sql, params: [
                message.id.uuidString,
                message.role.rawValue,
                message.content,
                message.timestamp.timeIntervalSince1970,
                DataPriority.normal.rawValue,
                DataLifetime.shortTerm.hashValue,
                1,
                message.timestamp.timeIntervalSince1970,
                "",
                message.id.uuidString
            ])
        }
    }
    
    func getRecentMessages(limit: Int) -> [ChatMessage] {
        let sql = """
            SELECT id, role, content, timestamp 
            FROM messages 
            ORDER BY timestamp DESC 
            LIMIT ?;
        """
        
        var messages: [ChatMessage] = []
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(limit))
            
            while sqlite3_step(statement) == SQLITE_ROW {
                if let idString = sqlite3_column_text(statement, 0),
                   let roleString = sqlite3_column_text(statement, 1),
                   let content = sqlite3_column_text(statement, 2) {
                    
                    let id = UUID(uuidString: String(cString: idString)) ?? UUID()
                    let role = MessageRole(rawValue: String(cString: roleString)) ?? .user
                    let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
                    
                    messages.append(ChatMessage(
                        id: id,
                        role: role,
                        content: String(cString: content),
                        timestamp: timestamp
                    ))
                }
            }
            sqlite3_finalize(statement)
        }
        
        return messages.reversed()
    }
    
    func search(query: String) -> [ChatMessage] {
        let sql = """
            SELECT id, role, content, timestamp 
            FROM messages 
            WHERE content LIKE ? 
            ORDER BY last_access DESC 
            LIMIT 50;
        """
        
        var messages: [ChatMessage] = []
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            let searchPattern = "%\(query)%"
            sqlite3_bind_text(statement, 1, (searchPattern as NSString).utf8String, -1, nil)
            
            while sqlite3_step(statement) == SQLITE_ROW {
                if let idString = sqlite3_column_text(statement, 0),
                   let roleString = sqlite3_column_text(statement, 1),
                   let content = sqlite3_column_text(statement, 2) {
                    
                    let id = UUID(uuidString: String(cString: idString)) ?? UUID()
                    let role = MessageRole(rawValue: String(cString: roleString)) ?? .user
                    let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
                    
                    messages.append(ChatMessage(
                        id: id,
                        role: role,
                        content: String(cString: content),
                        timestamp: timestamp
                    ))
                }
            }
            sqlite3_finalize(statement)
        }
        
        return messages
    }
    
    func getMessagesOlderThan(days: Int) -> [ChatMessage] {
        let cutoff = Date().addingTimeInterval(-Double(days * 24 * 60 * 60))
        let sql = """
            SELECT id, role, content, timestamp 
            FROM messages 
            WHERE timestamp < ?;
        """
        
        var messages: [ChatMessage] = []
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_double(statement, 1, cutoff.timeIntervalSince1970)
            
            while sqlite3_step(statement) == SQLITE_ROW {
                if let idString = sqlite3_column_text(statement, 0),
                   let roleString = sqlite3_column_text(statement, 1),
                   let content = sqlite3_column_text(statement, 2) {
                    
                    let id = UUID(uuidString: String(cString: idString)) ?? UUID()
                    let role = MessageRole(rawValue: String(cString: roleString)) ?? .user
                    let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
                    
                    messages.append(ChatMessage(
                        id: id,
                        role: role,
                        content: String(cString: content),
                        timestamp: timestamp
                    ))
                }
            }
            sqlite3_finalize(statement)
        }
        
        return messages
    }
    
    func deleteMessagesOlderThan(days: Int) {
        let cutoff = Date().addingTimeInterval(-Double(days * 24 * 60 * 60))
        let sql = "DELETE FROM messages WHERE timestamp < ?;"
        execute(sql, params: [cutoff.timeIntervalSince1970])
    }
    
    func clearMessages() {
        let sql = "DELETE FROM messages;"
        execute(sql, params: [])
    }
    
    func updateAccessCount(for messageId: UUID) {
        let sql = """
            UPDATE messages 
            SET access_count = access_count + 1, last_access = ? 
            WHERE id = ?;
        """
        execute(sql, params: [Date().timeIntervalSince1970, messageId.uuidString])
    }
    
    func markAsDistilled(_ messageId: UUID) {
        let sql = "UPDATE messages SET is_distilled = 1 WHERE id = ?;"
        execute(sql, params: [messageId.uuidString])
    }
    
    func getMessagesForDistillation() -> [ChatMessage] {
        // 获取中频、未蒸馏、超过7天的消息
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        let sql = """
            SELECT id, role, content, timestamp 
            FROM messages 
            WHERE is_distilled = 0 
            AND access_count BETWEEN 2 AND 10
            AND timestamp < ?
            LIMIT 50;
        """
        
        var messages: [ChatMessage] = []
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_double(statement, 1, cutoff.timeIntervalSince1970)
            
            while sqlite3_step(statement) == SQLITE_ROW {
                if let idString = sqlite3_column_text(statement, 0),
                   let roleString = sqlite3_column_text(statement, 1),
                   let content = sqlite3_column_text(statement, 2) {
                    
                    let id = UUID(uuidString: String(cString: idString)) ?? UUID()
                    let role = MessageRole(rawValue: String(cString: roleString)) ?? .user
                    let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
                    
                    messages.append(ChatMessage(
                        id: id,
                        role: role,
                        content: String(cString: content),
                        timestamp: timestamp
                    ))
                }
            }
            sqlite3_finalize(statement)
        }
        
        return messages
    }
    
    // MARK: - 技能存储
    
    func saveSkill(_ skill: Skill) {
        let sql = """
            INSERT OR REPLACE INTO skills 
            (id, name, triggers, command_template, priority, usage_count, success_count, 
             fail_count, improvement_suggestions, created_at, updated_at, version)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        
        let triggersString = skill.triggers.joined(separator: ",")
        let suggestionsString = skill.improvementSuggestions?.joined(separator: "|") ?? ""
        
        execute(sql, params: [
            skill.id,
            skill.name,
            triggersString,
            skill.commandTemplate,
            skill.priority.rawValue,
            skill.usageCount,
            skill.successCount,
            skill.failCount,
            suggestionsString,
            skill.createdAt?.timeIntervalSince1970 ?? Date().timeIntervalSince1970,
            Date().timeIntervalSince1970,
            skill.version
        ])
    }
    
    func getSkills() -> [Skill] {
        let sql = "SELECT * FROM skills ORDER BY usage_count DESC;"
        var skills: [Skill] = []
        
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                if let stmt = statement, let skill = parseSkill(from: stmt) {
                    skills.append(skill)
                }
            }
            sqlite3_finalize(statement)
        }
        
        return skills
    }
    
    func recordSkillUsage(skillId: String, success: Bool, context: String) {
        // 记录使用日志
        let logSql = """
            INSERT INTO skill_usage (skill_id, timestamp, success, context, result)
            VALUES (?, ?, ?, ?, ?);
        """
        execute(logSql, params: [
            skillId,
            Date().timeIntervalSince1970,
            success ? 1 : 0,
            context,
            ""
        ])
        
        // 更新统计
        let updateSql = success 
            ? "UPDATE skills SET usage_count = usage_count + 1, success_count = success_count + 1 WHERE id = ?;"
            : "UPDATE skills SET usage_count = usage_count + 1, fail_count = fail_count + 1 WHERE id = ?;"
        execute(updateSql, params: [skillId])
    }
    
    func getSkillUsageStats(skillId: String) -> SkillUsageStats {
        let sql = """
            SELECT 
                COUNT(*) as total,
                SUM(CASE WHEN success = 1 THEN 1 ELSE 0 END) as successes,
                AVG(CASE WHEN success = 1 THEN 1.0 ELSE 0.0 END) as success_rate
            FROM skill_usage 
            WHERE skill_id = ?;
        """
        
        var stats = SkillUsageStats(totalUses: 0, successCount: 0, failCount: 0, successRate: 0, improvementSuggestions: [])
        
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (skillId as NSString).utf8String, -1, nil)
            
            if sqlite3_step(statement) == SQLITE_ROW {
                stats.totalUses = Int(sqlite3_column_int(statement, 0))
                stats.successCount = Int(sqlite3_column_int(statement, 1))
                stats.successRate = sqlite3_column_double(statement, 2)
            }
            sqlite3_finalize(statement)
        }
        
        // 获取改进建议
        let suggestionSql = "SELECT improvement_suggestions FROM skills WHERE id = ?;"
        if sqlite3_prepare_v2(db, suggestionSql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (skillId as NSString).utf8String, -1, nil)
            if sqlite3_step(statement) == SQLITE_ROW,
               let text = sqlite3_column_text(statement, 0) {
                let suggestions = String(cString: text).split(separator: "|").map(String.init)
                stats.improvementSuggestions = suggestions
            }
            sqlite3_finalize(statement)
        }
        
        stats.failCount = stats.totalUses - stats.successCount
        return stats
    }
    
    // MARK: - 蒸馏内容存储
    
    func saveDistilledContent(_ content: DistilledContent) {
        let sql = """
            INSERT OR REPLACE INTO distilled_content
            (id, original_message_id, topic, intent, entities, conclusion, keywords, timestamp, confidence)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        
        execute(sql, params: [
            content.id.uuidString,
            content.originalMessageId?.uuidString ?? "",
            content.topic,
            content.intent,
            content.entities.joined(separator: ","),
            content.conclusion,
            content.keywords.joined(separator: ","),
            content.timestamp.timeIntervalSince1970,
            content.confidence
        ])
    }
    
    func getDistilledContent(for topic: String) -> DistilledContent? {
        let sql = """
            SELECT * FROM distilled_content 
            WHERE topic LIKE ? OR keywords LIKE ?
            ORDER BY confidence DESC, timestamp DESC
            LIMIT 1;
        """
        
        var statement: OpaquePointer?
        let pattern = "%\(topic)%"
        
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (pattern as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 2, (pattern as NSString).utf8String, -1, nil)
            
            if sqlite3_step(statement) == SQLITE_ROW {
                // 解析结果...
            }
            sqlite3_finalize(statement)
        }
        
        return nil
    }
    
    // MARK: - 辅助方法
    
    private func execute(_ sql: String, params: [Any] = []) -> Bool {
        var statement: OpaquePointer?
        
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            print("SQL准备失败: \(String(cString: sqlite3_errmsg(db)))")
            return false
        }
        
        // 绑定参数
        for (index, param) in params.enumerated() {
            let position = Int32(index + 1)
            switch param {
            case let value as String:
                sqlite3_bind_text(statement, position, (value as NSString).utf8String, -1, nil)
            case let value as Int:
                // 使用 int64 避免溢出
                sqlite3_bind_int64(statement, position, Int64(value))
            case let value as Double:
                sqlite3_bind_double(statement, position, value)
            case let value as Int64:
                sqlite3_bind_int64(statement, position, value)
            default:
                sqlite3_bind_null(statement, position)
            }
        }
        
        let result = sqlite3_step(statement) == SQLITE_DONE
        sqlite3_finalize(statement)
        
        return result
    }
    
    private func parseSkill(from statement: OpaquePointer) -> Skill? {
        guard let id = sqlite3_column_text(statement, 0),
              let name = sqlite3_column_text(statement, 1),
              let triggers = sqlite3_column_text(statement, 2),
              let template = sqlite3_column_text(statement, 3) else {
            return nil
        }
        
        let triggerList = String(cString: triggers).split(separator: ",").map(String.init)
        
        return Skill(
            id: String(cString: id),
            name: String(cString: name),
            triggers: triggerList,
            commandTemplate: String(cString: template),
            priority: SkillPriority(rawValue: Int(sqlite3_column_int(statement, 4))) ?? .normal,
            usageCount: Int(sqlite3_column_int(statement, 5)),
            successCount: Int(sqlite3_column_int(statement, 6)),
            failCount: Int(sqlite3_column_int(statement, 7)),
            improvementSuggestions: nil,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 9)),
            version: Int(sqlite3_column_int(statement, 11))
        )
    }
}

// MARK: - 数据结构

struct SkillUsageStats {
    var totalUses: Int
    var successCount: Int
    var failCount: Int
    var successRate: Double
    var improvementSuggestions: [String]
}
