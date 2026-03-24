//
//  AIActionParser.swift
//  MacAssistant
//
//  AI浏览器动作解析器 - 将AI的自然语言转换为浏览器操作
//

import Foundation

// MARK: - AI浏览器动作
struct AIBrowserAction: Codable {
    let action: BrowserAction
    let params: [String: String]
    let reason: String
    
    init(action: BrowserAction, params: [String: String], reason: String = "") {
        self.action = action
        self.params = params
        self.reason = reason
    }
}

// MARK: - AI动作解析器
struct AIActionParser {
    
    /// 从AI响应中解析浏览器操作
    static func parseAIResponse(_ response: String) -> [AIBrowserAction] {
        var actions: [AIBrowserAction] = []
        
        // 1. 尝试解析JSON格式
        if let jsonActions = parseJSONActions(from: response) {
            return jsonActions
        }
        
        // 2. 解析自然语言指令
        actions.append(contentsOf: parseNaturalLanguage(from: response))
        
        return actions.isEmpty ? [defaultScreenshotAction()] : actions
    }
    
    /// 解析JSON格式的动作
    private static func parseJSONActions(from text: String) -> [AIBrowserAction]? {
        // 提取JSON代码块
        let jsonPattern = try? NSRegularExpression(pattern: "```json\\s*(\\{[\\s\\S]*?\\})\\s*```", options: [])
        let range = NSRange(location: 0, length: text.utf16.count)
        
        if let match = jsonPattern?.firstMatch(in: text, options: [], range: range),
           let jsonRange = Range(match.range(at: 1), in: text) {
            let jsonString = String(text[jsonRange])
            
            if let data = jsonString.data(using: .utf8),
               let action = try? JSONDecoder().decode(AIBrowserAction.self, from: data) {
                return [action]
            }
        }
        
        // 尝试直接解析整段文本为JSON
        if let data = text.data(using: .utf8),
           let action = try? JSONDecoder().decode(AIBrowserAction.self, from: data) {
            return [action]
        }
        
        return nil
    }
    
    /// 解析自然语言指令
    private static func parseNaturalLanguage(from text: String) -> [AIBrowserAction] {
        var actions: [AIBrowserAction] = []
        let lowercased = text.lowercased()
        
        // 导航操作
        if let url = extractURL(from: text) {
            if lowercased.contains("打开") || lowercased.contains("访问") || lowercased.contains("导航到") {
                actions.append(AIBrowserAction(
                    action: .navigate,
                    params: ["url": url],
                    reason: "用户要求访问网页"
                ))
            }
        }
        
        // 点击操作
        if lowercased.contains("点击") {
            if let selector = extractSelector(from: text) {
                actions.append(AIBrowserAction(
                    action: .click,
                    params: ["selector": selector],
                    reason: "用户要求点击元素"
                ))
            }
        }
        
        // 填写操作
        if lowercased.contains("填写") || lowercased.contains("输入") {
            if let (field, value) = extractFillInfo(from: text) {
                actions.append(AIBrowserAction(
                    action: .fill,
                    params: [
                        "selector": field,
                        "text": value
                    ],
                    reason: "用户要求填写表单"
                ))
            }
        }
        
        // 截图操作
        if lowercased.contains("截图") || lowercased.contains("屏幕") {
            actions.append(AIBrowserAction(
                action: .screenshot,
                params: [:],
                reason: "用户要求截图"
            ))
        }
        
        // 滚动操作
        if lowercased.contains("滚动") || lowercased.contains("下拉") {
            let direction = lowercased.contains("上") ? "up" : "down"
            actions.append(AIBrowserAction(
                action: .scroll,
                params: ["direction": direction],
                reason: "用户要求滚动页面"
            ))
        }
        
        // 后退/前进
        if lowercased.contains("后退") || lowercased.contains("返回") {
            actions.append(AIBrowserAction(
                action: .goBack,
                params: [:],
                reason: "用户要求返回上一页"
            ))
        }
        
        if lowercased.contains("前进") {
            actions.append(AIBrowserAction(
                action: .goForward,
                params: [:],
                reason: "用户要求前进"
            ))
        }
        
        // 等待操作
        if lowercased.contains("等待") {
            let seconds = extractNumber(from: text) ?? 2
            actions.append(AIBrowserAction(
                action: .wait,
                params: ["seconds": String(seconds)],
                reason: "用户要求等待"
            ))
        }
        
        return actions
    }
    
