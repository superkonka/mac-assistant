//
//  BrowserController.swift
//  浏览器控制器 - 核心逻辑
//

import Foundation

/// 浏览器控制器 - 管理浏览器会话和操作
public actor BrowserController {
    
    private var sessions: [String: BrowserSession] = [:]
    private let permissionManager = PermissionManager()
    private let scriptRunner = AppleScriptRunner()
    
    // 启动新会话
    public func startSession(config: SessionConfig) async throws -> String {
        let permission = await permissionManager.checkPermission(for: config.browserType)
        guard permission.authorized else {
            throw BrowserError(
                code: .permissionNotGranted,
                message: "需要授权才能控制 \(config.browserType.rawValue)"
            )
        }
        
        let sessionId = UUID().uuidString
        sessions[sessionId] = BrowserSession(id: sessionId, config: config)
        
        // 激活浏览器
        try await activateBrowser(config.browserType)
        
        return sessionId
    }
    
    // 导航到URL
    public func navigate(sessionId: String, url: String) async throws -> PageInfo {
        guard sessions[sessionId] != nil else {
            throw BrowserError(code: .sessionNotFound, message: "会话不存在")
        }
        
        let script = buildNavigateScript(url: url)
        _ = try await scriptRunner.execute(script)
        
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        return try await getPageInfo(sessionId: sessionId)
    }
    
    // 执行JavaScript
    public func executeJavaScript(sessionId: String, script: String) async throws -> String {
        guard let session = sessions[sessionId] else {
            throw BrowserError(code: .sessionNotFound, message: "会话不存在")
        }
        
        let jsScript = buildJSScript(browser: session.config.browserType, script: script)
        return try await scriptRunner.execute(jsScript)
    }
    
    // 获取页面信息
    public func getPageInfo(sessionId: String) async throws -> PageInfo {
        let title = try await executeJavaScript(sessionId: sessionId, script: "document.title")
        let url = try await executeJavaScript(sessionId: sessionId, script: "location.href")
        return PageInfo(title: title, url: url, loading: false)
    }
    
    // 结束会话
    public func endSession(sessionId: String) async {
        sessions.removeValue(forKey: sessionId)
    }
    
    // MARK: - 私有方法
    
    private func activateBrowser(_ browser: BrowserType) async throws {
        let appName = browser == .chrome ? "Google Chrome" : "Safari"
        let script = "tell application \"\(appName)\" to activate"
        _ = try await scriptRunner.execute(script)
    }
    
    private func buildNavigateScript(url: String) -> String {
        return """
        tell application "Safari"
            activate
            if (count of windows) = 0 then make new document
            set URL of front document to "\(url)"
        end tell
        """
    }
    
    private func buildJSScript(browser: BrowserType, script: String) -> String {
        let escaped = script.replacingOccurrences(of: "\"", with: "\\\"")
        if browser == .chrome {
            return "tell application \"Google Chrome\" to tell active tab of front window to execute javascript \"\(escaped)\""
        }
        return "tell application \"Safari\" to tell front document to do JavaScript \"\(escaped)\""
    }
}

private struct BrowserSession {
    let id: String
    let config: SessionConfig
}
