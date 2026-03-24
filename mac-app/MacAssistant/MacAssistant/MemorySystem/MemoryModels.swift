//
//  MemoryModels.swift
//  MacAssistant
//
//  Hierarchical Memory Data Models (L0/L1/L2)
//

import Foundation
import OpenClawKit

// MARK: - Memory Layer Enumeration

enum MemoryLayer: String, Codable, Sendable, CaseIterable {
    case raw = "L0"
    case filtered = "L1"
    case distilled = "L2"
    
    var parentLayer: MemoryLayer? {
        switch self {
        case .raw: return nil
        case .filtered: return .raw
        case .distilled: return .filtered
        }
    }
    
    var childLayer: MemoryLayer? {
        switch self {
        case .raw: return .filtered
        case .filtered: return .distilled
        case .distilled: return nil
        }
    }
}

// MARK: - Memory ID

struct MemoryID: Codable, Sendable, Hashable, CustomStringConvertible {
    let planId: String
    let layer: MemoryLayer
    let segmentId: String
    let entryId: String
    
    var description: String {
        "\(planId)/\(layer.rawValue)/\(segmentId)/\(entryId)"
    }
    
    func childID(in layer: MemoryLayer, entryId: String? = nil) -> MemoryID {
        MemoryID(
            planId: planId,
            layer: layer,
            segmentId: segmentId,
            entryId: entryId ?? self.entryId
        )
    }
}

// MARK: - L0: Raw Layer (原始层)

/// L0 原始记忆条目 - 完整执行记录
struct RawMemoryEntry: Codable, Sendable, Identifiable {
    let id: MemoryID
    let timestamp: Date
    let type: RawEntryType
    
    // 执行上下文
    let planId: String
    let taskId: String?
    let agentId: String
    let sessionKey: String
    
    // 输入输出
    let input: RawInput
    let output: RawOutput
    
    // 执行元数据
    let executionTrace: MemoryExecutionTrace
    
    // 关联
    let parentEntryId: MemoryID?
    let correlationId: String?  // 用于关联同一批次
    
    enum RawEntryType: String, Codable, Sendable {
        case llmCall
        case toolInvoke
        case stateTransition
        case userInput
        case systemEvent
        case planStart
        case planComplete
    }
    
    struct RawInput: Codable, Sendable {
        let prompt: String
        let attachments: [String]
        let contextSnapshot: String?  // 执行时的上下文摘要
        let parameters: [String: AnyCodable]?
    }
    
    struct RawOutput: Codable, Sendable {
        let response: String
        let metadata: [String: AnyCodable]?
        let finishReason: String?
    }
}

struct MemoryExecutionTrace: Codable, Sendable {
    let durationMs: Int
    let tokenUsage: MemoryTokenUsage?
    let costEstimate: Double?
    let retryCount: Int
    let cacheHit: Bool
    let errorInfo: MemoryErrorInfo?
    let dependencies: [String]  // 依赖的其他 entry ID
}

struct MemoryTokenUsage: Codable, Sendable {
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int
    let cachedTokens: Int?
}

struct MemoryErrorInfo: Codable, Sendable {
    let type: String
    let message: String
    let stackTrace: String?
    let recoverable: Bool
}

// MARK: - L1: Filtered Layer (信息层)

/// L1 过滤记忆条目 - 关键信息提取
struct FilteredMemoryEntry: Codable, Sendable, Identifiable {
    let id: MemoryID
    let sourceId: MemoryID  // 指向 L0
    
    let timestamp: Date
    let importance: ImportanceScore
    
    // 结构化信息
    let keyFacts: [KeyFact]
    let decisions: [DecisionPoint]
    let outcomes: [TaskOutcome]
    
    // 可检索内容
    let summary: String
    let keywords: [String]
    let entities: [EntityReference]
    let searchableContent: String
    
    // 分类
    let category: MemoryCategory
    let sentiment: Sentiment
}

enum ImportanceScore: Int, Codable, Sendable, Comparable {
    case trivial = 1
    case normal = 2
    case significant = 3
    case critical = 4
    
    static func < (lhs: ImportanceScore, rhs: ImportanceScore) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct KeyFact: Codable, Sendable {
    let subject: String
    let predicate: String
    let object: String
    let confidence: Double
    let sourceQuote: String
}

struct DecisionPoint: Codable, Sendable {
    let decision: String
    let alternatives: [String]
    let rationale: String
    let outcome: String
    let timestamp: Date
}

struct TaskOutcome: Codable, Sendable {
    let success: Bool
    let result: String
    let metrics: [String: Double]
}

struct EntityReference: Codable, Sendable {
    let name: String
    let type: EntityType
    let mentions: Int
    
