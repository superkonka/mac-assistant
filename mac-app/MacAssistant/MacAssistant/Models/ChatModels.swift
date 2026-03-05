//
//  ChatModels.swift
//  数据模型
//

import Foundation

enum MessageRole: String, Codable {
    case user
    case assistant
    case system
}

struct ChatMessage: Identifiable, Codable {
    let id: UUID
    var role: MessageRole
    var content: String
    var timestamp: Date?
    var metadata: [String: String]?
    
    init(id: UUID = UUID(), role: MessageRole, content: String, timestamp: Date? = nil, metadata: [String: String]? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.metadata = metadata
    }
}

struct APIResponse: Codable {
    let role: String?
    let content: String?
    let error: String?
}

struct HealthResponse: Codable {
    let status: String
    let openclaw: Bool
    let kimi: Bool
    let connections: Int
}

struct CommandRequest: Codable {
    let command: String
    let context: String?
    let use_openclaw: Bool
    let use_kimi: Bool
}

struct SystemAction: Codable {
    let action: String
    let params: [String: String]?
}
