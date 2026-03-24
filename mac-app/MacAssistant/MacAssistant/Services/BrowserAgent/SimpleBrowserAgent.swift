//
//  SimpleBrowserAgent.swift
//  MacAssistant
//
//  简化的浏览器代理 - 使用系统浏览器 + AppleScript
//

import Foundation
import Combine
import AppKit
import CoreGraphics
import ApplicationServices

/// 简化的浏览器代理服务
/// 使用系统默认浏览器（Safari/Chrome）而不是嵌入式浏览器
@MainActor
final class SimpleBrowserAgent: ObservableObject {
    static let shared = SimpleBrowserAgent()
    
    // MARK: - Published State
    @Published var isRunning = false
    @Published var currentURL: String = ""
    @Published var browserName: String = "Safari"
    @Published var recentActions: [BrowserAction] = []
    
    // MARK: - Private
    private var cancellables = Set<AnyCancellable>()
    private let actionLimit = 50

    private struct SnapshotPayload: Decodable {
        struct ElementPayload: Decodable {
            let label: String
            let role: String
        }

        let title: String
        let url: String
        let textExcerpt: String
        let actionableElements: [ElementPayload]
    }
    
    struct BrowserAction: Identifiable {
        let id = UUID()
        let timestamp: Date
        let type: ActionType
        let description: String
        let status: ActionStatus
        
        enum ActionType: String {
            case navigate = "导航"
            case click = "点击"
            case fill = "填写"
            case screenshot = "截图"
            case script = "脚本"
        }
        
        enum ActionStatus {
            case success
            case failed(String)
            case pending
        }
    }
    
    private init() {
        detectDefaultBrowser()
    }
    
    // MARK: - 服务管理
    
    func start() {
        LogInfo("浏览器代理启动")
        isRunning = true
        logAction(.navigate, description: "浏览器代理已启动", status: .success)
    }
    
    func stop() {
        LogInfo("浏览器代理停止")
        isRunning = false
        logAction(.navigate, description: "浏览器代理已停止", status: .success)
    }
    
    // MARK: - 浏览器控制
    
    /// 检查 AppleScript 权限（使用与实际导航相同的权限级别）
    func checkAppleScriptAuthorization() async -> (authorized: Bool, error: String?, needsRestart: Bool) {
        LogInfo("[SafariPermission] 开始检查 AppleScript 权限...")
        
        // 使用与实际导航几乎相同的脚本进行测试
        let testScript = """
        tell application "Safari"
            activate
            if (count of windows) = 0 then
                make new document
            end if
            return "authorized"
        end tell
        """
        
        var errorInfo: NSDictionary?
        if let appleScript = NSAppleScript(source: testScript) {
            LogInfo("[SafariPermission] 执行权限检测脚本...")
            let result = appleScript.executeAndReturnError(&errorInfo)
            
            if let error = errorInfo {
                let errorNumber = error["NSAppleScriptErrorNumber"] as? Int ?? -1
                let errorMessage = error["NSAppleScriptErrorMessage"] as? String ?? "未知错误"
                LogError("[SafariPermission] 权限检测失败 - 错误码: \(errorNumber), 消息: \(errorMessage)")
                
                if errorNumber == -1743 {
                    return (false, "需要在「系统设置 > 隐私与安全性 > 自动化」中授权 MacAssistant 控制 Safari", false)
                }
                
                // 如果 Safari 正在运行但没有窗口，这也是权限不足的表现
                if errorMessage.contains("Not authorized") || errorMessage.contains("Authorization") {
                    return (false, "权限不足，请确保已授权 MacAssistant 控制 Safari", false)
                }
                
                // 其他错误（如 Safari 未安装）
                return (false, "AppleScript 错误: \(errorMessage)", false)
            }
            
            let resultValue = result.stringValue
            LogInfo("[SafariPermission] 权限检测成功，结果: \(resultValue ?? "nil")")
            
            // 检查是否返回了预期的结果
            if resultValue == "authorized" {
                LogInfo("[SafariPermission] 权限已授予，可以正常使用")
                return (true, nil, false)
            }
            
            // 如果返回了结果但不是预期的，可能是权限刚授予但需要重启
            LogInfo("[SafariPermission] 权限可能已授予但需要重启应用")
            return (true, nil, true)
        }
        LogError("[SafariPermission] 无法创建 AppleScript 对象")
        return (false, "无法创建 AppleScript", false)
    }
    
