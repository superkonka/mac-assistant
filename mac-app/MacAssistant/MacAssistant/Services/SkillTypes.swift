//
//  SkillTypes.swift
//  MacAssistant
//
//  Skill 相关类型定义（补充）
//

import Foundation

// MARK: - Skill 执行结果
struct SkillExecutionResult {
    let success: Bool
    let output: [String: String]?
    let error: String?
    let artifacts: [Artifact]?  // 生成的文件/图片等
    let followUpActions: [FollowUpAction]?
    
    struct Artifact: Codable {
        let type: ArtifactType
        let path: String
        let description: String
        
        enum ArtifactType: String, Codable {
            case file
            case image
            case url
        }
    }
    
    struct FollowUpAction: Codable {
        let label: String
        let skillID: String?
        let parameters: [String: String]?
    }
}

// MARK: - Skill Adapter Registry
@MainActor
final class SkillAdapterRegistry: ObservableObject {
    static let shared = SkillAdapterRegistry()
    
    func syncToCatalog() async {
        // 临时实现
    }
    
    func execute(skillID: String, parameters: [String: Any]) async throws -> SkillExecutionResult {
        // 临时实现 - 返回成功结果
        return SkillExecutionResult(
            success: true,
            output: ["response": "Skill \(skillID) executed"],
            error: nil,
            artifacts: nil,
            followUpActions: nil
        )
    }
}

// MARK: - Health Severity
enum HealthSeverity: String, Codable {
    case critical
    case warning
    case info
    case error
    
    var displayName: String {
        switch self {
        case .critical: return "严重"
        case .warning: return "警告"
        case .info: return "信息"
        case .error: return "错误"
        }
    }
}
