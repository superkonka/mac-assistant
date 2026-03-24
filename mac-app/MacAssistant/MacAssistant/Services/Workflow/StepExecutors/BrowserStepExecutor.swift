//
//  BrowserStepExecutor.swift
//  MacAssistant
//
//  Browser 步骤执行器
//

import Foundation

@MainActor
final class BrowserStepExecutor: StepExecutor {
    static let shared = BrowserStepExecutor()
    
    let supportedKinds: [WorkflowStepKind] = [.action]
    let supportedBindingKinds: [WorkflowBindingKind] = [.browser]
    
    private let browserAgent = SimpleBrowserAgent.shared
    private var activeRuns: Set<String> = []
    
    private init() {}
    
    func isAvailable() async -> Bool {
        // 检查浏览器是否可用
        return true
    }
    
    func cancel(runID: String) {
        activeRuns.remove(runID)
        LogInfo("[BrowserStepExecutor] 取消执行: \(runID)")
    }
    
    func execute(_ step: WorkflowStepDef, context: WorkflowContext) async -> StepExecutionResult {
        guard !activeRuns.contains(context.runID) else {
            return .failure(error: .cancelled)
        }
        
        activeRuns.insert(context.runID)
        defer { activeRuns.remove(context.runID) }
        
        LogInfo("[BrowserStepExecutor] 执行步骤: \(step.name), Run: \(context.runID)")
        
        // 从 step 名称或描述解析浏览器操作
        let operation = parseBrowserOperation(step.name + " " + step.description)
        
        switch operation {
        case .navigate(let url):
            return await executeNavigate(url: url, context: context)
            
        case .fill(let selector, let value):
            return await executeFill(selector: selector, value: value, context: context)
            
        case .click(let selector):
            return await executeClick(selector: selector, context: context)
            
        case .screenshot:
            return await executeScreenshot(context: context)
            
        case .wait(let seconds):
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            return .success(output: ["waited": String(seconds)])
            
        case .unknown:
            return .failure(error: StepExecutionError(
                code: "UNKNOWN_OPERATION",
                message: "无法识别的浏览器操作: \(step.name)",
                isRetryable: false
            ))
        }
    }
    
    // MARK: - 具体操作执行
    
    private func executeNavigate(url: String, context: WorkflowContext) async -> StepExecutionResult {
        let success = await browserAgent.navigate(to: url)
        
        if success {
            // 等待页面加载
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            
            // 获取页面信息
            if let pageInfo = await browserAgent.getPageInfo() {
                return .success(output: [
                    "url": pageInfo.url,
                    "title": pageInfo.title
                ])
            }
            
            return .success(output: ["url": url])
        } else {
            return .failure(error: StepExecutionError(
                code: "NAVIGATE_FAILED",
                message: "无法导航到: \(url)",
                isRetryable: true
            ))
        }
    }
    
    private func executeFill(selector: String, value: String, context: WorkflowContext) async -> StepExecutionResult {
        // 构建填充脚本
        let script = """
        (function() {
            const el = document.querySelector('\(escapeJS(selector))');
            if (!el) return { success: false, error: 'Element not found' };
            el.value = '\(escapeJS(value))';
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
            return { success: true };
        })()
        """
        
        if let result = await browserAgent.executeJavaScript(script) {
            if result.contains("success") {
                return .success(output: ["filled": selector])
            } else {
                return .failure(error: StepExecutionError(
                    code: "FILL_FAILED",
                    message: "无法填写元素: \(selector)",
                    isRetryable: true
                ))
            }
        }
        
        return .failure(error: .timeout)
    }
    
