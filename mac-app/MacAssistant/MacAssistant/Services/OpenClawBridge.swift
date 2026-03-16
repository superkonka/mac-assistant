//
//  OpenClawBridge.swift
//  MacAssistant
//
//  OpenClaw Kimi 桥接服务 - 简化版（非流式）
//

import Foundation
import Network

class OpenClawBridge {
    static let shared = OpenClawBridge()
    
    private var listener: NWListener?
    private var isRunning = false
    private let port: UInt16 = 11434
    
    func start() {
        guard !isRunning else { return }
        
        do {
            listener = try NWListener(using: .tcp, on: NWEndpoint.Port(integerLiteral: port))
            
            listener?.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    LogInfo("🌉 OpenClawBridge 已启动，端口 \(self.port)")
                    self.isRunning = true
                case .failed(let error):
                    LogError("🌉 Bridge 启动失败", error: error)
                default: break
                }
            }
            
            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            
            listener?.start(queue: .global())
        } catch {
            LogError("🌉 创建 Listener 失败", error: error)
        }
    }
    
    func stop() {
        listener?.cancel()
        isRunning = false
    }
    
    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global())
        
        receiveRequest(connection) { [weak self] request in
            guard let self = self, let request = request else {
                self?.sendResponse(connection, status: 400, body: "{\"error\": \"Bad Request\"}")
                return
            }
            
            self.processRequest(connection, request: request)
        }
    }
    
    private func processRequest(_ connection: NWConnection, request: HTTPRequest) {
        switch request.path {
        case "/api/tags":
            sendResponse(connection, status: 200, body: localModelsResponseBody())
            
        case "/api/generate":
            handleGenerate(connection, request: request)
            
        case "/api/chat":
            handleChat(connection, request: request)
            
        default:
            sendResponse(connection, status: 404, body: "{\"error\": \"Not Found\"}")
        }
    }
    
    private func handleGenerate(_ connection: NWConnection, request: HTTPRequest) {
        guard let body = request.body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let prompt = json["prompt"] as? String else {
            sendResponse(connection, status: 400, body: "{\"error\": \"Invalid request\"}")
            return
        }
        
        // 异步调用 Kimi，避免阻塞
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            
            LogDebug("🌉 Bridge 调用 Kimi: \(prompt.prefix(30))...")
            let result = self.callKimi(prompt: prompt, files: [])
            
            let responseBody = """
            {"model":"kimi-local","created_at":"\(self.isoDate())","response":"\(self.escapeJSON(result))","done":true}
            """
            
            self.sendResponse(connection, status: 200, body: responseBody)
        }
    }
    
    private func handleChat(_ connection: NWConnection, request: HTTPRequest) {
        guard let body = request.body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let messages = json["messages"] as? [[String: Any]],
              let lastMsg = messages.last(where: { $0["role"] as? String == "user" }) else {
            sendResponse(connection, status: 400, body: "{\"error\": \"Invalid request\"}")
            return
        }

        let content = (lastMsg["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let files = (json["images"] as? [String] ?? [])
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            
            let effectivePrompt = content.isEmpty && !files.isEmpty ? "请分析这张图片。" : content
            LogDebug("🌉 Bridge 调用 Kimi (chat): \(effectivePrompt.prefix(30))...")
            let result = self.callKimi(prompt: effectivePrompt, files: files)
            
            let responseBody = """
            {"model":"kimi-local","created_at":"\(self.isoDate())","message":{"role":"assistant","content":"\(self.escapeJSON(result))"},"done":true}
            """
            
            self.sendResponse(connection, status: 200, body: responseBody)
        }
    }
    
    private func callKimi(prompt: String, files: [String]) -> String {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedPrompt.isEmpty && files.isEmpty {
            return "我这次没有拿到要发送的文字内容，所以还没法继续调用本地 Kimi CLI。你可以把刚才的问题再发一次。"
        }

        if let attachmentError = unsupportedAttachmentMessage(for: files) {
            return attachmentError
        }

        let finalPrompt = composePrompt(prompt: trimmedPrompt, files: files)

        let task = Process()
        let pipe = Pipe()

        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["kimi", "-p", finalPrompt]
        task.standardOutput = pipe
        task.standardError = pipe
        
        var env = ProcessInfo.processInfo.environment
        let localBin = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path
        env["PATH"] = "\(localBin):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        task.environment = env
        
        do {
            try task.run()
            
            // 设置 2 分钟超时
            let timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { _ in
                if task.isRunning {
                    task.terminate()
                    LogError("🌉 Kimi 调用超时", error: NSError(domain: "OpenClawBridge", code: -1))
                }
            }
            
            task.waitUntilExit()
            timer.invalidate()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let rawOutput = String(data: data, encoding: .utf8) ?? ""
            return UserFacingErrorFormatter.normalizeCLIOutput(rawOutput, providerName: "本地 Kimi CLI")
        } catch {
            return UserFacingErrorFormatter.inlineMessage(for: error, providerName: "本地 Kimi CLI")
        }
    }

    private func unsupportedAttachmentMessage(for files: [String]) -> String? {
        let imageExtensions = Set(["png", "jpg", "jpeg", "webp", "gif", "heic", "bmp", "tiff"])
        let imageFiles = files.filter { file in
            imageExtensions.contains(URL(fileURLWithPath: file).pathExtension.lowercased())
        }

        if !imageFiles.isEmpty {
            return "当前本地 Kimi CLI 不支持图片附件分析，因此无法直接查看截图。请切换到支持视觉的 API Agent。"
        }

        return nil
    }

    private func composePrompt(prompt: String, files: [String]) -> String {
        let textAttachments = files.compactMap(readTextAttachment)
        if textAttachments.isEmpty {
            return prompt.isEmpty ? "请分析以下内容。" : prompt
        }

        let attachmentBlock = textAttachments.joined(separator: "\n\n")
        if prompt.isEmpty {
            return attachmentBlock
        }

        return "\(attachmentBlock)\n\n\(prompt)"
    }

    private func readTextAttachment(at path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        let textExtensions = Set([
            "txt", "md", "markdown", "json", "yaml", "yml", "xml",
            "swift", "py", "js", "ts", "tsx", "jsx", "html", "css",
            "sh", "zsh", "bash", "log", "csv"
        ])

        guard textExtensions.contains(url.pathExtension.lowercased()),
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }

        return "附件文件: \(path)\n\(content)"
    }

    private func localModelsResponseBody() -> String {
        let models = AgentStore.shared.usableAgents
            .map { agent in
                [
                    "name": agent.model,
                    "model": agent.model,
                    "modified_at": "2024-01-01T00:00:00Z",
                    "size": 0,
                    "digest": "kimi"
                ] as [String: Any]
            }

        let payload: [String: Any] = ["models": models]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let body = String(data: data, encoding: .utf8) else {
            return "{\"models\":[]}"
        }

        return body
    }
    
    private func receiveRequest(_ connection: NWConnection, completion: @escaping (HTTPRequest?) -> Void) {
        var data = Data()
        
        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { content, _, isComplete, error in
                if let content = content {
                    data.append(content)
                }
                
                if isComplete || self.isCompleteHTTP(data) {
                    completion(self.parseHTTP(data))
                    return
                }
                
                if error != nil {
                    completion(nil)
                    return
                }
                
                receive()
            }
        }
        
        // 5秒超时
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            if data.isEmpty {
                completion(nil)
            }
        }
        
        receive()
    }
    
    private func isCompleteHTTP(_ data: Data) -> Bool {
        guard let str = String(data: data, encoding: .utf8),
              let headerEnd = str.range(of: "\r\n\r\n") else { return false }
        
        let headers = String(str[..<headerEnd.lowerBound])
        if let match = headers.range(of: "Content-Length: ", options: .caseInsensitive) {
            let start = headers.index(match.upperBound, offsetBy: 0)
            let end = headers[start...].firstIndex(where: { $0.isNewline }) ?? headers.endIndex
            if let length = Int(headers[start..<end].trimmingCharacters(in: .whitespaces)) {
                let bodyStart = str.index(headerEnd.upperBound, offsetBy: 0)
                return str[bodyStart...].utf8.count >= length
            }
        }
        return headers.hasPrefix("GET ") || headers.hasPrefix("HEAD ")
    }
    
    private func parseHTTP(_ data: Data) -> HTTPRequest? {
        guard let str = String(data: data, encoding: .utf8) else { return nil }
        let lines = str.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        
        let parts = first.components(separatedBy: " ")
        guard parts.count >= 2 else { return nil }
        
        var body: Data?
        if let range = str.range(of: "\r\n\r\n") {
            body = String(str[range.upperBound...]).data(using: .utf8)
        }
        
        return HTTPRequest(method: parts[0], path: parts[1], body: body)
    }
    
    private func sendResponse(_ connection: NWConnection, status: Int, body: String) {
        let response = """
        HTTP/1.1 \(status) \(statusText(status))\r\n\
        Content-Type: application/json\r\n\
        Content-Length: \(body.utf8.count)\r\n\
        Connection: close\r\n\r\n\
        \(body)
        """
        
        connection.send(content: response.data(using: .utf8)!, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
    
    private func statusText(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        default: return "Error"
        }
    }
    
    private func isoDate() -> String {
        return ISO8601DateFormatter().string(from: Date())
    }
    
    private func escapeShell(_ str: String) -> String {
        return "'" + str.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    
    private func escapeJSON(_ str: String) -> String {
        return str
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}

struct HTTPRequest {
    let method: String
    let path: String
    let body: Data?
}
