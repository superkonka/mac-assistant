//
//  MemoryCoordinator.swift
//  MacAssistant
//
//  Unified Memory Coordinator - Main Entry Point
//

import Foundation
import OpenClawKit

/// 统一记忆协调器 - 三层记忆系统的中央控制器
actor MemoryCoordinator: MemoryCoordinating {
    
    // MARK: - Singleton
    
    static let shared = MemoryCoordinator()
    
    // MARK: - Storage Backends
    
    private let l0Store: RawMemoryStore
    private let l1Store: FilteredMemoryStore
    private let l2Store: DistilledMemoryStore
    
    // MARK: - State
    
    private var planContexts: [String: PlanMemoryContext] = [:]
    private var isInitialized = false
    
    // MARK: - Initialization
    
    init() {
        // 使用内存存储作为默认实现（快速启动）
        self.l0Store = InMemoryRawStore()
        self.l1Store = InMemoryFilteredStore()
        self.l2Store = InMemoryDistilledStore()
        
        LogInfo("[MemoryCoordinator] Initialized with in-memory stores")
    }
    
    /// 使用指定后端初始化
    init(
        l0Backend: StorageBackend = .inMemory,
        l1Backend: StorageBackend = .inMemory,
        l2Backend: StorageBackend = .inMemory
    ) async {
        self.l0Store = await MemoryStorageFactory.createRawStore(backend: l0Backend)
        self.l1Store = await MemoryStorageFactory.createFilteredStore(backend: l1Backend)
        self.l2Store = await MemoryStorageFactory.createDistilledStore(backend: l2Backend)
        
        self.isInitialized = true
        LogInfo("[MemoryCoordinator] Initialized with backends: L0=\(l0Backend), L1=\(l1Backend), L2=\(l2Backend)")
    }
    
    // MARK: - Public API
    
    func initializePlanContext(
        planId: String,
        mainSessionKey: String
    ) async throws -> PlanMemoryContext {
        let context = PlanMemoryContext(
            planId: planId,
            mainSessionKey: mainSessionKey,
            initializedAt: Date(),
            l0EntryCount: 0
        )
        planContexts[planId] = context
        LogInfo("[MemoryCoordinator] Initialized plan context: \(planId)")
        return context
    }
    
    /// 存储原始执行记录（L0）- 主要入口点
    func storeRaw(_ entry: RawMemoryEntry) async throws {
        // 检查 L0 是否启用
        guard MemoryFeatureFlags.enableL0Storage else {
            return
        }
        
        // 写入 L0
        try await l0Store.append(entry)
        
        // 更新统计
        if var context = planContexts[entry.planId] {
            // context.l0EntryCount += 1  // 需要可变绑定
        }
        
        LogDebug("[MemoryCoordinator] Stored L0 entry: \(entry.id)")
        
        // 如果 L1 启用，触发异步蒸馏
        if MemoryFeatureFlags.enableL1Filter && MemoryFeatureFlags.asyncDistillation {
            Task {
                await triggerL1Distillation(for: entry)
            }
        }
    }
    
    /// 从执行结果创建并存储 L0 条目（便捷方法）
    func storeExecution(
        planId: String,
        taskId: String?,
        agentId: String,
        sessionKey: String,
        prompt: String,
        response: String,
        durationMs: Int,
        tokenUsage: TokenUsage?,
        metadata: [String: AnyCodable]? = nil
    ) async {
        guard MemoryFeatureFlags.enableL0Storage else { return }
        
        let entry = RawMemoryEntry(
            id: MemoryID(
                planId: planId,
                layer: .raw,
                segmentId: taskId ?? "main",
                entryId: "\(Date().timeIntervalSince1970)"
            ),
            timestamp: Date(),
            type: .llmCall,
            planId: planId,
            taskId: taskId,
            agentId: agentId,
            sessionKey: sessionKey,
            input: RawMemoryEntry.RawInput(
                prompt: prompt,
                attachments: [],
                contextSnapshot: nil,
                parameters: metadata
            ),
            output: RawMemoryEntry.RawOutput(
                response: response,
                metadata: metadata,
                finishReason: nil
            ),
            executionTrace: ExecutionTrace(
                durationMs: durationMs,
                tokenUsage: tokenUsage,
                costEstimate: nil,
                retryCount: 0,
                cacheHit: false,
                errorInfo: nil,
                dependencies: []
            ),
            parentEntryId: nil,
            correlationId: planId
        )
        
        try? await storeRaw(entry)
    }
    
    func buildTaskContext(
        planId: String,
        taskId: String,
        requiredDepth: RetrievalDepth
    ) async -> TaskExecutionContext {
        
        var entries: [ContextEntry] = []
        var concepts: [Concept] = []
        
        // 根据深度检索不同层级
        switch requiredDepth {
        case .surface:
            // 仅 L2
            if MemoryFeatureFlags.enableL2Distill {
                let l2Results = try? await l2Store.queryByConcept(conceptName: taskId)
                entries = l2Results?.map { l2ToContextEntry($0) } ?? []
            }
            
        case .detailed:
            // L2 + L1
            if MemoryFeatureFlags.enableL2Distill {
                let l2Results = try? await l2Store.queryByConcept(conceptName: taskId)
                concepts = l2Results?.flatMap(\.concepts) ?? []
            }
            if MemoryFeatureFlags.enableL1Filter {
                let l1Results = try? await l1Store.queryByKeywords(
                    keywords: [taskId],
                    planId: planId
                )
                entries.append(contentsOf: l1Results?.map { l1ToContextEntry($0) } ?? [])
            }
            
        case .complete:
            // L2 + L1 + L0
            if MemoryFeatureFlags.enableL2Distill {
                let l2Results = try? await l2Store.queryByConcept(conceptName: taskId)
                concepts = l2Results?.flatMap(\.concepts) ?? []
            }
            if MemoryFeatureFlags.enableL1Filter {
                let l1Results = try? await l1Store.queryByKeywords(
                    keywords: [taskId],
                    planId: planId
                )
                entries.append(contentsOf: l1Results?.map { l1ToContextEntry($0) } ?? [])
            }
            if MemoryFeatureFlags.enableL0Storage {
                let l0Results = try? await l0Store.getExecutionTrace(
                    planId: planId,
                    taskId: taskId
                )
                entries.append(contentsOf: l0Results?.map { l0ToContextEntry($0) } ?? [])
            }
        }
        
        // 按相关性排序
        entries.sort { $0.relevance > $1.relevance }
        
        return TaskExecutionContext(
            taskId: taskId,
            planId: planId,
            entries: entries,
            concepts: concepts,
            patterns: [],  // 从 L2 提取
            writableScope: MemoryScope(layer: .filtered, planId: planId, taskId: taskId)
        )
    }
    
    func retrieve(query: RetrievalQuery) async throws -> HierarchicalRetrievalResult {
        var l2Entries: [DistilledMemoryEntry] = []
        var l1Entries: [FilteredMemoryEntry] = []
        var l0Entries: [RawMemoryEntry] = []
        var diffusionPaths: [DiffusionPath] = []
        
        // L2 语义检索
        if MemoryFeatureFlags.enableL2Distill {
            l2Entries = try await l2Store.semanticSearch(
                query: query.text,
                embedding: query.embedding ?? EmbeddingVector(
                    model: "default",
                    dimensions: 0,
                    vector: [],
                    normalized: false
                ),
                topK: query.maxResults,
                filters: query.filters
            )
        }
        
        // 根据深度扩散
        if query.depth == .detailed || query.depth == .complete {
            if MemoryFeatureFlags.enableL1Filter {
                for l2 in l2Entries {
                    let sources = try? await l1Store.getSourcesForL2(l2Id: l2.id)
                    l1Entries.append(contentsOf: sources ?? [])
                    
                    diffusionPaths.append(DiffusionPath(
                        l2Id: l2.id,
                        l1Ids: sources?.map(\.id) ?? [],
                        l0Ids: [],
                        relevanceScore: 0.8
                    ))
                }
            }
        }
        
        if query.depth == .complete {
            if MemoryFeatureFlags.enableL0Storage {
                for l1 in l1Entries {
                    if let l0 = try? await l0Store.get(id: l1.sourceId) {
                        l0Entries.append(l0)
                    }
                }
            }
        }
        
        // 估算 token 数
        let totalTokens = estimateTokens(l2Entries, l1Entries, l0Entries)
        
        return HierarchicalRetrievalResult(
            query: query,
            l2Entries: l2Entries,
            l1Entries: l1Entries,
            l0Entries: l0Entries,
            diffusionPaths: diffusionPaths,
            totalTokens: totalTokens
        )
    }
    
    func assembleContext(
        retrievalResult: HierarchicalRetrievalResult,
        budget: ContextBudget
    ) async -> AssembledContext {
        var sections: [ContextSection] = []
        var usedTokens = 0
        
        // 优先级 1: L2 核心概念
        for entry in retrievalResult.l2Entries.prefix(3) {
            let content = formatL2ForContext(entry)
            let tokens = estimateContentTokens(content)
            
            if usedTokens + tokens <= budget.l2Allocation {
                sections.append(ContextSection(
                    title: "认知摘要: \(entry.concepts.first?.name ?? "Unknown")",
                    content: content,
                    layer: .distilled,
                    relevanceScore: 0.95,
                    sourceIds: [entry.id]
                ))
                usedTokens += tokens
            }
        }
        
        // 优先级 2: L1 关键事实
        let remainingBudget = budget.totalTokens - usedTokens
        for entry in retrievalResult.l1Entries
            .filter({ $0.importance >= .significant })
            .prefix(5) {
            
            let content = formatL1ForContext(entry)
            let tokens = estimateContentTokens(content)
            
            if usedTokens + tokens <= remainingBudget * 0.7 {
                sections.append(ContextSection(
                    title: "关键信息: \(entry.summary.prefix(30))...",
                    content: content,
                    layer: .filtered,
                    relevanceScore: Double(entry.importance.rawValue) / 4.0,
                    sourceIds: [entry.id]
                ))
                usedTokens += tokens
            }
        }
        
        // 优先级 3: L0 细节（仅当空间允许）
        if !retrievalResult.l0Entries.isEmpty && usedTokens < budget.totalTokens * 0.9 {
            let l0Summary = formatL0Summary(retrievalResult.l0Entries)
            sections.append(ContextSection(
                title: "执行细节",
                content: l0Summary,
                layer: .raw,
                relevanceScore: 0.5,
                sourceIds: retrievalResult.l0Entries.map(\.id)
            ))
        }
        
        let coverage = ContextCoverage(
            l2Coverage: min(1.0, Double(sections.filter { $0.layer == .distilled }.count) / 3.0),
            l1Coverage: min(1.0, Double(sections.filter { $0.layer == .filtered }.count) / 5.0),
            l0Coverage: sections.contains { $0.layer == .raw } ? 1.0 : 0.0,
            gaps: identifyGaps(sections, retrievalResult)
        )
        
        return AssembledContext(
            sections: sections,
            totalTokens: usedTokens,
            coverage: coverage
        )
    }
    
    func finalizePlan(planId: String) async throws {
        guard var context = planContexts[planId] else { return }
        
        LogInfo("[MemoryCoordinator] Finalizing plan: \(planId)")
        
        // 触发最终蒸馏（如果 L2 启用）
        if MemoryFeatureFlags.enableL2Distill {
            try await triggerFinalL2Distillation(planId: planId)
        }
        
        // 清理临时数据
        if MemoryFeatureFlags.enableL0Storage {
            // 保留最近数据，清理旧的
            let cutoff = Date().addingTimeInterval(-Double(MemoryFeatureFlags.l0RetentionDays) * 24 * 3600)
            try? await l0Store.purgeEntries(olderThan: cutoff)
        }
        
        planContexts.removeValue(forKey: planId)
        LogInfo("[MemoryCoordinator] Plan finalized: \(planId)")
    }
    
    // MARK: - Private Methods
    
    private func triggerL1Distillation(for entry: RawMemoryEntry) async {
        // 简化的 L1 蒸馏逻辑
        // 实际实现应调用 L1DistillationEngine
        LogDebug("[MemoryCoordinator] Would trigger L1 distillation for: \(entry.id)")
    }
    
    private func triggerFinalL2Distillation(planId: String) async throws {
        // 从 L1 聚合生成 L2
        LogInfo("[MemoryCoordinator] Triggering final L2 distillation for plan: \(planId)")
    }
    
    private func l2ToContextEntry(_ entry: DistilledMemoryEntry) -> ContextEntry {
        ContextEntry(
            source: .distilled,
            content: entry.concepts.map { "\($0.name): \($0.definition)" }.joined(separator: "\n"),
            relevance: 0.95,
            timestamp: entry.timeRange.lowerBound
        )
    }
    
    private func l1ToContextEntry(_ entry: FilteredMemoryEntry) -> ContextEntry {
        ContextEntry(
            source: .filtered,
            content: entry.summary,
            relevance: Double(entry.importance.rawValue) / 4.0,
            timestamp: entry.timestamp
        )
    }
    
    private func l0ToContextEntry(_ entry: RawMemoryEntry) -> ContextEntry {
        ContextEntry(
            source: .raw,
            content: entry.output.response,
            relevance: 0.5,
            timestamp: entry.timestamp
        )
    }
    
    private func formatL2ForContext(_ entry: DistilledMemoryEntry) -> String {
        var parts: [String] = []
        
        parts.append("核心概念:")
        for concept in entry.concepts.prefix(3) {
            parts.append("- \(concept.name): \(concept.definition)")
        }
        
        if !entry.beliefs.isEmpty {
            parts.append("\n关键结论:")
            for belief in entry.beliefs.prefix(2) {
                parts.append("- \(belief.statement) (置信度: \(Int(belief.confidence * 100))%)")
            }
        }
        
        return parts.joined(separator: "\n")
    }
    
    private func formatL1ForContext(_ entry: FilteredMemoryEntry) -> String {
        var parts: [String] = []
        parts.append(entry.summary)
        
        if !entry.keyFacts.isEmpty {
            parts.append("\n关键事实:")
            for fact in entry.keyFacts.prefix(2) {
                parts.append("- \(fact.subject) \(fact.predicate) \(fact.object)")
            }
        }
        
        return parts.joined(separator: "\n")
    }
    
    private func formatL0Summary(_ entries: [RawMemoryEntry]) -> String {
        "[包含 \(entries.count) 条原始执行记录]"
    }
    
    private func estimateTokens(
        _ l2: [DistilledMemoryEntry],
        _ l1: [FilteredMemoryEntry],
        _ l0: [RawMemoryEntry]
    ) -> Int {
        var total = 0
        total += l2.reduce(0) { $0 + $1.concepts.count * 50 }
        total += l1.reduce(0) { $0 + $1.summary.count / 4 }
        total += l0.reduce(0) { $0 + $1.output.response.count / 4 }
        return total
    }
    
    private func estimateContentTokens(_ content: String) -> Int {
        content.count / 4  // 简化估算
    }
    
    private func identifyGaps(
        _ sections: [ContextSection],
        _ result: HierarchicalRetrievalResult
    ) -> [String] {
        var gaps: [String] = []
        
        if sections.filter({ $0.layer == .distilled }).isEmpty && !result.l2Entries.isEmpty {
            gaps.append("L2 concepts not included in context")
        }
        
        if sections.filter({ $0.layer == .filtered }).isEmpty && !result.l1Entries.isEmpty {
            gaps.append("L1 details not included in context")
        }
        
        return gaps
    }
}

// MARK: - Convenience Extensions

extension MemoryCoordinator {
    /// 快速存储执行记录（最常用）
    func logExecution(
        planId: String,
        agentId: String,
        prompt: String,
        response: String,
        durationMs: Int
    ) async {
        await storeExecution(
            planId: planId,
            taskId: nil,
            agentId: agentId,
            sessionKey: "main",
            prompt: prompt,
            response: response,
            durationMs: durationMs,
            tokenUsage: nil
        )
    }
}
