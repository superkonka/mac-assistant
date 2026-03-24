//
//  LLMProvider.swift
//  MacAssistant
//
//  LLM Provider 统一协议
//

import Foundation

// MARK: - 核心模型

struct LLMMessage {
    let role: LLMRole
    let content: String
    let images: [LLMImageAttachment]
    
    enum LLMRole: String {
        case system
        case user
        case assistant
    }
    
    init(role: LLMRole, content: String, images: [LLMImageAttachment] = []) {
        self.role = role
        self.content = content
        self.images = images
    }
}

struct LLMImageAttachment {
    let data: Data
    let mimeType: String
    
    init(data: Data, mimeType: String) {
        self.data = data
        self.mimeType = mimeType
    }
}

struct LLMRequest {
    let messages: [LLMMessage]
    let model: String
    let temperature: Double
    let maxTokens: Int
    let stream: Bool
}

struct LLMChunk {
    let content: String
    let finishReason: String?
}

struct LLMUsage {
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int
}

enum LLMError: Error {
    case invalidAPIKey
    case invalidResponse
    case rateLimited
    case serverError(Int)
    case networkError(Error)
    case unknown
    
    var localizedDescription: String {
        switch self {
        case .invalidAPIKey:
            return "API Key 无效"
        case .invalidResponse:
            return "响应格式错误"
        case .rateLimited:
            return "请求过于频繁"
        case .serverError(let code):
            return "服务器错误 (\(code))"
        case .networkError(let error):
            return "网络错误: \(error.localizedDescription)"
        case .unknown:
            return "未知错误"
        }
    }
}

// MARK: - Provider 协议

protocol LLMServiceProvider {
    var name: String { get }
    
    /// 发送请求（流式或非流式）
    func complete(
        request: LLMRequest,
        apiKey: String,
        baseURL: String,
        onChunk: ((String) async -> Void)?
    ) async throws -> String
}

// MARK: - 运行时指标

struct LLMMetrics {
    struct RequestRecord {
        let provider: String
        let model: String
        let startTime: Date
        var endTime: Date?
        var success: Bool
        var error: Error?
        var tokenCount: Int?
        var streaming: Bool
        
        var durationMs: Double {
            guard let end = endTime else { return 0 }
            return end.timeIntervalSince(startTime) * 1000
        }
    }
    
    private(set) var records: [RequestRecord] = []
    private let maxRecords = 100
    
    mutating func recordStart(provider: String, model: String, streaming: Bool) -> RequestRecord {
        let record = RequestRecord(
            provider: provider,
            model: model,
            startTime: Date(),
            endTime: nil,
            success: false,
            error: nil,
            tokenCount: nil,
            streaming: streaming
        )
        records.append(record)
        if records.count > maxRecords {
            records.removeFirst(records.count - maxRecords)
        }
        return record
    }
    
    mutating func recordEnd(record: inout RequestRecord, success: Bool, error: Error? = nil, tokenCount: Int? = nil) {
        record.endTime = Date()
        record.success = success
        record.error = error
        record.tokenCount = tokenCount
        
        // 更新 records 数组中的对应记录
        if let index = records.firstIndex(where: { $0.startTime == record.startTime }) {
            records[index] = record
        }
    }
    
    // 统计信息
    var totalRequests: Int { records.count }
    
    var successRate: Double {
        guard !records.isEmpty else { return 0 }
        let successes = records.filter { $0.success }.count
        return Double(successes) / Double(records.count) * 100
    }
    
    var averageLatencyMs: Double {
        guard !records.isEmpty else { return 0 }
        let durations = records.compactMap { $0.endTime != nil ? $0.durationMs : nil }
        guard !durations.isEmpty else { return 0 }
        return durations.reduce(0, +) / Double(durations.count)
    }
    
    var providerStats: [String: (requests: Int, avgLatency: Double)] {
        let grouped = Dictionary(grouping: records) { $0.provider }
        return grouped.mapValues { group in
            let count = group.count
            let avgLatency = group.compactMap { $0.endTime != nil ? $0.durationMs : nil }
                .reduce(0, +) / Double(max(group.count, 1))
            return (count, avgLatency)
        }
    }
}

// MARK: - 统一客户端

@MainActor
final class UnifiedLLMClient {
    static let shared = UnifiedLLMClient()
    
    private var providers: [String: LLMServiceProvider] = [:]
    private(set) var metrics = LLMMetrics()
    
    private init() {
        registerDefaultProviders()
    }
    
    private func registerDefaultProviders() {
        register(OpenAICompatibleProvider())
        register(AnthropicProvider())
        register(GoogleProvider())
    }
    
    func register(_ provider: LLMServiceProvider) {
        providers[provider.name.lowercased()] = provider
    }
    
    func provider(for name: String) -> LLMServiceProvider? {
        providers[name.lowercased()]
    }
    
    /// 获取指标摘要（用于调试和监控）
    func metricsSummary() -> String {
        let stats = metrics.providerStats
        let providerBreakdown = stats.map { provider, data in
            "  - \(provider): \(data.requests) 请求, 平均 \(String(format: "%.0f", data.avgLatency))ms"
        }.joined(separator: "\n")
        
        return """
        LLM 指标摘要:
        - 总请求数: \(metrics.totalRequests)
        - 成功率: \(String(format: "%.1f", metrics.successRate))%
        - 平均延迟: \(String(format: "%.0f", metrics.averageLatencyMs))ms
        按 Provider:
        \(providerBreakdown.isEmpty ? "  (暂无数据)" : providerBreakdown)
        """
    }
    
    /// 发送消息（带指标收集）
    func send(
        providerName: String,
        model: String,
        messages: [LLMMessage],
        temperature: Double,
        maxTokens: Int,
        apiKey: String,
        baseURL: String,
        stream: Bool,
        onChunk: ((String) async -> Void)? = nil
    ) async throws -> String {
        guard let provider = providers[providerName.lowercased()] else {
            throw LLMError.unknown
        }
        
        // 记录开始
        var record = metrics.recordStart(provider: providerName, model: model, streaming: stream)
        
        let request = LLMRequest(
            messages: messages,
            model: model,
            temperature: temperature,
            maxTokens: maxTokens,
            stream: stream
        )
        
        do {
            let response = try await provider.complete(
                request: request,
                apiKey: apiKey,
                baseURL: baseURL,
                onChunk: onChunk
            )
            
            // 记录成功
            let tokenEstimate = response.count / 4  // 粗略估算
            metrics.recordEnd(record: &record, success: true, tokenCount: tokenEstimate)
            
            return response
        } catch {
            // 记录失败
            metrics.recordEnd(record: &record, success: false, error: error)
            throw error
        }
    }
}
