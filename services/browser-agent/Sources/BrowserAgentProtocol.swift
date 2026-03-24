//
//  BrowserAgentProtocol.swift
//  BrowserAgent 标准协议定义
//

import Foundation

// MARK: - 命令定义

public enum BrowserCommand: Codable {
    case navigate(url: String, waitForLoad: Bool)
    case executeJavaScript(script: String)
    case captureSnapshot(includeScreenshot: Bool)
    case captureScreenshot(fullPage: Bool)
    case getPageInfo
    case click(elementSelector: String)
    case fill(selector: String, value: String)
    case pressKey(key: String, modifiers: [String])
    case scroll(direction: ScrollDirection, amount: Int)
    case startSession(config: SessionConfig)
    case endSession(sessionId: String)
    case checkPermission
    
    public enum ScrollDirection: String, Codable {
        case up, down, left, right
    }
}

public struct SessionConfig: Codable {
    public let browserType: BrowserType
    public let headless: Bool
    public let windowSize: WindowSize?
    
    public init(browserType: BrowserType = .safari, 
                headless: Bool = false,
                windowSize: WindowSize? = nil) {
        self.browserType = browserType
        self.headless = headless
        self.windowSize = windowSize
    }
}

public enum BrowserType: String, Codable {
    case safari
    case chrome
    case edge
}

public struct WindowSize: Codable {
    public let width: Int
    public let height: Int
    
    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

// MARK: - 响应定义

public struct BrowserResponse: Codable {
    public let success: Bool
    public let requestId: String
    public let timestamp: Date
    public let data: BrowserData?
    public let error: BrowserError?
    
    public init(success: Bool, requestId: String, timestamp: Date = Date(), 
                data: BrowserData? = nil, error: BrowserError? = nil) {
        self.success = success
        self.requestId = requestId
        self.timestamp = timestamp
        self.data = data
        self.error = error
    }
    
    public static func success(requestId: String, data: BrowserData? = nil) -> BrowserResponse {
        return BrowserResponse(success: true, requestId: requestId, data: data)
    }
    
    public static func failure(requestId: String, error: BrowserError) -> BrowserResponse {
        return BrowserResponse(success: false, requestId: requestId, error: error)
    }
}

public enum BrowserData: Codable {
    case pageSnapshot(PageSnapshot)
    case screenshot(path: String, url: String?)
    case pageInfo(PageInfo)
    case jsResult(value: String)
    case actionResult(succeeded: Bool)
    case permissionStatus(PermissionStatus)
    case sessionCreated(sessionId: String)
    case void
    
    enum CodingKeys: String, CodingKey {
        case type, payload
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pageSnapshot(let snapshot):
            try container.encode("pageSnapshot", forKey: .type)
            try container.encode(snapshot, forKey: .payload)
        case .screenshot(let path, let url):
            try container.encode("screenshot", forKey: .type)
            try container.encode(["path": path, "url": url], forKey: .payload)
        case .pageInfo(let info):
            try container.encode("pageInfo", forKey: .type)
            try container.encode(info, forKey: .payload)
        case .jsResult(let value):
            try container.encode("jsResult", forKey: .type)
            try container.encode(["value": value], forKey: .payload)
        case .actionResult(let succeeded):
            try container.encode("actionResult", forKey: .type)
            try container.encode(["succeeded": succeeded], forKey: .payload)
        case .permissionStatus(let status):
            try container.encode("permissionStatus", forKey: .type)
            try container.encode(status, forKey: .payload)
        case .sessionCreated(let sessionId):
            try container.encode("sessionCreated", forKey: .type)
            try container.encode(["sessionId": sessionId], forKey: .payload)
        case .void:
            try container.encode("void", forKey: .type)
        }
    }
}

public struct BrowserError: Codable, Error {
    public let code: ErrorCode
    public let message: String
    public let details: [String: String]?
    
    public init(code: ErrorCode, message: String, details: [String: String]? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }
    