    /// 提取URL
    private static func extractURL(from text: String) -> String? {
        // URL正则匹配
        let pattern = try? NSRegularExpression(
            pattern: "(https?://[^\\s]+)|(www\\.[^\\s]+)|([a-zA-Z0-9.-]+\\.(com|cn|org|net|io|dev|app))",
            options: []
        )
        let range = NSRange(location: 0, length: text.utf16.count)
        
        if let match = pattern?.firstMatch(in: text, options: [], range: range),
           let urlRange = Range(match.range, in: text) {
            var url = String(text[urlRange])
            
            // 补全协议
            if !url.hasPrefix("http") {
                url = "https://" + url
            }
            
            return url
        }
        
        return nil
    }
    
    /// 提取CSS选择器
    private static func extractSelector(from text: String) -> String? {
        let lowercased = text.lowercased()
        
        // 常见的按钮/链接描述
        let patterns: [(pattern: String, selector: String)] = [
            ("登录按钮", "button:has-text('登录'), input[type='submit']"),
            ("提交按钮", "button[type='submit'], input[type='submit']"),
            ("搜索按钮", "button:has-text('搜索'), .search-btn"),
            ("确定按钮", "button:has-text('确定'), button:has-text('确认')"),
            ("取消按钮", "button:has-text('取消'), button:has-text('关闭')"),
        ]
        
        for (pattern, selector) in patterns {
            if lowercased.contains(pattern) {
                return selector
            }
        }
        
        // 尝试提取引号中的文本作为按钮文本
        let quotePattern = try? NSRegularExpression(pattern: "['\"]([^'\"]+)['\"]" , options: [])
        let range = NSRange(location: 0, length: text.utf16.count)
        if let match = quotePattern?.firstMatch(in: text, options: [], range: range),
           let quoteRange = Range(match.range(at: 1), in: text) {
            let buttonText = String(text[quoteRange])
            return "button:has-text('\(buttonText)'), a:has-text('\(buttonText)')"
        }
        
        return nil
    }
    
    /// 提取填写信息
    private static func extractFillInfo(from text: String) -> (field: String, value: String)? {
        // 模式：在"xxx"中填写"yyy"
        let pattern = try? NSRegularExpression(
            pattern: "在['\"]?([^'\"]+)['\"]?\\s*(?:中|里)\\s*(?:填写|输入)['\"]([^'\"]+)['\"]",
            options: []
        )
        let range = NSRange(location: 0, length: text.utf16.count)
        
        if let match = pattern?.firstMatch(in: text, options: [], range: range),
           let fieldRange = Range(match.range(at: 1), in: text),
           let valueRange = Range(match.range(at: 2), in: text) {
            let field = String(text[fieldRange])
            let value = String(text[valueRange])
            return (field, value)
        }
        
        // 简化模式：输入xxx到yyy
        let simplePattern = try? NSRegularExpression(
            pattern: "(?:输入|填写)['\"]?([^'\"]+)['\"]?\\s*(?:到|至|进)\\s*['\"]?([^'\"]+)['\"]?",
            options: []
        )
        if let match = simplePattern?.firstMatch(in: text, options: [], range: range),
           let valueRange = Range(match.range(at: 1), in: text),
           let fieldRange = Range(match.range(at: 2), in: text) {
            let value = String(text[valueRange])
            let field = String(text[fieldRange])
            return (field, value)
        }
        
        return nil
    }
    
    /// 提取数字
    private static func extractNumber(from text: String) -> Int? {
        let pattern = try? NSRegularExpression(pattern: "\\d+", options: [])
        let range = NSRange(location: 0, length: text.utf16.count)
        
        if let match = pattern?.firstMatch(in: text, options: [], range: range),
           let numberRange = Range(match.range, in: text) {
            return Int(text[numberRange])
        }
        
        return nil
    }
    