    /// 请求 Safari 权限（会触发系统授权对话框）
    func requestSafariPermission() {
        LogInfo("[SafariPermission] 开始请求 Safari 权限...")
        
        // 方法1: 尝试使用辅助功能 API（这会触发辅助功能权限弹窗）
        LogInfo("[SafariPermission] 尝试使用辅助功能 API...")
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let accessibilityEnabled = AXIsProcessTrustedWithOptions(options as CFDictionary)
        LogInfo("[SafariPermission] 辅助功能权限状态: \(accessibilityEnabled)")
        
        // 方法2: 触发一个需要 Safari 权限的简单操作
        let requestScript = """
        tell application "Safari"
            activate
        end tell
        """
        
        var errorInfo: NSDictionary?
        if let appleScript = NSAppleScript(source: requestScript) {
            LogInfo("[SafariPermission] 执行 AppleScript 请求权限...")
            let result = appleScript.executeAndReturnError(&errorInfo)
            
            if let error = errorInfo {
                let errorNumber = error["NSAppleScriptErrorNumber"] as? Int ?? -1
                let errorMessage = error["NSAppleScriptErrorMessage"] as? String ?? "未知错误"
                LogError("[SafariPermission] AppleScript 执行失败 - 错误码: \(errorNumber), 消息: \(errorMessage)")
            } else {
                LogInfo("[SafariPermission] AppleScript 执行成功，结果: \(result.stringValue ?? "nil")")
            }
        } else {
            LogError("[SafariPermission] 无法创建 AppleScript 对象")
        }
    }
    
    /// 导航到指定 URL，返回包含错误信息的详细结果
    func navigateWithResult(to urlString: String) async -> (success: Bool, errorMessage: String?) {
        LogInfo("开始导航到: \(urlString)")
        
        // 注意：不在这里检查权限，直接执行 AppleScript
        // 如果权限不足，系统会自动弹出授权对话框
        
        // 验证 URL 是否有效
        guard let url = URL(string: urlString), 
              url.scheme?.hasPrefix("http") == true else {
            LogError("无效的 URL 格式: \(urlString)")
            print("[DEBUG] 无效的 URL: \(urlString)")
            logAction(.navigate, description: "无效的 URL: \(urlString)", status: .failed("URL 格式错误"))
            return (false, "URL 格式无效")
        }
        
        // 对 URL 进行 AppleScript 安全编码（只需要处理引号）
        let safeURL = escapeAppleScriptLiteral(url.absoluteString)
        
        LogDebug("安全编码后的 URL: \(safeURL), 使用浏览器: \(browserName)")
        print("[DEBUG] 导航到: \(safeURL), 使用浏览器: \(browserName)")
        
        let script: String
        if browserName == "Safari" {
            script = """
            tell application "Safari"
                activate
                if (count of windows) = 0 then
                    make new document
                end if
                set URL of front document to "\(safeURL)"
            end tell
            """
        } else {
            script = """
            tell application "Google Chrome"
                activate
                if (count of windows) = 0 then
                    make new window
                end if
                set URL of active tab of front window to "\(safeURL)"
            end tell
            """
        }
        
        let result = await runAppleScript(script)
        if result {
            currentURL = url.absoluteString
            LogInfo("导航成功: \(url.absoluteString)")
            logAction(.navigate, description: "导航到 \(url.absoluteString)", status: .success)
            return (true, nil)
        } else {
            LogError("导航失败: \(url.absoluteString)")
            logAction(.navigate, description: "导航失败", status: .failed("AppleScript 执行失败"))
            return (false, "无法打开浏览器页面")
        }
    }
    
