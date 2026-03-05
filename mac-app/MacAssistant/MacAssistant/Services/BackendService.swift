//
//  BackendService.swift
//  后端服务通信
//

import Foundation
import Combine

class BackendService: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isLoading = false
    @Published var isConnected = false
    
    private let baseURL = "http://127.0.0.1:8765"
    private var webSocketTask: URLSessionWebSocketTask?
    
    // MARK: - 健康检查
    
    func checkHealth() async -> Bool {
        guard let url = URL(string: "\(baseURL)/health") else { return false }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(HealthResponse.self, from: data)
            
            await MainActor.run {
                self.isConnected = (response.status == "ok")
            }
            return self.isConnected
        } catch {
            await MainActor.run {
                self.isConnected = false
            }
            return false
        }
    }
    
    // MARK: - 发送消息
    
    func sendMessage(_ content: String) async {
        await MainActor.run {
            isLoading = true
            messages.append(ChatMessage(role: .user, content: content, timestamp: Date()))
        }
        
        let requestBody = ChatMessage(role: .user, content: content)
        
        guard let url = URL(string: "\(baseURL)/chat"),
              let jsonData = try? JSONEncoder().encode(requestBody) else {
            await MainActor.run { isLoading = false }
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let response = try JSONDecoder().decode(ChatMessage.self, from: data)
            
            await MainActor.run {
                messages.append(response)
                isLoading = false
                saveHistory()
            }
        } catch {
            await MainActor.run {
                messages.append(ChatMessage(
                    role: .assistant,
                    content: "❌ 请求失败: \(error.localizedDescription)",
                    timestamp: Date()
                ))
                isLoading = false
            }
        }
    }
    
    // MARK: - 截图询问
    
    func takeScreenshotAndAsk() async {
        await MainActor.run { isLoading = true }
        
        let action = SystemAction(action: "screenshot", params: nil)
        
        guard let url = URL(string: "\(baseURL)/system"),
              let jsonData = try? JSONEncoder().encode(action) else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            
            // 截图成功后询问
            await sendMessage("我截了一张图，请帮我分析一下")
            
        } catch {
            await MainActor.run { isLoading = false }
        }
    }
    
    func takeScreenshot() {
        Task {
            let action = SystemAction(action: "screenshot", params: nil)
            
            guard let url = URL(string: "\(baseURL)/system"),
                  let jsonData = try? JSONEncoder().encode(action) else { return }
            
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = jsonData
            
            _ = try? await URLSession.shared.data(for: request)
        }
    }
    
    // MARK: - 剪贴板询问
    
    func askAboutClipboard() async {
        let action = SystemAction(action: "clipboard", params: nil)
        
        guard let url = URL(string: "\(baseURL)/system"),
              let jsonData = try? JSONEncoder().encode(action) else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let result = json["data"] as? [String: String],
               let text = result["text"] {
                await sendMessage("我剪贴板里有这些内容，帮我处理：\n\(text)")
            }
        } catch {
            print("剪贴板请求失败: \(error)")
        }
    }
    
    // MARK: - 历史记录
    
    func loadHistory() {
        // 从 UserDefaults 加载
        if let data = UserDefaults.standard.data(forKey: "chat_history"),
           let history = try? JSONDecoder().decode([ChatMessage].self, from: data) {
            messages = history
        }
    }
    
    func saveHistory() {
        // 保存到 UserDefaults
        if let data = try? JSONEncoder().encode(messages) {
            UserDefaults.standard.set(data, forKey: "chat_history")
        }
    }
    
    func clearHistory() {
        messages.removeAll()
        UserDefaults.standard.removeObject(forKey: "chat_history")
    }
    
    // MARK: - WebSocket
    
    func connectWebSocket() {
        guard let url = URL(string: "ws://127.0.0.1:8765/ws") else { return }
        
        webSocketTask = URLSession.shared.webSocketTask(with: url)
        webSocketTask?.resume()
        
        receiveMessage()
    }
    
    func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    if let data = text.data(using: .utf8),
                       let response = try? JSONDecoder().decode(ChatMessage.self, from: data) {
                        DispatchQueue.main.async {
                            self?.messages.append(response)
                        }
                    }
                default:
                    break
                }
                self?.receiveMessage()
            case .failure(let error):
                print("WebSocket 错误: \(error)")
            }
        }
    }
    
    func disconnectWebSocket() {
        webSocketTask?.cancel()
        webSocketTask = nil
    }
}