    /// 默认截图操作
    private static func defaultScreenshotAction() -> AIBrowserAction {
        AIBrowserAction(
            action: .screenshot,
            params: [:],
            reason: "无法解析指令，先截图查看当前状态"
        )
    }
    
    /// 生成AI提示词（用于让AI理解当前页面）
    static func generateAIPrompt(task: String, pageInfo: PageInfo) -> String {
        """
        你是一个浏览器自动化助手。请帮助用户完成以下任务：

        ## 任务
        \(task)

        ## 当前页面状态
        - URL: \(pageInfo.url)
        - 标题: \(pageInfo.title)
        - 加载状态: \(pageInfo.isLoading ? "加载中" : "已完成")

        ## 页面内容摘要
        \(pageInfo.textContent.prefix(3000))

        ## 可用操作
        1. `navigate` - 访问URL (参数: url)
        2. `click` - 点击元素 (参数: selector)
        3. `fill` - 填写输入框 (参数: selector, text)
        4. `screenshot` - 截图 (无参数)
        5. `scroll` - 滚动页面 (参数: direction [up/down])
        6. `wait` - 等待 (参数: seconds)
        7. `evaluate` - 执行JavaScript (参数: script)

        ## 响应格式
        请以以下JSON格式返回下一步操作：
        ```json
        {
            "action": "操作类型",
            "params": {
                "参数名": "参数值"
            },
            "reason": "说明为什么选择这个操作"
        }
        ```

        如果任务已完成，请返回：
        ```json
        {"action": "complete", "params": {}, "reason": "任务已完成"}
        ```
        """
    }
}

// MARK: - 页面信息
struct PageInfo {
    let url: String
    let title: String
    let isLoading: Bool
    let textContent: String
    let screenshot: String?  // base64
    
    init(url: String = "", title: String = "", isLoading: Bool = false, 
         textContent: String = "", screenshot: String? = nil) {
        self.url = url
        self.title = title
        self.isLoading = isLoading
        self.textContent = textContent
        self.screenshot = screenshot
    }
}

// MARK: - 智能任务模板
enum BrowserTaskTemplate {
    case search(query: String)
    case login(username: String, password: String)
    case fillForm(data: [String: String])
    case downloadFile(url: String)
    case extractData(selector: String)
    
    var actions: [AIBrowserAction] {
        switch self {
        case .search(let query):
            return [
                AIBrowserAction(action: .fill, params: [
                    "selector": "input[type='search'], input[name='q'], #search-input",
                    "text": query
                ]),
                AIBrowserAction(action: .click, params: [
                    "selector": "button[type='submit'], .search-button"
                ]),
                AIBrowserAction(action: .wait, params: ["seconds": "3"])
            ]
            
        case .login(let username, let password):
            return [
                AIBrowserAction(action: .fill, params: [
                    "selector": "input[name='username'], input[name='email'], input[type='email']",
                    "text": username
                ]),
                AIBrowserAction(action: .fill, params: [
                    "selector": "input[name='password'], input[type='password']",
                    "text": password
                ]),
                AIBrowserAction(action: .click, params: [
                    "selector": "button[type='submit'], .login-button"
                ]),
                AIBrowserAction(action: .wait, params: ["seconds": "2"])
            ]
            
        case .fillForm(let data):
            return data.map { field, value in
                AIBrowserAction(action: .fill, params: [
                    "selector": "input[name='\(field)'], textarea[name='\(field)']",
                    "text": value
                ])
            }
            
        case .downloadFile(let url):
            return [
                AIBrowserAction(action: .navigate, params: ["url": url]),
                AIBrowserAction(action: .wait, params: ["seconds": "5"])
            ]
            
        case .extractData(let selector):
            return [
                AIBrowserAction(action: .evaluate, params: [
                    "script": "Array.from(document.querySelectorAll('\(selector)')).map(el => el.innerText)"
                ])
            ]
        }
    }
}
