//
//  BackendService.swift
//  后端服务通信 - 支持自动重连
//

import Foundation
import Combine

class BackendService: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isLoading = false
    @Published var isConnected = false
    @Published var connectionError: String?
    
    private let baseURL = "http://127.0.0.1:8765"
    private var webSocketTask: URLSessionWebSocketTask?
    private var healthCheckTimer: Timer?
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5
    private var isReconnecting = false
    
    // MARK: - 初始化
    
    init() {
        // 启动健康检查定时器
        startHealthCheck()
        // 立即检查一次
        Task { await checkHealth() }
    }
    
    deinit {
        stopHealthCheck()
        disconnectWebSocket()
    }
    
    // MARK: - 健康检查与自动重连
    
    func startHealthCheck() {
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task {
                await self?.checkHealth()
            }
        }
    }
    
    func stopHealthCheck() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
    }
    
    func checkHealth() async -> Bool {
        guard let url = URL(string: "\(baseURL)/health") else { return false }
        
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                await handleDisconnection()
                return false
            }
            
            let health = try JSONDecoder().decode(HealthResponse.self, from: data)
            
            let wasConnected = isConnected
            let newConnected = health.status == "ok"
            
            await MainActor.run {
                isConnected = newConnected
                connectionError = nil
                
                // 如果之前断开现在恢复，重置重连计数
                if !wasConnected && newConnected {
                    reconnectAttempts = 0
                    isReconnecting = false
                    // 重新连接 WebSocket
                    connectWebSocket()
                }
            }
            
            return newConnected
            
        } catch {
            await handleDisconnection()
            return false
        }
    }
    
    func handleDisconnection() async {
        await MainActor.run {
            isConnected = false
        }
        
        // 尝试重连
        guard !isReconnecting && reconnectAttempts < maxReconnectAttempts else {
            if reconnectAttempts >= maxReconnectAttempts {
                await MainActor.run {
                    connectionError = "无法连接到后台服务，请检查服务是否运行"
                }
            }
            return
        }
        
        isReconnecting = true
        reconnectAttempts += 1
        
        let delay = min(Double(reconnectAttempts) * 2.0, 10.0) // 指数退避，最大10秒
        
        await MainActor.run {
            connectionError = "连接断开，正在尝试重连... (\(reconnectAttempts)/\(maxReconnectAttempts))"
        }
        
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        
        isReconnecting = false
        _ = await checkHealth()
    }
    
    // MARK: - 发送消息
    
    func sendMessage(_ content: String) async {
        guard isConnected else {
            await MainActor.run {
                messages.append(ChatMessage(
                    role: .assistant,
                    content: "⚠️ 服务未连接，请检查后台服务是否运行",
                    timestamp: Date()
                ))
            }
            return
        }
        
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
        request.timeoutInterval = 60 // AI 响应可能需要较长时间
        
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
            let (_, _) = try await URLSession.shared.data(for: request)
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
               let resultData = json["data"] as? [String: String],
               let text = resultData["text"], !text.isEmpty {
                await sendMessage("我剪贴板里有这些内容，帮我处理：\n```\n\(text.prefix(500))\n```")
            } else {
                await MainActor.run {
                    messages.append(ChatMessage(
                        role: .assistant,
                        content: "⚠️ 剪贴板为空或无法读取",
                        timestamp: Date()
                    ))
                }
            }
        } catch {
            print("剪贴板请求失败: \(error)")
        }
    }
    
    // MARK: - 历史记录
    
    func loadHistory() {
        if let data = UserDefaults.standard.data(forKey: "chat_history"),
           let history = try? JSONDecoder().decode([ChatMessage].self, from: data) {
            messages = history
        }
    }
    
    func saveHistory() {
        // 只保留最近 50 条
        let recentMessages = Array(messages.suffix(50))
        if let data = try? JSONEncoder().encode(recentMessages) {
            UserDefaults.standard.set(data, forKey: "chat_history")
        }
    }
    
    func clearHistory() {
        messages.removeAll()
        UserDefaults.standard.removeObject(forKey: "chat_history")
    }
    
    // MARK: - WebSocket 实时通信
    
    func connectWebSocket() {
        guard isConnected else { return }
        
        guard let url = URL(string: "ws://127.0.0.1:8765/ws") else { return }
        
        // 断开现有连接
        disconnectWebSocket()
        
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
                            self?.saveHistory()
                        }
                    }
                default:
                    break
                }
                self?.receiveMessage()
            case .failure(let error):
                print("WebSocket 错误: \(error)")
                // 连接断开，尝试重连
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    Task {
                        _ = await self?.checkHealth()
                    }
                }
            }
        }
    }
    
    func disconnectWebSocket() {
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
    }
}
