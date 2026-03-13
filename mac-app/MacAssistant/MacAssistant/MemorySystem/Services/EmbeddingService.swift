//
//  EmbeddingService.swift
//  MacAssistant
//
//  Phase 6: Embedding Generation Service for Vector Search
//

import Foundation

// MARK: - Embedding Service Protocol

/// 嵌入生成服务协议
protocol EmbeddingService: Actor {
    /// 服务名称
    var name: String { get }
    
    /// 嵌入维度
    var dimensions: Int { get }
    
    /// 最大并发请求数
    var maxConcurrentRequests: Int { get }
    
    /// 生成单个文本的嵌入向量
    func embed(text: String) async throws -> EmbeddingVector
    
    /// 批量生成嵌入向量
    func embedBatch(texts: [String]) async throws -> [EmbeddingVector]
    
    /// 计算两个向量的余弦相似度
    func cosineSimilarity(_ a: EmbeddingVector, _ b: EmbeddingVector) -> Float
    
    /// 健康检查
    func healthCheck() async -> Bool
}

// MARK: - OpenAI Embedding Service

actor OpenAIEmbeddingService: EmbeddingService {
    
    let name = "OpenAI"
    let dimensions: Int
    let maxConcurrentRequests: Int
    
    private let apiKey: String
    private let baseURL: String
    private let model: String
    private let urlSession: URLSession
    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()
    
    /// 当前并发请求数
    private var currentRequests = 0
    private let requestSemaphore: Semaphore
    
    init(
        apiKey: String,
        model: String = "text-embedding-3-small",
        baseURL: String = "https://api.openai.com/v1",
        maxConcurrentRequests: Int = 10
    ) {
        self.apiKey = apiKey
        self.model = model
        self.baseURL = baseURL
        self.dimensions = model.contains("3") ? 1536 : 1536  // text-embedding-3 supports dimensions param
        self.maxConcurrentRequests = maxConcurrentRequests
        self.requestSemaphore = Semaphore(value: maxConcurrentRequests)
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        self.urlSession = URLSession(configuration: config)
    }
    
    func embed(text: String) async throws -> EmbeddingVector {
        let results = try await embedBatch(texts: [text])
        guard let first = results.first else {
            throw EmbeddingError.emptyResponse
        }
        return first
    }
    
    func embedBatch(texts: [String]) async throws -> [EmbeddingVector] {
        guard !texts.isEmpty else { return [] }
        
        // 限制批处理大小（OpenAI 限制）
        let batchSize = 100
        var allEmbeddings: [EmbeddingVector] = []
        
        for chunk in texts.chunked(into: batchSize) {
            let embeddings = try await embedBatchChunk(texts: chunk)
            allEmbeddings.append(contentsOf: embeddings)
        }
        
        return allEmbeddings
    }
    
    private func embedBatchChunk(texts: [String]) async throws -> [EmbeddingVector] {
        await requestSemaphore.wait()
        defer { Task { await requestSemaphore.signal() } }
        
        let request = OpenAIEmbeddingRequest(
            input: texts,
            model: model,
            dimensions: dimensions
        )
        
        var urlRequest = URLRequest(url: URL(string: "\(baseURL)/embeddings")!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try jsonEncoder.encode(request)
        
        let (data, response) = try await urlSession.data(for: urlRequest)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw EmbeddingError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw EmbeddingError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
        }
        
        let embeddingResponse = try jsonDecoder.decode(OpenAIEmbeddingResponse.self, from: data)
        
        return embeddingResponse.data.map { item in
            EmbeddingVector(
                model: model,
                dimensions: item.embedding.count,
                vector: item.embedding.map { Float($0) },
                normalized: false
            )
        }
    }
    
    func cosineSimilarity(_ a: EmbeddingVector, _ b: EmbeddingVector) -> Float {
        guard a.vector.count == b.vector.count else { return 0 }
        
        var dotProduct: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        
        for i in 0..<a.vector.count {
            dotProduct += a.vector[i] * b.vector[i]
            normA += a.vector[i] * a.vector[i]
            normB += b.vector[i] * b.vector[i]
        }
        
        guard normA > 0 && normB > 0 else { return 0 }
        return dotProduct / (sqrt(normA) * sqrt(normB))
    }
    
    func healthCheck() async -> Bool {
        do {
            _ = try await embed(text: "health check")
            return true
        } catch {
            return false
        }
    }
}

// MARK: - OpenAI API Models

struct OpenAIEmbeddingRequest: Codable {
    let input: [String]
    let model: String
    let dimensions: Int?
    
    enum CodingKeys: String, CodingKey {
        case input, model, dimensions
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(input, forKey: .input)
        try container.encode(model, forKey: .model)
        if let dimensions = dimensions {
            try container.encode(dimensions, forKey: .dimensions)
        }
    }
}

struct OpenAIEmbeddingResponse: Codable {
    let data: [OpenAIEmbeddingData]
    let model: String
    let usage: OpenAIEmbeddingUsage
}

struct OpenAIEmbeddingData: Codable {
    let embedding: [Double]
    let index: Int
    let object: String
}

