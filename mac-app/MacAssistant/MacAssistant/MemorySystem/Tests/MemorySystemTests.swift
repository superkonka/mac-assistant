//
//  MemorySystemTests.swift
//  MacAssistant
//
//  Phase 8: Memory System Test Suite
//

import XCTest
@testable import MacAssistant

// MARK: - L0 Storage Tests

@MainActor
final class L0StorageTests: XCTestCase {
    
    var store: InMemoryRawStore!
    
    override func setUp() {
        super.setUp()
        store = InMemoryRawStore()
    }
    
    override func tearDown() {
        store = nil
        super.tearDown()
    }
    
    func testAppendAndGet() async throws {
        let entry = createTestRawEntry(planId: "test-plan")
        try await store.append(entry)
        
        let retrieved = try await store.get(id: entry.id)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.id, entry.id)
        XCTAssertEqual(retrieved?.planId, "test-plan")
    }
    
    func testAppendBatch() async throws {
        let entries = (0..<10).map { i in
            createTestRawEntry(planId: "batch-plan", entryId: "entry-\(i)")
        }
        
        try await store.appendBatch(entries)
        
        let retrieved = try await store.getPlanEntries(planId: "batch-plan")
        XCTAssertEqual(retrieved.count, 10)
    }
    
    func testQueryByTimeRange() async throws {
        let now = Date()
        let entry1 = createTestRawEntry(planId: "time-plan", timestamp: now.addingTimeInterval(-3600))
        let entry2 = createTestRawEntry(planId: "time-plan", timestamp: now)
        
        try await store.append(entry1)
        try await store.append(entry2)
        
        let results = try await store.query(
            planId: "time-plan",
            timeRange: now.addingTimeInterval(-1800)...now.addingTimeInterval(100),
            types: nil
        )
        
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.id, entry2.id)
    }
    
    func testPurgeOldEntries() async throws {
        let oldEntry = createTestRawEntry(planId: "purge-plan", timestamp: Date().addingTimeInterval(-86400 * 2))
        let newEntry = createTestRawEntry(planId: "purge-plan", timestamp: Date())
        
        try await store.append(oldEntry)
        try await store.append(newEntry)
        
        try await store.purgeEntries(olderThan: Date().addingTimeInterval(-86400))
        
        let retrievedOld = try await store.get(id: oldEntry.id)
        let retrievedNew = try await store.get(id: newEntry.id)
        
        XCTAssertNil(retrievedOld)
        XCTAssertNotNil(retrievedNew)
    }
    
    // MARK: - Helpers
    
    private func createTestRawEntry(
        planId: String,
        entryId: String = "test-entry",
        timestamp: Date = Date()
    ) -> RawMemoryEntry {
        RawMemoryEntry(
            id: MemoryID(
                planId: planId,
                layer: .raw,
                segmentId: "test",
                entryId: entryId
            ),
            timestamp: timestamp,
            type: .llmCall,
            planId: planId,
            taskId: nil,
            agentId: "test-agent",
            sessionKey: "test-session",
            input: RawMemoryEntry.RawInput(
                prompt: "Test prompt",
                attachments: [],
                contextSnapshot: nil,
                parameters: nil
            ),
            output: RawMemoryEntry.RawOutput(
                response: "Test response",
                metadata: nil,
                finishReason: nil
            ),
            executionTrace: MemoryExecutionTrace(
                durationMs: 100,
                tokenUsage: nil,
                costEstimate: nil,
                retryCount: 0,
                cacheHit: false,
                errorInfo: nil,
                dependencies: []
            ),
            parentEntryId: nil,
            correlationId: planId
        )
    }
}

// MARK: - L1 Distillation Tests

@MainActor
final class L1DistillationTests: XCTestCase {
    
    var engine: L1DistillationEngine!
    var scorer: ImportanceScorer!
    
    override func setUp() {
        super.setUp()
        engine = L1DistillationEngine()
        scorer = ImportanceScorer()
    }
    
    func testImportanceScoring() async {
        let normalEntry = createTestRawEntry(durationMs: 100, hasError: false)
        let errorEntry = createTestRawEntry(durationMs: 100, hasError: true)
        let slowEntry = createTestRawEntry(durationMs: 6000, hasError: false)
        
        let normalScore = await scorer.score(normalEntry)
        let errorScore = await scorer.score(errorEntry)
        let slowScore = await scorer.score(slowEntry)
        
        XCTAssertEqual(normalScore, .normal)
        XCTAssertEqual(errorScore, .significant)
        XCTAssertEqual(slowScore, .normal)
    }
    
