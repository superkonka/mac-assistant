//
//  GoogleProvider.swift
//  MacAssistant
//
//  Google Gemini Provider
//

import Foundation

struct GoogleProvider: LLMServiceProvider {
    let name = "Google"
    
    func complete(
        request: LLMRequest,
        apiKey: String,
        baseURL: String,
        onChunk: ((String) async -> Void)?
    ) async throws -> String {
        // Google API Key 作为 query 参数
        var components = URLComponents(string: "\(normalizeBaseURL(baseURL))/models/\(request.model):generateContent")
        components?.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        
        guard let url = components?.url else {
            throw LLMError.invalidResponse
        }
        
        // 转换消息格式
        var parts: [[String: Any]] = []
        var systemPrompt: String?
        
        for msg in request.messages {
            if msg.role == .system {
                systemPrompt = msg.content
                continue
            }
            
            // Google 不支持多角色，合并到 parts
            var msgParts: [[String: Any]] = [["text": msg.content]]
            
            for img in msg.images {
                msgParts.append([
                    "inline_data": [
                        "mime_type": img.mimeType,
                        "data": img.data.base64EncodedString()
                    ]
                ])
            }
            
            parts.append(contentsOf: msgParts)
        }
        
        // 如果有 system prompt，加到用户消息前面
        var promptText = ""
        if let system = systemPrompt {
            promptText = "【系统提示】\n\(system)\n\n【用户请求】\n"
        }
        if let firstText = parts.first?["text"] as? String {
            promptText += firstText
            parts[0] = ["text": promptText]
        }
        
        var body: [String: Any] = [
            "contents": [
                ["role": "user", "parts": parts]
            ]
        ]
        
        var generationConfig: [String: Any] = [:]
        if request.temperature >= 0 {
            generationConfig["temperature"] = request.temperature
        }
        if request.maxTokens > 0 {
            generationConfig["maxOutputTokens"] = request.maxTokens
        }
        if !generationConfig.isEmpty {
            body["generationConfig"] = generationConfig
        }
        
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        urlRequest.timeoutInterval = 120
        
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 400 {
                // 可能是 API Key 问题
                throw LLMError.invalidAPIKey
            } else {
                throw LLMError.serverError(httpResponse.statusCode)
            }
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw LLMError.invalidResponse
        }
        
        let text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        return text
    }
    
    private func normalizeBaseURL(_ url: String) -> String {
        var result = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasSuffix("/") {
            result.removeLast()
        }
        return result.isEmpty ? "https://generativelanguage.googleapis.com/v1beta" : result
    }
}
