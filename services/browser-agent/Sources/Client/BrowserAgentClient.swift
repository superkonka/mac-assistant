//
//  BrowserAgentClient.swift
//  浏览器服务客户端
//

import Foundation

/// 浏览器服务客户端
public class BrowserAgentClient: BrowserAgentProtocol {
    
    private var connection: NSXPCConnection?
    private let serviceName = "com.macassistant.browser-agent"
    
    /// 连接到服务
    public func connect() {
        let connection = NSXPCConnection(machServiceName: serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: BrowserAgentXPCProtocol.self)
        connection.resume()
        self.connection = connection
    }
    
    /// 断开连接
    public func disconnect() {
        connection?.invalidate()
        connection = nil
    }
    
    /// 发送命令
    public func sendCommand(_ command: BrowserCommand, timeout: TimeInterval = 30) async throws -> BrowserResponse {
        guard let connection = connection else {
            throw BrowserError(code: .internalError, message: "未连接到服务")
        }
        
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            print("[BrowserClient] XPC 错误: \(error)")
        } as? BrowserAgentXPCProtocol
        
        guard let proxy = proxy else {
            throw BrowserError(code: .internalError, message: "无法获取服务代理")
        }
        
        let commandData = try JSONEncoder().encode(command)
        
        return try await withCheckedThrowingContinuation { continuation in
            proxy.sendCommand(commandData) { data, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                guard let data = data else {
                    continuation.resume(throwing: BrowserError(code: .internalError, message: "无响应数据"))
                    return
                }
                
                do {
                    let response = try JSONDecoder().decode(BrowserResponse.self, from: data)
                    continuation.resume(returning: response)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// 启动会话
    public func startSession(config: SessionConfig) async throws -> String {
        let response = try await sendCommand(.startSession(config: config))
        
        guard response.success,
              case .sessionCreated(let sessionId) = response.data else {
            throw response.error ?? BrowserError(code: .internalError, message: "启动会话失败")
        }
        
        return sessionId
    }
    
    /// 结束会话
    public func endSession(sessionId: String) async throws {
        _ = try await sendCommand(.endSession(sessionId: sessionId))
    }
    
    /// 检查权限
    public func checkPermission() async throws -> PermissionStatus {
        guard let connection = connection else {
            throw BrowserError(code: .internalError, message: "未连接到服务")
        }
        
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in } as? BrowserAgentXPCProtocol
        
        return try await withCheckedThrowingContinuation { continuation in
            proxy?.checkPermission { data, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                guard let data = data,
                      let response = try? JSONDecoder().decode(BrowserResponse.self, from: data),
                      case .permissionStatus(let status) = response.data else {
                    continuation.resume(throwing: BrowserError(code: .internalError, message: "检查权限失败"))
                    return
                }
                
                continuation.resume(returning: status)
            }
        }
    }
}
