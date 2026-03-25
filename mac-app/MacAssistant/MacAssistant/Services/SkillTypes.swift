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

// MARK: - SkillExecutionResult 便捷构造器

extension SkillExecutionResult {
    /// 成功结果
    static func success(
        output: String? = nil,
        data: [String: Any]? = nil
    ) -> SkillExecutionResult {
        var outputDict: [String: String] = [:]
        if let output = output {
            outputDict["response"] = output
        }
        if let data = data {
            for (key, value) in data {
                outputDict[key] = String(describing: value)
            }
        }
        
        return SkillExecutionResult(
            success: true,
            output: outputDict.isEmpty ? nil : outputDict,
            error: nil,
            artifacts: nil,
            followUpActions: nil
        )
    }
    
    /// 失败结果
    static func failure(
        error: String,
        output: String? = nil
    ) -> SkillExecutionResult {
        var outputDict: [String: String] = [:]
        if let output = output {
            outputDict["response"] = output
        }
        
        return SkillExecutionResult(
            success: false,
            output: outputDict.isEmpty ? nil : outputDict,
            error: error,
            artifacts: nil,
            followUpActions: nil
        )
    }
    
    /// 带 artifact 的成功结果
    static func successWithArtifact(
        output: String,
        artifactPath: String,
        artifactType: Artifact.ArtifactType = .file,
        artifactDescription: String = ""
    ) -> SkillExecutionResult {
        let artifact = Artifact(
            type: artifactType,
            path: artifactPath,
            description: artifactDescription.isEmpty ? output : artifactDescription
        )
        
        return SkillExecutionResult(
            success: true,
            output: ["response": output],
            error: nil,
            artifacts: [artifact],
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