    enum EntityType: String, Codable, Sendable {
        case person
        case project
        case technology
        case tool
        case concept
        case file
        case api
    }
}

enum MemoryCategory: String, Codable, Sendable {
    case technicalDecision
    case errorResolution
    case workflowOptimization
    case knowledgeDiscovery
    case userPreference
    case systemEvent
}

enum Sentiment: String, Codable, Sendable {
    case positive
    case neutral
    case negative
    case mixed
}

// MARK: - L2: Distilled Layer (认知层)

/// L2 蒸馏记忆条目 - 认知结构
struct DistilledMemoryEntry: Codable, Sendable, Identifiable {
    let id: MemoryID
    let sourceIds: [MemoryID]  // 聚合多个 L1
    
    // 时间范围
    let timeRange: ClosedRange<Date>
    let updateCount: Int
    
    // 核心认知
    let concepts: [Concept]
    let relations: [Relation]
    let patterns: [Pattern]
    let beliefs: [Belief]
    
    // 可执行洞察
    let actionableInsights: [ActionableInsight]
    
    // 向量表示（用于语义检索）
    let embedding: EmbeddingVector?
    let graphNodeId: String?
}

struct Concept: Codable, Sendable {
    let id: String
    let name: String
    let type: ConceptType
    let definition: String
    let aliases: [String]
    let frequency: Int
    let confidence: Double
    
    enum ConceptType: String, Codable, Sendable {
        case entity
        case abstraction
        case process
        case constraint
        case pattern
    }
}

struct Relation: Codable, Sendable {
    let id: String
    let sourceConceptId: String
    let targetConceptId: String
    let type: RelationType
    let strength: Double
    let evidence: [String]  // L1 entry IDs
}

enum RelationType: String, Codable, Sendable {
    case dependsOn
    case implements
    case conflictsWith
    case similarTo
    case partOf
    case leadsTo
    case uses
    case extends
    case alternativeTo
}

struct Pattern: Codable, Sendable {
    let id: String
    let name: String
    let description: String
    let triggerConditions: [String]
    let actionSequence: [String]
    let successRate: Double
    let contextConstraints: [String]
    let sourceEvidence: [String]
}

struct Belief: Codable, Sendable {
    let id: String
    let statement: String
    let confidence: Double
    let supportingEvidence: [MemoryID]
    let contradictingEvidence: [MemoryID]
    let lastVerified: Date
    let verificationCount: Int
}

struct ActionableInsight: Codable, Sendable {
    let id: String
    let insight: String
    let applicability: [String]
    let implementation: String?
    let riskAssessment: String?
    let expectedOutcome: String?
    let sourcePatterns: [String]
}

struct EmbeddingVector: Codable, Sendable {
    let model: String
    let dimensions: Int
    let vector: [Float]
    let normalized: Bool
}

// MARK: - Retrieval Types

enum RetrievalDepth: String, Codable, Sendable {
    case surface     // 仅 L2
    case detailed    // L2 + L1
    case complete    // L2 + L1 + L0
}

struct RetrievalQuery: Sendable {
    let text: String
    let embedding: EmbeddingVector?
    let filters: RetrievalFilters
    let depth: RetrievalDepth
    let maxResults: Int
}

struct RetrievalFilters: Sendable {
    let timeRange: ClosedRange<Date>?
    let categories: [MemoryCategory]?
    let minImportance: ImportanceScore?
    let entities: [String]?
    let planId: String?
}

struct HierarchicalRetrievalResult: Sendable {
    let query: RetrievalQuery
    let l2Entries: [DistilledMemoryEntry]
    let l1Entries: [FilteredMemoryEntry]
    let l0Entries: [RawMemoryEntry]
    let diffusionPaths: [DiffusionPath]
    let totalTokens: Int
}

struct DiffusionPath: Sendable {
    let l2Id: MemoryID
    let l1Ids: [MemoryID]
    let l0Ids: [MemoryID]
    let relevanceScore: Double
}

// MARK: - Context Assembly

struct AssembledContext: Sendable {
    let sections: [ContextSection]
    let totalTokens: Int
    let coverage: ContextCoverage
}

struct ContextSection: Sendable {
    let title: String
    let content: String
    let layer: MemoryLayer
    let relevanceScore: Double
    let sourceIds: [MemoryID]
}

struct ContextCoverage: Sendable {
    let l2Coverage: Double
    let l1Coverage: Double
    let l0Coverage: Double
    let gaps: [String]
}
