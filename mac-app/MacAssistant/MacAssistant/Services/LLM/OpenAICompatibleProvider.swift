//
//  OpenAICompatibleProvider.swift
//  MacAssistant
//
//  OpenAI 兼容 Provider（支持 OpenAI、DeepSeek、Moonshot、Doubao、Zhipu）
//

import Foundation

struct OpenAICompatibleProvider: LLMServiceProvider {
    let name = "OpenAICompatible"
    
    func complete(
        request: LLMRequest,
        apiKey: String,
        baseURL: String,
        onChunk: ((String) async -> Void)?
    ) async throws -> String {
        let endpoint = URL(string: "\(normalizeBaseURL(baseURL))/chat/completions")!
        
        var messages: [[String: Any]] = request.messages.map { msg in
            var content: Any = msg.content
            
            // 如果有图片，构建多模态内容
            if !msg.images.isEmpty {
                var contentArray: [[String: Any]] = [
                    ["type": "text", "text": msg.content]
                ]
                for img in msg.images {
                    contentArray.append([
                        "type": "image_url",
                        "image_url": [
                            "url": "data:\(img.mimeType);base64,\(img.data.base64EncodedString())"
                        ]
                    ])
                }
                content = contentArray
            }
            
            return [
                "role": msg.role.rawValue,
                "content": content
            ]
        }
        
        var body: [String: Any] = [
            "model": request.model,
            "messages": messages,
            "stream": request.stream
        ]
        
        if request.temperature >= 0 {
            body["temperature"] = request.temperature
        }
        if request.maxTokens > 0 {
            body["max_tokens"] = request.maxTokens
        }
        
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        urlRequest.timeoutInterval = 120
        
        if request.stream && onChunk != nil {
            return try await performStreamingRequest(
                request: urlRequest,
                onChunk: onChunk!
            )
        } else {
            return try await performNonStreamingRequest(request: urlRequest)
        }
    }
    
    private func performNonStreamingRequest(request: URLRequest) async throws -> String {
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 {
                throw LLMError.invalidAPIKey
            } else if httpResponse.statusCode == 429 {
                throw LLMError.rateLimited
            } else {
                throw LLMError.serverError(httpResponse.statusCode)
            }
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw LLMError.invalidResponse
        }
        
        return content
    }
    
    private func performStreamingRequest(
        request: URLRequest,
        onChunk: @escaping (String) async -> Void
    ) async throws -> String {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw LLMError.invalidResponse
        }
        
        var fullContent = ""
        
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let dataContent = String(line.dropFirst(6))
            
            if dataContent == "[DONE]" { break }
            
            guard let data = dataContent.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any],
                  let content = delta["content"] as? String else {
                continue
            }
            
            fullContent += content
            await onChunk(fullContent)
        }
        
        return fullContent
    }
    
    private func normalizeBaseURL(_ url: String) -> String {
        var result = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }
}