    /// 向后兼容的导航方法
    func navigate(to urlString: String) async -> Bool {
        let result = await navigateWithResult(to: urlString)
        return result.success
    }
    
    /// 在当前页面执行 JavaScript
    func executeJavaScript(_ script: String) async -> String? {
        LogDebug("执行 JavaScript: \(script.prefix(100))...")
        let safeScript = escapeJavaScriptForAppleScript(script)
        let fullScript: String
        if browserName == "Safari" {
            fullScript = """
            tell application "Safari"
                tell front document
                    do JavaScript "\(safeScript)"
                end tell
            end tell
            """
        } else {
            fullScript = """
            tell application "Google Chrome"
                tell active tab of front window
                    execute javascript "\(safeScript)"
                end tell
            end tell
            """
        }
        
        return await runAppleScriptWithOutput(fullScript)
    }
    
    /// 截取当前页面
    func screenshot() async -> NSImage? {
        guard let screenshotPath = await captureScreenshotFilePath() else {
            return nil
        }

        return NSImage(contentsOfFile: screenshotPath)
    }

    func captureScreenshotFilePath() async -> String? {
        LogDebug("开始捕获浏览器截图")
        let activated = await activateBrowserWindow()
        guard activated else {
            LogError("截图失败: 无法激活浏览器窗口")
            logAction(.screenshot, description: "浏览器截图失败", status: .failed("无法激活浏览器窗口"))
            return nil
        }

        try? await Task.sleep(nanoseconds: 350_000_000)

        guard let windowID = frontBrowserWindowID() else {
            LogError("截图失败: 未找到浏览器窗口 (browserName: \(browserName))")
            logAction(.screenshot, description: "浏览器截图失败", status: .failed("未找到浏览器窗口"))
            return nil
        }
        LogDebug("找到浏览器窗口 ID: \(windowID)")

        let outputURL = makeScreenshotURL()
        LogDebug("截图输出路径: \(outputURL.path)")
        let succeeded = await captureWindowScreenshot(windowID: windowID, outputURL: outputURL)
        guard succeeded, FileManager.default.fileExists(atPath: outputURL.path) else {
            LogError("截图失败: screencapture 执行失败或文件未生成")
            logAction(.screenshot, description: "浏览器截图失败", status: .failed("请检查屏幕录制权限"))
            return nil
        }

        LogInfo("截图成功: \(outputURL.path)")
        logAction(.screenshot, description: "截取当前浏览器窗口", status: .success)
        return outputURL.path
    }

    func captureSnapshot(includingScreenshot: Bool = true) async -> BrowserPageSnapshot? {
        LogDebug("开始抓取页面快照 (includingScreenshot: \(includingScreenshot))")
        let script = """
        (() => { const actionableElements = Array.from(document.querySelectorAll("button, a, input[type='submit'], input[type='button'], [role='button'], input[type='text'], input[type='email'], input[type='password']")).slice(0, 12).map((el) => ({ label: ((el.innerText || el.value || el.getAttribute('aria-label') || el.getAttribute('placeholder') || '').trim()).slice(0, 60), role: (el.tagName || '').toLowerCase() })); return JSON.stringify({ title: document.title || '', url: location.href || '', textExcerpt: ((document.body && document.body.innerText) || '').trim().slice(0, 2000), actionableElements }); })()
        """

        guard let payloadText = await executeJavaScript(script) else {
            LogError("执行 JavaScript 获取页面快照失败")
            return nil
        }
        
        guard let data = payloadText.data(using: .utf8) else {
            LogError("无法将页面快照数据编码为 UTF-8")
            return nil
        }
        
        guard let payload = try? JSONDecoder().decode(SnapshotPayload.self, from: data) else {
            LogError("无法解析页面快照 JSON，原始数据: \(payloadText.prefix(300))")
            return nil
        }
        
        LogDebug("页面快照抓取成功 - URL: \(payload.url), 标题: \(payload.title)")

        let elements = payload.actionableElements.map {
            BrowserElementCandidate(label: $0.label, role: $0.role)
        }
        let classification = BrowserPageAnalyzer.classify(
            title: payload.title,
            url: payload.url,
            textExcerpt: payload.textExcerpt,
            actionableElements: elements
        )

        currentURL = payload.url
        let screenshotPath = includingScreenshot ? await captureScreenshotFilePath() : nil
        logAction(.script, description: "抓取页面快照", status: .success)

        return BrowserPageSnapshot(
            title: payload.title,
            url: payload.url,
            textExcerpt: payload.textExcerpt,
            pageKind: classification.pageKind,
            authState: classification.authState,
            actionableElements: elements,
            screenshotPath: screenshotPath,
            capturedAt: Date()
        )
    }
    
