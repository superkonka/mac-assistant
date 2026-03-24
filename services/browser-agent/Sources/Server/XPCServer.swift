//
//  XPCServer.swift
//  XPC 服务器 - 提供浏览器服务
//

import Foundation

/// XPC 服务器协议
@objc public protocol BrowserAgentXPCProtocol {
    func sendCommand(_ commandData: Data, reply: @escaping (Data?, Error?) -> Void)
    func checkPermission(reply: @escaping (Data?, Error?) -> Void)
}

/// XPC 服务器
public class BrowserAgentXPCServer: NSObject, BrowserAgentXPCProtocol {
    
    private let controller = BrowserController()
    private var listener: NSXPCListener?
    
    /// 启动服务器
    public func start() {
        let listener = NSXPCListener(machServiceName: "com.macassistant.browser-agent")
        listener.delegate = self
        listener.resume()
        self.listener = listener
        
        print("[BrowserAgent] XPC 服务器已启动")
    }
    
    /// 处理命令
    public func sendCommand(_ commandData: Data, reply: @escaping (Data?, Error?) -> Void) {
        Task {
            do {
                let command = try JSONDecoder().decode(BrowserCommand.self, from: commandData)
                let response = try await handleCommand(command)
                let responseData = try JSONEncoder().encode(response)
                reply(responseData, nil)
            } catch {
                reply(nil, error)
            }
        }
    }
    
    /// 检查权限
    public func checkPermission(reply: @escaping (Data?, Error?) -> Void) {
        Task {
            let status = await PermissionManager().checkPermission(for: .safari)
            let response = BrowserResponse.success(requestId: "permission-check", 
                                                   data: .permissionStatus(status))
            let data = try? JSONEncoder().encode(response)
            reply(data, nil)
        }
    }
    
    // MARK: - 私有方法
    
    private func handleCommand(_ command: BrowserCommand) async throws -> BrowserResponse {
        let requestId = UUID().uuidString
        
        switch command {
        case .startSession(let config):
            let sessionId = try await controller.startSession(config: config)
            return .success(requestId: requestId, data: .sessionCreated(sessionId: sessionId))
            
        case .navigate(let url, _):
            // 简化实现，实际需要 sessionId
            return .failure(requestId: requestId, 
                          error: BrowserError(code: .notImplemented, message: "需要 sessionId"))
            
        default:
            return .failure(requestId: requestId, 
                          error: BrowserError(code: .notImplemented, message: "命令未实现"))
        }
    }
}

extension BrowserAgentXPCServer: NSXPCListenerDelegate {
    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: BrowserAgentXPCProtocol.self)
        newConnection.exportedObject = self
        newConnection.resume()
        return true
    }
}