    public enum ErrorCode: String, Codable {
        // 权限错误
        case permissionDenied = "PERMISSION_DENIED"
        case permissionNotGranted = "PERMISSION_NOT_GRANTED"
        case permissionRestricted = "PERMISSION_RESTRICTED"
        
        // 浏览器错误
        case browserNotFound = "BROWSER_NOT_FOUND"
        case browserNotRunning = "BROWSER_NOT_RUNNING"
        case browserConnectionFailed = "BROWSER_CONNECTION_FAILED"
        
        // 导航错误
        case navigationFailed = "NAVIGATION_FAILED"
        case invalidURL = "INVALID_URL"
        case timeout = "TIMEOUT"
        
        // 执行错误
        case scriptExecutionFailed = "SCRIPT_EXECUTION_FAILED"
        case elementNotFound = "ELEMENT_NOT_FOUND"
        case actionFailed = "ACTION_FAILED"
        
        // 会话错误
        case sessionNotFound = "SESSION_NOT_FOUND"
        case sessionExpired = "SESSION_EXPIRED"
        
        // 通用错误
        case internalError = "INTERNAL_ERROR"
        case notImplemented = "NOT_IMPLEMENTED"
    }
}

// MARK: - 数据模型

public struct PageSnapshot: Codable {
    public let sessionId: String
    public let title: String
    public let url: String
    public let textExcerpt: String
    public let pageKind: PageKind
    public let authState: AuthState
    public let actionableElements: [ElementCandidate]
    public let screenshotPath: String?
    public let capturedAt: Date
    
    public init(sessionId: String, title: String, url: String, textExcerpt: String,
                pageKind: PageKind, authState: AuthState, 
                actionableElements: [ElementCandidate] = [],
                screenshotPath: String? = nil, capturedAt: Date = Date()) {
        self.sessionId = sessionId
        self.title = title
        self.url = url
        self.textExcerpt = textExcerpt
        self.pageKind = pageKind
        self.authState = authState
        self.actionableElements = actionableElements
        self.screenshotPath = screenshotPath
        self.capturedAt = capturedAt
    }
}

public enum PageKind: String, Codable {
    case login = "login"
    case dashboard = "dashboard"
    case search = "search"
    case form = "form"
    case article = "article"
    case list = "list"
    case checkout = "checkout"
    case chat = "chat"
    case unknown = "unknown"
}

public enum AuthState: String, Codable {
    case unknown = "unknown"
    case needsLogin = "needs_login"
    case needsScan = "needs_scan"
    case ready = "ready"
}

public struct ElementCandidate: Codable {
    public let label: String
    public let role: String
    public let selector: String?
    public let bounds: ElementBounds?
    
    public init(label: String, role: String, selector: String? = nil, bounds: ElementBounds? = nil) {
        self.label = label
        self.role = role
        self.selector = selector
        self.bounds = bounds
    }
}

public struct ElementBounds: Codable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
}

public struct PageInfo: Codable {
    public let title: String
    public let url: String
    public let loading: Bool
}

public struct PermissionStatus: Codable {
    public let authorized: Bool
    public let browserType: BrowserType
    public let canControlBrowser: Bool
    public let canCaptureScreen: Bool
}

// MARK: - 通信协议接口

public protocol BrowserAgentProtocol {
    func sendCommand(_ command: BrowserCommand, timeout: TimeInterval) async throws -> BrowserResponse
    func startSession(config: SessionConfig) async throws -> String
    func endSession(sessionId: String) async throws
    func checkPermission() async throws -> PermissionStatus
}

// MARK: - 事件流

public enum BrowserEvent: Codable {
    case pageLoaded(url: String, title: String)
    case pageLoadFailed(url: String, error: String)
    case navigationStarted(url: String)
    case actionExecuted(action: String, succeeded: Bool)
    case elementFound(selector: String, count: Int)
    case screenshotCaptured(path: String)
    case sessionExpired(sessionId: String)
    case permissionChanged(authorized: Bool)
}
