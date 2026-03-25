import Foundation
import os.log

/// 表示Agent响应的类型
enum AgentResponse {
    /// 直接对话响应
    case direct(text: String)
    
    /// 工具调用响应
    case toolCall(tool: String, parameters: [String: Any], response: String)
    
    /// 创建任务响应
    case createTask(name: String, description: String, steps: [String])
    
    /// Agent路由响应
    case routeAgent(targetAgent: String, reason: String)
}

/// 解析Agent的原始输出为结构化响应
class AgentResponseParser {
    
    // MARK: - Shared Instance
    
    static let shared = AgentResponseParser()
    
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "com.macassistant.app", category: "AgentResponseParser")
    
    // MARK: - Public Methods
    
    /// 解析原始响应字符串
    /// - Parameter rawResponse: Agent返回的原始字符串
    /// - Returns: 解析后的 AgentResponse
    func parse(_ rawResponse: String) -> AgentResponse {
        logger.debug("开始解析Agent响应")
        
        // 1. 尝试提取 JSON 代码块
        if let jsonString = extractJSONFromCodeBlock(rawResponse) {
            logger.debug("从代码块中提取到JSON")
            return parseJSON(jsonString, fallbackText: rawResponse)
        }
        
        // 2. 尝试提取行内 JSON
        if let jsonString = extractInlineJSON(rawResponse) {
            logger.debug("从行内提取到JSON")
            return parseJSON(jsonString, fallbackText: rawResponse)
        }
        
        // 3. 尝试将整个响应作为 JSON 解析
        if isValidJSON(rawResponse) {
            logger.debug("将整个响应作为JSON解析")
            return parseJSON(rawResponse, fallbackText: rawResponse)
        }
        
        // 4. 无法解析 JSON，返回直接对话
        logger.info("无法解析为JSON，返回直接对话响应")
        return .direct(text: rawResponse)
    }
    
    // MARK: - Private Methods
    
    /// 从代码块中提取 JSON
    private func extractJSONFromCodeBlock(_ text: String) -> String? {
        // 匹配 ```json ... ``` 格式的代码块
        let pattern = "```json\\s*\\n?([\\s\\S]*?)\\n?```"
        
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            logger.error("正则表达式编译失败")
            return nil
        }
        
        let range = NSRange(text.startIndex..., in: text)
        if let match = regex.firstMatch(in: text, options: [], range: range) {
            let jsonRange = match.range(at: 1)
            if let swiftRange = Range(jsonRange, in: text) {
                let extracted = String(text[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                logger.debug("从代码块提取JSON成功，长度: \(extracted.count)")
                return extracted
            }
        }
        
        return nil
    }
    
    /// 从文本中提取行内 JSON
    private func extractInlineJSON(_ text: String) -> String? {
        // 查找以 { 开头，} 结尾的最外层 JSON 对象
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard trimmed.hasPrefix("{") else {
            return nil
        }
        
        // 使用括号匹配找到完整的 JSON
        var braceCount = 0
        var startIndex: String.Index?
        
        for (index, char) in trimmed.enumerated() {
            let currentIndex = trimmed.index(trimmed.startIndex, offsetBy: index)
            
            if char == "{" {
                if braceCount == 0 {
                    startIndex = currentIndex
                }
                braceCount += 1
            } else if char == "}" {
                braceCount -= 1
                if braceCount == 0, let start = startIndex {
                    let jsonString = String(trimmed[start...currentIndex])
                    logger.debug("提取到行内JSON，长度: \(jsonString.count)")
                    return jsonString
                }
            }
        }
        
        return nil
    }
    
    /// 检查字符串是否为有效的 JSON
    private func isValidJSON(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8) else {
            return false
        }
        
        do {
            _ = try JSONSerialization.jsonObject(with: data, options: [])
            return true
        } catch {
            return false
        }
    }
    
    /// 解析 JSON 字符串为 AgentResponse
    private func parseJSON(_ jsonString: String, fallbackText: String) -> AgentResponse {
        guard let data = jsonString.data(using: .utf8) else {
            logger.error("无法将JSON字符串转换为Data")
            return .direct(text: fallbackText)
        }
        
        do {
            guard let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
                logger.error("JSON格式不正确，不是字典类型")
                return .direct(text: fallbackText)
            }
            
            // 获取响应文本（给用户看的）
            let responseText = json["response"] as? String ?? ""
            
            // 检查是否有 action 字段
            guard let action = json["action"] as? [String: Any] else {
                // 没有 action，直接返回对话响应
                let text = responseText.isEmpty ? fallbackText : responseText
                logger.debug("没有action字段，返回直接对话")
                return .direct(text: text)
            }
            
            // 解析 action 类型
            let actionType = action["type"] as? String ?? ""
            
            switch actionType {
            case "tool_call":
                return parseToolCall(action: action, responseText: responseText, fallbackText: fallbackText)
                
            case "create_task":
                return parseCreateTask(action: action, responseText: responseText, fallbackText: fallbackText)
                
            case "route_agent":
                return parseRouteAgent(action: action, responseText: responseText, fallbackText: fallbackText)
                
            default:
                logger.warning("未知的action类型: \(actionType)")
                return .direct(text: responseText.isEmpty ? fallbackText : responseText)
            }
            
        } catch {
            logger.error("JSON解析失败: \(error.localizedDescription)")
            return .direct(text: fallbackText)
        }
    }
    
    /// 解析工具调用
    private func parseToolCall(action: [String: Any], responseText: String, fallbackText: String) -> AgentResponse {
        guard let tool = action["tool"] as? String else {
            logger.error("tool_call缺少tool字段")
            return .direct(text: responseText.isEmpty ? fallbackText : responseText)
        }
        
        let parameters = action["parameters"] as? [String: Any] ?? [:]
        
        logger.info("解析到工具调用: \(tool)")
        return .toolCall(tool: tool, parameters: parameters, response: responseText)
    }
    
    /// 解析创建任务
    private func parseCreateTask(action: [String: Any], responseText: String, fallbackText: String) -> AgentResponse {
        guard let name = action["name"] as? String else {
            logger.error("create_task缺少name字段")
            return .direct(text: responseText.isEmpty ? fallbackText : responseText)
        }
        
        let description = action["description"] as? String ?? ""
        let steps = action["steps"] as? [String] ?? []
        
        logger.info("解析到创建任务: \(name)")
        return .createTask(name: name, description: description, steps: steps)
    }
    
    /// 解析Agent路由
    private func parseRouteAgent(action: [String: Any], responseText: String, fallbackText: String) -> AgentResponse {
        guard let targetAgent = action["target_agent"] as? String else {
            logger.error("route_agent缺少target_agent字段")
            return .direct(text: responseText.isEmpty ? fallbackText : responseText)
        }
        
        let reason = action["reason"] as? String ?? ""
        
        logger.info("解析到Agent路由: \(targetAgent)")
        return .routeAgent(targetAgent: targetAgent, reason: reason)
    }
}

// MARK: - AgentResponse 扩展

extension AgentResponse {
    /// 获取给用户显示的文本
    var displayText: String {
        switch self {
        case .direct(let text):
            return text
        case .toolCall(_, _, let response):
            return response
        case .createTask(let name, let description, _):
            return "创建任务: \(name) - \(description)"
        case .routeAgent(let targetAgent, let reason):
            return "转接到 \(targetAgent): \(reason)"
        }
    }
    
    /// 获取动作类型描述
    var actionDescription: String {
        switch self {
        case .direct:
            return "direct"
        case .toolCall(let tool, _, _):
            return "tool_call(\(tool))"
        case .createTask:
            return "create_task"
        case .routeAgent(let targetAgent, _):
            return "route_agent(\(targetAgent))"
        }
    }
}