struct OpenAIEmbeddingUsage: Codable {
    let promptTokens: Int
    let totalTokens: Int
    
    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case totalTokens = "total_tokens"
    }
}

// MARK: - Local Embedding Service (Mock for now)

/// 本地嵌入模型服务（可用于离线场景或隐私保护）
actor LocalEmbeddingService: EmbeddingService {
    
    let name = "Local"
    let dimensions: Int
    let maxConcurrentRequests: Int
    
    private let modelPath: String?
    private var modelLoaded = false
    
    init(
        dimensions: Int = 384,  // 使用较小维度以提高性能
        modelPath: String? = nil,
        maxConcurrentRequests: Int = 5
    ) {
        self.dimensions = dimensions
        self.modelPath = modelPath
        self.maxConcurrentRequests = maxConcurrentRequests
    }
    
    func loadModel() async throws {
        // 实际实现：加载 Core ML 或 ONNX 模型
        // 这里使用 Mock 实现
        LogInfo("[LocalEmbedding] Loading model...")
        try await Task.sleep(nanoseconds: 500_000_000) // 模拟加载时间
        modelLoaded = true
        LogInfo("[LocalEmbedding] Model loaded successfully")
    }
    
    func embed(text: String) async throws -> EmbeddingVector {
        guard modelLoaded else {
            throw EmbeddingError.modelNotLoaded
        }
        
        // Mock 实现：基于文本哈希生成确定性向量
        // 实际实现：运行 Core ML/ONNX 模型推理
        let vector = generateDeterministicVector(from: text, dimensions: dimensions)
        
        return EmbeddingVector(
            model: "local-\(dimensions)d",
            dimensions: dimensions,
            vector: vector,
            normalized: true
        )
    }
    
    func embedBatch(texts: [String]) async throws -> [EmbeddingVector] {
        var results: [EmbeddingVector] = []
        for text in texts {
            let embedding = try await embed(text: text)
            results.append(embedding)
        }
        return results
    }
    
    func cosineSimilarity(_ a: EmbeddingVector, _ b: EmbeddingVector) -> Float {
        guard a.vector.count == b.vector.count else { return 0 }
        
        var dotProduct: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        
        for i in 0..<a.vector.count {
            dotProduct += a.vector[i] * b.vector[i]
            normA += a.vector[i] * a.vector[i]
            normB += b.vector[i] * b.vector[i]
        }
        
        guard normA > 0 && normB > 0 else { return 0 }
        return dotProduct / (sqrt(normA) * sqrt(normB))
    }
    
    func healthCheck() async -> Bool {
        modelLoaded
    }
    
    // MARK: - Private Methods
    
    private func generateDeterministicVector(from text: String, dimensions: Int) -> [Float] {
        // 使用文本哈希生成确定性向量（仅用于测试）
        var vector: [Float] = []
        var hash = text.hash
        
        for _ in 0..<dimensions {
            hash = hash &* 31 &+ 17
            let value = Float(hash % 1000) / 1000.0 * 2.0 - 1.0
            vector.append(value)
        }
        
        // 归一化
        let norm = sqrt(vector.map { $0 * $0 }.reduce(0, +))
        return vector.map { $0 / norm }
    }
}

// MARK: - Embedding Service Factory

actor EmbeddingServiceFactory {
    
    private static var sharedService: EmbeddingService?
    
    /// 创建默认的嵌入服务
    static func createDefault() -> EmbeddingService {
        // 优先使用 OpenAI，如果配置了 API Key
        if let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
           !apiKey.isEmpty {
            return OpenAIEmbeddingService(apiKey: apiKey)
        }
        
        // 否则使用本地服务
        return LocalEmbeddingService()
    }
    
    /// 创建 OpenAI 嵌入服务
    static func createOpenAI(
        apiKey: String,
        model: String = "text-embedding-3-small"
    ) -> EmbeddingService {
        OpenAIEmbeddingService(apiKey: apiKey, model: model)
    }
    
    /// 创建本地嵌入服务
    static func createLocal(
        dimensions: Int = 384,
        modelPath: String? = nil
    ) -> EmbeddingService {
        LocalEmbeddingService(dimensions: dimensions, modelPath: modelPath)
    }
    
    /// 获取共享服务实例（单例）
    static func shared() -> EmbeddingService {
        if let service = sharedService {
            return service
        }
        let service = createDefault()
        sharedService = service
        return service
    }
    
    /// 设置共享服务实例
    static func setShared(_ service: EmbeddingService) {
        sharedService = service
    }
}

// MARK: - Embedding Error

enum EmbeddingError: Error {
    case emptyResponse
    case invalidResponse
    case apiError(statusCode: Int, message: String)
    case modelNotLoaded
    case rateLimited
    case networkError(Error)
}

// MARK: - Semaphore

actor Semaphore {
    private var value: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    
    init(value: Int) {
        self.value = value
    }
    
    func wait() async {
        if value > 0 {
            value -= 1
        } else {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
    }
    
    func signal() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            value += 1
        }
    }
}

// MARK: - Array Extension

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

// MARK: - String Hash Extension

extension String {
    var hash: Int {
        var h = 0
        for char in self.unicodeScalars {
            h = h &* 31 &+ Int(char.value)
        }
        return h
    }
}