    func testDistillation() async throws {
        let entry = createTestRawEntry(
            prompt: "This is a test prompt about Swift programming",
            response: "Swift is a powerful programming language developed by Apple"
        )
        
        let result = try await engine.distill(entry)
        
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.sourceId, entry.id)
        XCTAssertFalse(result?.summary.isEmpty ?? true)
        XCTAssertFalse(result?.keywords.isEmpty ?? true)
    }
    
    func testLowImportanceFiltering() async throws {
        let trivialEntry = createTestRawEntry(
            durationMs: 10,
            prompt: "hi",
            response: "hello"
        )
        
        let result = try await engine.distill(trivialEntry)
        
        XCTAssertNil(result)
    }
    
    // MARK: - Helpers
    
    private func createTestRawEntry(
        durationMs: Int = 100,
        hasError: Bool = false,
        prompt: String = "Test prompt",
        response: String = "Test response"
    ) -> RawMemoryEntry {
        RawMemoryEntry(
            id: MemoryID(
                planId: "test",
                layer: .raw,
                segmentId: "test",
                entryId: UUID().uuidString
            ),
            timestamp: Date(),
            type: .llmCall,
            planId: "test",
            taskId: nil,
            agentId: "test-agent",
            sessionKey: "test-session",
            input: RawMemoryEntry.RawInput(
                prompt: prompt,
                attachments: [],
                contextSnapshot: nil,
                parameters: nil
            ),
            output: RawMemoryEntry.RawOutput(
                response: response,
                metadata: nil,
                finishReason: nil
            ),
            executionTrace: MemoryExecutionTrace(
                durationMs: durationMs,
                tokenUsage: nil,
                costEstimate: nil,
                retryCount: hasError ? 1 : 0,
                cacheHit: false,
                errorInfo: hasError ? MemoryErrorInfo(type: "TestError", message: "Test", stackTrace: nil, recoverable: true) : nil,
                dependencies: []
            ),
            parentEntryId: nil,
            correlationId: "test"
        )
    }
}

// MARK: - Cache Tests

@MainActor
final class CacheTests: XCTestCase {
    
    var cache: LRUCache<String, String>!
    
    override func setUp() {
        super.setUp()
        cache = LRUCache(maxSize: 3, defaultTTL: nil)
    }
    
    override func tearDown() {
        cache = nil
        super.tearDown()
    }
    
    func testBasicOperations() async {
        await cache.set("key1", value: "value1")
        await cache.set("key2", value: "value2")
        
        let value1 = await cache.get("key1")
        let value2 = await cache.get("key2")
        
        XCTAssertEqual(value1, "value1")
        XCTAssertEqual(value2, "value2")
    }
    
    func testLRUEviction() async {
        await cache.set("key1", value: "value1")
        await cache.set("key2", value: "value2")
        await cache.set("key3", value: "value3")
        
        _ = await cache.get("key1")
        
        await cache.set("key4", value: "value4")
        
        let value1 = await cache.get("key1")
        let value2 = await cache.get("key2")
        let value4 = await cache.get("key4")
        
        XCTAssertEqual(value1, "value1")
        XCTAssertNil(value2)
        XCTAssertEqual(value4, "value4")
    }
    
    func testCacheStats() async {
        await cache.set("key1", value: "value1")
        _ = await cache.get("key1")
        _ = await cache.get("key2")
        _ = await cache.get("key1")
        
        let stats = await cache.getStats()
        
        XCTAssertEqual(stats.size, 1)
        XCTAssertEqual(stats.hitCount, 2)
        XCTAssertEqual(stats.missCount, 1)
        XCTAssertEqual(stats.hitRate, 2.0 / 3.0, accuracy: 0.01)
    }
}

// MARK: - Coordinator Integration Tests

@MainActor
final class CoordinatorIntegrationTests: XCTestCase {
    
    var coordinator: MemoryCoordinator!
    
    override func setUp() {
        super.setUp()
        coordinator = MemoryCoordinator()
    }
    
    override func tearDown() {
        coordinator = nil
        super.tearDown()
    }
    
    func testStoreAndRetrieve() async throws {
        await coordinator.storeExecution(
            planId: "integration-test",
            taskId: "task-1",
            agentId: "agent-1",
            sessionKey: "session-1",
            prompt: "What is Swift?",
            response: "Swift is a programming language",
            durationMs: 500,
            tokenUsage: nil
        )
        
        try await Task.sleep(nanoseconds: 100_000_000)
        
        let context = try await coordinator.buildContext(planId: "integration-test")
        
        XCTAssertNotNil(context)
    }
    
    func testDistillationStats() async throws {
        for i in 0..<5 {
            await coordinator.storeExecution(
                planId: "stats-test",
                taskId: "task-\(i)",
                agentId: "agent-1",
                sessionKey: "session-1",
                prompt: "Question \(i)",
                response: "Answer \(i)",
                durationMs: 500,
                tokenUsage: nil
            )
        }
        
        try await Task.sleep(nanoseconds: 200_000_000)
        
        let stats = await coordinator.getDistillationStats()
        
        XCTAssertGreaterThan(stats.totalProcessed, 0)
    }
}