    private func executeClick(selector: String, context: WorkflowContext) async -> StepExecutionResult {
        let script = """
        (function() {
            const el = document.querySelector('\(escapeJS(selector))');
            if (!el) return { success: false, error: 'Element not found' };
            el.click();
            return { success: true };
        })()
        """
        
        if let result = await browserAgent.executeJavaScript(script) {
            if result.contains("success") {
                return .success(output: ["clicked": selector])
            }
        }
        
        // 尝试通过文本点击
        let textClickScript = """
        (function() {
            const elements = Array.from(document.querySelectorAll('button, a, [role="button"], input[type="submit"]'));
            const target = elements.find(el => el.textContent.trim() === '\(escapeJS(selector))');
            if (target) {
                target.click();
                return { success: true };
            }
            return { success: false };
        })()
        """
        
        if let result = await browserAgent.executeJavaScript(textClickScript),
           result.contains("success") {
            return .success(output: ["clicked": selector])
        }
        
        return .failure(error: StepExecutionError(
            code: "CLICK_FAILED",
            message: "无法点击元素: \(selector)",
            isRetryable: true
        ))
    }
    
    private func executeScreenshot(context: WorkflowContext) async -> StepExecutionResult {
        if let path = await browserAgent.captureScreenshotFilePath() {
            return .success(output: [
                "screenshotPath": path,
                "action": "screenshot"
            ])
        }
        
        return .failure(error: StepExecutionError(
            code: "SCREENSHOT_FAILED",
            message: "截图失败",
            isRetryable: true
        ))
    }
    
    // MARK: - 操作解析
    
    private enum BrowserOperation {
        case navigate(url: String)
        case fill(selector: String, value: String)
        case click(selector: String)
        case screenshot
        case wait(seconds: Int)
        case unknown
    }
    
    private func parseBrowserOperation(_ text: String) -> BrowserOperation {
        let lowercased = text.lowercased()
        
        // 导航
        if lowercased.contains("打开") || lowercased.contains("导航") || lowercased.contains("访问"),
           let url = extractURL(from: text) {
            return .navigate(url: url)
        }
        
        // 填写
        if lowercased.contains("填写") || lowercased.contains("输入"),
           let selector = extractSelector(from: text, keyword: ["填写", "输入"]),
           let value = extractValue(from: text) {
            return .fill(selector: selector, value: value)
        }
        
        // 点击
        if lowercased.contains("点击") || lowercased.contains("按下"),
           let selector = extractSelector(from: text, keyword: ["点击", "按下"]) {
            return .click(selector: selector)
        }
        
        // 截图
        if lowercased.contains("截图") || lowercased.contains("屏幕") {
            return .screenshot
        }
        
        // 等待
        if let seconds = extractWaitTime(from: text) {
            return .wait(seconds: seconds)
        }
        
        // 默认：尝试解析 URL 作为导航
        if let url = extractURL(from: text) {
            return .navigate(url: url)
        }
        
        return .unknown
    }
    
    private func extractURL(from text: String) -> String? {
        // 提取 http:// 或 https:// 开头的 URL
        if let range = text.range(of: #"https?://[^\s]+"#, options: .regularExpression) {
            return String(text[range])
        }
        return nil
    }
    
    private func extractSelector(from text: String, keyword: [String]) -> String? {
        // 简化实现：提取关键词后面的内容
        for kw in keyword {
            if let range = text.range(of: kw + "(.+)", options: .regularExpression) {
                let after = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                return after.components(separatedBy: CharacterSet.whitespaces).first
            }
        }
        return nil
    }
    
    private func extractValue(from text: String) -> String? {
        // 提取引号中的内容或冒号后的内容
        if let range = text.range(of: #"["']([^"']+)["']"#, options: .regularExpression) {
            return String(text[range])
        }
        if let range = text.range(of: #":\s*(.+?)(?:\s|$)"#, options: .regularExpression) {
            return String(text[range]).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
    
    private func extractWaitTime(from text: String) -> Int? {
        // 提取等待时间，如"等待3秒"
        if let match = text.range(of: #"等待\s*(\d+)\s*秒"#, options: .regularExpression) {
            let matched = String(text[match])
            if let num = matched.components(separatedBy: CharacterSet.decimalDigits.inverted).joined().first,
               let intVal = Int(String(num)) {
                return intVal
            }
        }
        return nil
    }
    
    private func escapeJS(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
