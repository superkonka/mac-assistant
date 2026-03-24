//
//  AnthropicProvider.swift
//  MacAssistant
//
//  Anthropic Claude Provider (支持流式 SSE)
//

import Foundation

struct AnthropicProvider: LLMServiceProvider {
    let name = "Anthropic"
    
    func complete(
        request: LLMRequest,
        apiKey: String,
        baseURL: String,
        onChunk: ((String) async -> Void)?
    ) async throws -> String {
        let url = URL(string: "\(normalizeBaseURL(baseURL))/messages")!
        
        // Anthropic 格式转换
        var messages: [[String: Any]] = []
        var systemPrompt: String?
        
        for msg in request.messages {
            if msg.role == .system {
                systemPrompt = msg.content
                continue
            }
            
            var content: Any = msg.content
            if !msg.images.isEmpty {
                var contentArray: [[String: Any]] = [
                    ["type": "text", "text": msg.content]
                ]
                for img in msg.images {
                    contentArray.append([
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": img.mimeType,
                            "data": img.data.base64EncodedString()
                        ]
                    ])
                }
                content = contentArray
            }
            
            messages.append([
                "role": msg.role.rawValue,
                "content": content
            ])
        }
        
        var body: [String: Any] = [
            "model": request.model,
            "max_tokens": max(request.maxTokens, 1024),
            "messages": messages,
            "stream": request.stream
        ]
        
        if let system = systemPrompt {
            body["system"] = system
        }
        if request.temperature >= 0 {
            body["temperature"] = request.temperature
        }
        
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
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
            } else {
                throw LLMError.serverError(httpResponse.statusCode)
            }
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            throw LLMError.invalidResponse
        }
        
        let text = content.compactMap { block -> String? in
            guard (block["type"] as? String) == "text" else { return nil }
            return block["text"] as? String
        }.joined(separator: "\n")
        
        return text
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
        var currentEventType = ""
        
        for try await line in bytes.lines {
            // Anthropic SSE 格式: event: type / data: json
            if line.hasPrefix("event: ") {
                currentEventType = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                continue
            }
            
            guard line.hasPrefix("data: ") else { continue }
            let dataContent = String(line.dropFirst(6))
            
            // 解析事件数据
            guard let data = dataContent.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            
            let eventType = json["type"] as? String ?? currentEventType
            
            switch eventType {
            case "content_block_delta":
                if let delta = json["delta"] as? [String: Any],
                   let text = delta["text"] as? String {
                    fullContent += text
                    await onChunk(fullContent)
                }
            case "text_delta":
                // 直接文本增量
                if let text = json["text"] as? String {
                    fullContent += text
                    await onChunk(fullContent)
                }
            case "message_stop", "message_stop_event":
                // 流结束
                break
            default:
                // 忽略其他事件类型
                break
            }
        }
        
        return fullContent
    }
    
    private func normalizeBaseURL(_ url: String) -> String {
        var result = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasSuffix("/") {
            result.removeLast()
        }
        return result.isEmpty ? "https://api.anthropic.com/v1" : result
    }
}