    /// 获取当前页面信息
    func getPageInfo() async -> BrowserPageInfo? {
        let script: String
        if browserName == "Safari" {
            script = """
            tell application "Safari"
                set pageTitle to name of front document
                set pageURL to URL of front document
                return pageTitle & "|||" & pageURL
            end tell
            """
        } else {
            script = """
            tell application "Google Chrome"
                set pageTitle to title of active tab of front window
                set pageURL to URL of active tab of front window
                return pageTitle & "|||" & pageURL
            end tell
            """
        }
        
        guard let result = await runAppleScriptWithOutput(script) else {
            return nil
        }
        
        let parts = result.components(separatedBy: "|||")
        return BrowserPageInfo(
            title: parts.first ?? "",
            url: parts.count > 1 ? parts[1] : ""
        )
    }
    
    /// 执行 WhatsApp 自动化任务
    func executeWhatsAppTask(_ task: WhatsAppTask) async -> TaskResult {
        // 首先确保在 WhatsApp 网页
        if !currentURL.contains("web.whatsapp.com") {
            let success = await navigate(to: "https://web.whatsapp.com")
            guard success else {
                return .failed("无法导航到 WhatsApp")
            }
            // 等待页面加载
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
        
        switch task {
        case .sendMessage(let contact, let message):
            return await sendWhatsAppMessage(to: contact, message: message)
            
        case .searchContact(let name):
            return await searchWhatsAppContact(name: name)
            
        case .getUnreadMessages:
            return await getWhatsAppUnreadMessages()
        }
    }
    
    // MARK: - WhatsApp 具体操作
    
    private func sendWhatsAppMessage(to contact: String, message: String) async -> TaskResult {
        // 1. 搜索联系人
        let searchScript = """
        // 点击搜索框
        document.querySelector('[data-testid="chat-list-search"]').click();
        // 输入联系人名称
        document.querySelector('[data-testid="chat-list-search"]').value = '\(contact)';
        // 触发输入事件
        document.querySelector('[data-testid="chat-list-search"]').dispatchEvent(new Event('input'));
        """
        
        _ = await executeJavaScript(searchScript)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        
        // 2. 点击第一个结果
        let clickScript = """
        document.querySelector('[data-testid="chat-list-item"]').click();
        """
        _ = await executeJavaScript(clickScript)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        
        // 3. 输入消息
        let inputScript = """
        document.querySelector('[data-testid="conversation-compose-box-input"]').innerHTML = '\(message)';
        """
        _ = await executeJavaScript(inputScript)
        
        // 4. 发送
        let sendScript = """
        document.querySelector('[data-testid="send"]').click();
        """
        _ = await executeJavaScript(sendScript)
        
        logAction(.fill, description: "发送消息给 \(contact)", status: .success)
        return .success("消息已发送给 \(contact)")
    }
    
    private func searchWhatsAppContact(name: String) async -> TaskResult {
        let script = """
        document.querySelector('[data-testid="chat-list-search"]').click();
        document.querySelector('[data-testid="chat-list-search"]').value = '\(name)';
        document.querySelector('[data-testid="chat-list-search"]').dispatchEvent(new Event('input'));
        """
        
        _ = await executeJavaScript(script)
        logAction(.click, description: "搜索联系人: \(name)", status: .success)
        return .success("已搜索 \(name)")
    }
    
    private func getWhatsAppUnreadMessages() async -> TaskResult {
        let script = """
        var chats = document.querySelectorAll('[data-testid="chat-list-item"]');
        var unread = [];
        chats.forEach(chat => {
            var badge = chat.querySelector('[data-testid="icon-unread-count"]');
            if (badge) {
                var name = chat.querySelector('[data-testid="chat-list-item-title"]').innerText;
                var count = badge.innerText;
                unread.push(name + ': ' + count);
            }
        });
        return unread.join(', ');
        """
        
        guard let result = await executeJavaScript(script) else {
            return .failed("无法获取未读消息")
        }
        
        logAction(.script, description: "获取未读消息", status: .success)
        return .success(result)
    }
    
    // MARK: - 辅助方法
    
    private func detectDefaultBrowser() {
        // 检测默认浏览器
        let script = """
        tell application "System Events"
            return name of first application of (get processes whose frontmost is true)
        end tell
        """
        
        Task {
            LogDebug("开始检测默认浏览器...")
            if let result = await runAppleScriptWithOutput(script) {
                if result.contains("Chrome") {
                    browserName = "Google Chrome"
                    LogInfo("检测到默认浏览器: Google Chrome")
                } else {
                    browserName = "Safari"
                    LogInfo("检测到默认浏览器: Safari")
                }
            } else {
                LogWarning("无法检测默认浏览器，使用默认 Safari")
            }
        }
    }

    private func escapeAppleScriptLiteral(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func escapeJavaScriptForAppleScript(_ script: String) -> String {
        script
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    private func activateBrowserWindow() async -> Bool {
        LogDebug("尝试激活浏览器窗口: \(browserName)")
        let script = """
        tell application "\(browserName)"
            activate
        end tell
        """
        let result = await runAppleScript(script)
        if !result {
            LogError("激活浏览器窗口失败: \(browserName)")
        }
        return result
    }

    private func frontBrowserWindowID() -> CGWindowID? {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            LogError("无法获取窗口列表")
            return nil
        }
        
        LogDebug("扫描窗口列表，寻找 \(browserName) 窗口...")
        let ownerNames = browserOwnerNames()
        var foundWindows: [(name: String, layer: Int, alpha: Double, windowID: CGWindowID)] = []
        
        for windowInfo in windowList {
            let ownerName = (windowInfo[kCGWindowOwnerName as String] as? String) ?? ""
            let layer = (windowInfo[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            let alpha = (windowInfo[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            
            if ownerNames.contains(where: { ownerName.localizedCaseInsensitiveContains($0) || $0.localizedCaseInsensitiveContains(ownerName) }) {
                if let windowNumber = windowInfo[kCGWindowNumber as String] as? NSNumber {
                    foundWindows.append((ownerName, layer, alpha, CGWindowID(windowNumber.uint32Value)))
                }
            }
        }
        
        LogDebug("找到 \(foundWindows.count) 个 \(browserName) 窗口: \(foundWindows.map { "[\($0.name) layer:\($0.layer) alpha:\($0.alpha)]" })")
        
        for windowInfo in windowList {
            let ownerName = (windowInfo[kCGWindowOwnerName as String] as? String) ?? ""
            let layer = (windowInfo[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            let alpha = (windowInfo[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            guard layer == 0, alpha > 0 else { continue }

            guard ownerNames.contains(where: { ownerName.localizedCaseInsensitiveContains($0) || $0.localizedCaseInsensitiveContains(ownerName) }) else {
                continue
            }

            if let windowNumber = windowInfo[kCGWindowNumber as String] as? NSNumber {
                LogDebug("选择窗口 ID: \(windowNumber.uint32Value), owner: \(ownerName)")
                return CGWindowID(windowNumber.uint32Value)
            }
        }

        LogError("未找到有效的 \(browserName) 窗口")
        return nil
    }

    private func browserOwnerNames() -> [String] {
        if browserName.localizedCaseInsensitiveContains("chrome") {
            return ["Google Chrome", "Chrome"]
        }
        return ["Safari"]
    }

    private func makeScreenshotURL() -> URL {
        let filename = "macassistant-browser-\(UUID().uuidString).png"
        return FileManager.default.temporaryDirectory.appendingPathComponent(filename)
    }

    private func captureWindowScreenshot(windowID: CGWindowID, outputURL: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-l", String(windowID), outputURL.path]
            process.terminationHandler = { proc in
                let success = proc.terminationStatus == 0
                if !success {
                    LogError("screencapture 失败，退出码: \(proc.terminationStatus)")
                }
                continuation.resume(returning: success)
            }

            do {
                try process.run()
            } catch {
                LogError("启动 screencapture 失败: \(error)")
                continuation.resume(returning: false)
            }
        }
    }
    
    private func runAppleScript(_ script: String) async -> Bool {
        LogDebug("执行 AppleScript: \(script.prefix(200))...")
        return await withCheckedContinuation { continuation in
            var errorInfo: NSDictionary?
            if let appleScript = NSAppleScript(source: script) {
                appleScript.executeAndReturnError(&errorInfo)
                if let error = errorInfo {
                    let errorMessage = error["NSAppleScriptErrorMessage"] as? String ?? "未知错误"
                    let errorNumber = error["NSAppleScriptErrorNumber"] as? Int ?? -1
                    let errorBrief = error["NSAppleScriptErrorBriefMessage"] as? String ?? ""
                    LogError("AppleScript 执行失败 - \(errorMessage) (错误码: \(errorNumber)), 脚本: \(script.prefix(200))")
                    print("[DEBUG] AppleScript 错误: \(error)")
                } else {
                    LogDebug("AppleScript 执行成功")
                }
                continuation.resume(returning: errorInfo == nil)
            } else {
                LogError("无法创建 AppleScript 对象")
                print("[DEBUG] 无法创建 AppleScript")
                continuation.resume(returning: false)
            }
        }
    }
    
    private func runAppleScriptWithOutput(_ script: String) async -> String? {
        LogDebug("执行 AppleScript (带输出): \(script.prefix(200))...")
        return await withCheckedContinuation { continuation in
            var errorInfo: NSDictionary?
            if let appleScript = NSAppleScript(source: script) {
                let result = appleScript.executeAndReturnError(&errorInfo)
                let output = result.stringValue
                if let error = errorInfo {
                    let errorMessage = error["NSAppleScriptErrorMessage"] as? String ?? "未知错误"
                    let errorNumber = error["NSAppleScriptErrorNumber"] as? Int ?? -1
                    LogError("AppleScript (带输出) 执行失败 - \(errorMessage) (错误码: \(errorNumber)), 脚本: \(script.prefix(200))")
                } else {
                    LogDebug("AppleScript (带输出) 执行成功，输出长度: \(output?.count ?? 0)")
                }
                continuation.resume(returning: output)
            } else {
                LogError("无法创建 AppleScript (带输出) 对象")
                continuation.resume(returning: nil)
            }
        }
    }
    
    private func logAction(_ type: BrowserAction.ActionType, description: String, status: BrowserAction.ActionStatus) {
        let action = BrowserAction(
            timestamp: Date(),
            type: type,
            description: description,
            status: status
        )
        recentActions.insert(action, at: 0)
        if recentActions.count > actionLimit {
            recentActions = Array(recentActions.prefix(actionLimit))
        }
    }
}

// MARK: - 数据类型

struct BrowserPageInfo {
    let title: String
    let url: String
}

enum WhatsAppTask {
    case sendMessage(contact: String, message: String)
    case searchContact(name: String)
    case getUnreadMessages
}

enum TaskResult {
    case success(String)
    case failed(String)
}
