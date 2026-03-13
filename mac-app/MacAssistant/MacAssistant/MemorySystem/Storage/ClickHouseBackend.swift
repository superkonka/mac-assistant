//
//  ClickHouseBackend.swift
//  MacAssistant
//
//  Phase 5: ClickHouse Storage Backend for L0 Time-Series Data
//

import Foundation

// MARK: - ClickHouse Configuration

struct ClickHouseConfig {
    let host: String
    let port: Int
    let database: String
    let username: String
    let password: String
    let useHTTPS: Bool
    let maxConnections: Int
    
    static let `default` = ClickHouseConfig(
        host: ProcessInfo.processInfo.environment["CH_HOST"] ?? "localhost",
        port: Int(ProcessInfo.processInfo.environment["CH_PORT"] ?? "8123") ?? 8123,
        database: ProcessInfo.processInfo.environment["CH_DATABASE"] ?? "macassistant_memory",
        username: ProcessInfo.processInfo.environment["CH_USER"] ?? "default",
        password: ProcessInfo.processInfo.environment["CH_PASSWORD"] ?? "",
        useHTTPS: false,
        maxConnections: 10
    )
    
    var baseURL: String {
        let scheme = useHTTPS ? "https" : "http"
        return "\(scheme)://\(host):\(port)"
    }
}

// MARK: - ClickHouse HTTP Client (Framework)

// Note: 这是一个框架实现。实际使用时需要添加 AsyncHTTPClient 依赖
// 并在 Package.swift 中添加: .package(url: "https://github.com/swift-server/async-http-client", from: "1.0.0")

actor ClickHouseHTTPClient {
    private let config: ClickHouseConfig
    private var isInitialized = false
    
    init(config: ClickHouseConfig = .default) {
        self.config = config
    }
    
    func initialize() async throws {
        LogInfo("[ClickHouse] Initializing client for \(config.host):\(config.port)")
        isInitialized = true
    }
    
    func execute(query: String) async throws -> Data {
        guard isInitialized else {
            throw MemoryError.connectionFailed("Client not initialized")
        }
        LogDebug("[ClickHouse] Executing: \(query.prefix(100))...")
        return Data()
    }
    
    func insert(table: String, data: [ClickHouseRow]) async throws {
        LogInfo("[ClickHouse] Inserting \(data.count) rows into \(table)")
    }
    
    func close() async {
        LogInfo("[ClickHouse] Closing client")
        isInitialized = false
    }
}

// MARK: - ClickHouse Row Protocol

protocol ClickHouseRow {
    func toTSV() -> String
}

// MARK: - L0 ClickHouse Row

struct L0ClickHouseRow: ClickHouseRow {
    let entry: RawMemoryEntry
    
    func toTSV() -> String {
        var fields: [String] = []
        
        fields.append(entry.id.description)
        fields.append(entry.id.planId)
        fields.append(entry.id.segmentId)
        fields.append(entry.id.entryId)
        fields.append(formatDate(entry.timestamp))
        fields.append(String(entry.type.rawValue))
        fields.append(entry.planId)
        fields.append(entry.taskId ?? "\\N")
        fields.append(entry.agentId)
        fields.append(entry.sessionKey)
        fields.append(escape(entry.input.prompt))
        fields.append(encodeArray(entry.input.attachments))
        fields.append(entry.input.contextSnapshot ?? "\\N")
        fields.append(encodeJSON(entry.input.parameters))
        fields.append(escape(entry.output.response))
        fields.append(encodeJSON(entry.output.metadata))
        fields.append(entry.output.finishReason ?? "\\N")
        fields.append(String(entry.executionTrace.durationMs))
        fields.append(String(entry.executionTrace.tokenUsage?.promptTokens ?? 0))
        fields.append(String(entry.executionTrace.tokenUsage?.completionTokens ?? 0))
        fields.append(String(entry.executionTrace.tokenUsage?.totalTokens ?? 0))
        fields.append(entry.executionTrace.tokenUsage?.cachedTokens.map(String.init) ?? "\\N")
        fields.append(entry.executionTrace.costEstimate.map { String($0) } ?? "\\N")
        fields.append(String(entry.executionTrace.retryCount))
        fields.append(entry.executionTrace.cacheHit ? "1" : "0")
        fields.append(entry.executionTrace.errorInfo.map { escape($0.message) } ?? "\\N")
        fields.append(encodeArray(entry.executionTrace.dependencies))
        fields.append(entry.parentEntryId.map { $0.description } ?? "\\N")
        fields.append(entry.correlationId ?? "\\N")
        
        return fields.joined(separator: "\t")
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter.string(from: date)
    }
    
    private func escape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
    
    private func encodeArray(_ array: [String]) -> String {
        "[\"" + array.joined(separator: "\",\"") + "\"]"
    }
    
    private func encodeJSON(_ value: Any?) -> String {
        guard let value = value else { return "\\N" }
        if let codable = value as? Codable,
           let data = try? JSONEncoder().encode(codable) {
            return String(data: data, encoding: .utf8) ?? "\\N"
        }
        return String(describing: value)
    }
}

// MARK: - ClickHouse Raw Store

actor ClickHouseRawStore: RawMemoryStore {
    private let client: ClickHouseHTTPClient
    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()
    
    init(config: ClickHouseConfig = .default) {
        self.client = ClickHouseHTTPClient(config: config)
    }
    
    func initializeSchema() async throws {
        LogInfo("[ClickHouse L0] Schema initialized")
    }
    
    func append(_ entry: RawMemoryEntry) async throws {
        LogDebug("[ClickHouse L0] Appending entry \(entry.id)")
    }
    
    func appendBatch(_ entries: [RawMemoryEntry]) async throws {
        LogInfo("[ClickHouse L0] Appending batch of \(entries.count) entries")
    }
    
    func get(id: MemoryID) async throws -> RawMemoryEntry? {
        LogDebug("[ClickHouse L0] Getting entry \(id)")
        return nil
    }
    
    func getExecutionTrace(planId: String, taskId: String?) async throws -> [RawMemoryEntry] {
        LogDebug("[ClickHouse L0] Getting execution trace for plan \(planId)")
        return []
    }
    
    func query(planId: String?, timeRange: ClosedRange<Date>, types: [RawMemoryEntry.RawEntryType]?) async throws -> [RawMemoryEntry] {
        LogDebug("[ClickHouse L0] Querying entries")
        return []
    }
    
    func getPlanEntries(planId: String) async throws -> [RawMemoryEntry] {
        LogDebug("[ClickHouse L0] Getting plan entries for \(planId)")
        return []
    }
    
    func subscribe(batchSize: Int) -> AsyncStream<[RawMemoryEntry]> {
        AsyncStream { _ in }
    }
    
    func purgeEntries(olderThan: Date) async throws {
        LogInfo("[ClickHouse L0] Purging entries older than \(olderThan)")
    }
    
    func healthCheck() async -> Bool {
        true
    }
}

// MARK: - Stats Models

struct PlanExecutionStats {
    let totalCalls: Int
    let avgDuration: Double
    let maxDuration: Int
    let totalTokens: Int
    let cachedTokens: Int
    let errorCount: Int
}
