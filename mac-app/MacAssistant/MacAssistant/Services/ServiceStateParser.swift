//
//  ServiceStateParser.swift
//  MacAssistant
//
//  服务操作结果解析器 - 从 AI 响应中提取服务状态信息
//

import Foundation

/// 服务状态解析器
/// 用于从 AI 返回的文本中提取服务操作结果
struct ServiceStateParser {
    
    // MARK: - 解析模式定义
    
    struct ParsePattern {
        let name: String
        let regex: NSRegularExpression
        let extractor: (NSTextCheckingResult, String) -> ServiceParseResult?
    }
    
    // MARK: - 预定义模式
    
    private var patterns: [ParsePattern] { [
        // 模式1: ✅ 服务名 MCP 已启动 / 成功启动
        ParsePattern(
            name: "successStart",
            regex: try! NSRegularExpression(
                pattern: #"(?:✅|成功|已启动|启动完成).*?(\d+).*?端口.*?([\d,]+)"#,
                options: [.caseInsensitive]
            ),
            extractor: { match, text in
                let nsRange = NSRange(location: 0, length: text.utf16.count)
                guard let result = match.regularExpression?.firstMatch(in: text, options: [], range: nsRange) else {
                    return nil
                }
                
                var pid: Int?
                var port: Int?
                
                // 提取 PID
                if result.numberOfRanges > 1 {
                    let pidRange = result.range(at: 1)
                    if let range = Range(pidRange, in: text) {
                        pid = Int(text[range])
                    }
                }
                
                // 提取端口
                if result.numberOfRanges > 2 {
                    let portRange = result.range(at: 2)
                    if let range = Range(portRange, in: text) {
                        let portStr = text[range].replacingOccurrences(of: ",", with: "")
                        port = Int(portStr)
                    }
                }
                
                return ServiceParseResult(
                    isSuccess: true,
                    status: .running,
                    pid: pid,
                    port: port,
                    message: "服务启动成功"
                )
            }
        ),
        
        // 模式2: PID: 12345 / pid: 12345
        ParsePattern(
            name: "pidExtract",
            regex: try! NSRegularExpression(
                pattern: #"(?:PID|pid)[:\s]+(\d+)"#,
                options: [.caseInsensitive]
            ),
            extractor: { match, text in
                if match.numberOfRanges > 1 {
                    let range = match.range(at: 1)
                    if let r = Range(range, in: text) {
                        let pid = Int(text[r])
                        return ServiceParseResult(
                            isSuccess: true,
                            status: nil, // 需要结合其他信息判断
                            pid: pid,
                            port: nil,
                            message: "提取到 PID: \(pid ?? 0)"
                        )
                    }
                }
                return nil
            }
        ),
        
        // 模式3: port 18060 / 端口: 18060 / 端口 18060
        ParsePattern(
            name: "portExtract",
            regex: try! NSRegularExpression(
                pattern: #"(?:port|端口)[:\s]+([\d,]+)"#,
                options: [.caseInsensitive]
            ),
            extractor: { match, text in
                if match.numberOfRanges > 1 {
                    let range = match.range(at: 1)
                    if let r = Range(range, in: text) {
                        let portStr = text[r].replacingOccurrences(of: ",", with: "")
                        let port = Int(portStr)
                        return ServiceParseResult(
                            isSuccess: true,
                            status: nil,
                            pid: nil,
                            port: port,
                            message: "提取到端口: \(port ?? 0)"
                        )
                    }
                }
                return nil
            }
        ),
        
        // 模式4: 运行中 / 运行状态
        ParsePattern(
            name: "runningStatus",
            regex: try! NSRegularExpression(
                pattern: #"(?:运行中|running|正常运行|服务正常)"#,
                options: [.caseInsensitive]
            ),
            extractor: { _, _ in
                return ServiceParseResult(
                    isSuccess: true,
                    status: .running,
                    pid: nil,
                    port: nil,
                    message: "服务运行中"
                )
            }
        ),
        
        // 模式5: 已停止 / 停止状态
        ParsePattern(
            name: "stoppedStatus",
            regex: try! NSRegularExpression(
                pattern: #"(?:已停止|stopped|停止运行|未运行)"#,
                options: [.caseInsensitive]
            ),
            extractor: { _, _ in
                return ServiceParseResult(
                    isSuccess: true,
                    status: .stopped,
                    pid: nil,
                    port: nil,
                    message: "服务已停止"
                )
            }
        ),
        
        // 模式6: ❌ 失败 / 错误
        ParsePattern(
            name: "errorStatus",
            regex: try! NSRegularExpression(
                pattern: #"(?:❌|失败|错误|error|failed|启动失败|停止失败)"#,
                options: [.caseInsensitive]
            ),
            extractor: { match, text in
                // 尝试提取错误信息
                let errorPattern = try? NSRegularExpression(
                    pattern: #"(?:错误|error|失败)[:：]\s*(.+?)(?:\n|$)"#,
                    options: [.caseInsensitive]
                )
                let nsRange = NSRange(location: 0, length: text.utf16.count)
                var errorMsg: String?
                if let errorMatch = errorPattern?.firstMatch(in: text, options: [], range: nsRange),
                   errorMatch.numberOfRanges > 1 {
                    let range = errorMatch.range(at: 1)
                    if let r = Range(range, in: text) {
                        errorMsg = String(text[r]).trimmingCharacters(in: .whitespaces)
                    }
                }
                
                return ServiceParseResult(
                    isSuccess: false,
                    status: .error,
                    pid: nil,
                    port: nil,
                    message: errorMsg ?? "操作失败"
                )
            }
        ),
        
        // 模式7: MCP 服务启动完成表格格式
        ParsePattern(
            name: "mcpTableFormat",
            regex: try! NSRegularExpression(
                pattern: #"(?:小红书|GitHub|富途|WhatsApp).*?MCP.*?(?:运行中|✅).*?(?:port|PID)[:\s]+(\d+)"#,
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            ),
            extractor: { match, text in
                var port: Int?
                var pid: Int?
                
                if match.numberOfRanges > 1 {
                    let range = match.range(at: 1)
                    if let r = Range(range, in: text) {
                        let value = Int(text[r])
                        // 小于 10000 的可能是 PID，大于的是端口
                        if let v = value {
                            if v > 3000 && v < 10000 {
                                port = v
                            } else {
                                pid = v
                            }
                        }
                    }
                }
                
                return ServiceParseResult(
                    isSuccess: true,
                    status: .running,
                    pid: pid,
                    port: port,
                    message: "MCP 服务运行中"
                )
            }
        )
    ] }
    
    // MARK: - 服务名称映射
    
    private let serviceNameMappings: [String: [String]] = [
        "xiaohongshu-mcp": ["小红书", "xiaohongshu", "xhs"],
        "github-mcp-http": ["GitHub MCP HTTP", "github http", "github-mcp-http"],
        "github-mcp-stdio": ["GitHub MCP stdio", "github stdio", "github-mcp-stdio"],
        "futu-mcp": ["富途", "futu"],
        "whatsapp-mcp": ["WhatsApp", "whatsapp", "wa"],
        "futu-opend": ["富途 OpenD", "futu opend", "FutuOpenD"],
        "mongodb": ["MongoDB", "mongo", "mongodb"]
    ]
    
    // MARK: - 公共方法
    
    /// 解析 AI 返回的结果
    func parse(result: String, for serviceName: String) -> ServiceParseResult {
        var combinedResult = ServiceParseResult(
            isSuccess: false,
            status: nil,
            pid: nil,
            port: nil,
            message: nil
        )
        
        // 尝试所有模式匹配
        for pattern in patterns {
            let matches = pattern.regex.matches(
                in: result,
                options: [],
                range: NSRange(location: 0, length: result.utf16.count)
            )
            
            for match in matches {
                if let parsed = pattern.extractor(match, result) {
                    // 合并结果
                    combinedResult = merge(combinedResult, with: parsed)
                }
            }
        }
        
        // 如果没有明确的成功/失败标记，根据内容推断
        if combinedResult.status == nil {
            combinedResult = inferStatus(from: result, current: combinedResult)
        }
        
        return combinedResult
    }
    
    /// 从文本中识别服务名称
    func identifyService(in text: String) -> String? {
        let lowercased = text.lowercased()
        
        for (serviceID, aliases) in serviceNameMappings {
            for alias in aliases {
                if lowercased.contains(alias.lowercased()) {
                    return serviceID
                }
            }
        }
        
        return nil
    }
    
    /// 检查文本是否包含服务操作相关内容
    func containsServiceOperation(_ text: String) -> Bool {
        let indicators = [
            "mcp", "MCP",
            "启动", "停止", "重启",
            "start", "stop", "restart",
            "服务", "service",
            "端口", "port",
            "pid", "PID"
        ]
        
        let lowercased = text.lowercased()
        return indicators.contains { lowercased.contains($0.lowercased()) }
    }
    
    // MARK: - 私有方法
    
    /// 合并解析结果
    private func merge(_ base: ServiceParseResult, with other: ServiceParseResult) -> ServiceParseResult {
        return ServiceParseResult(
            isSuccess: other.isSuccess || base.isSuccess,
            status: other.status ?? base.status,
            pid: other.pid ?? base.pid,
            port: other.port ?? base.port,
            message: other.message ?? base.message
        )
    }
    
    /// 推断状态
    private func inferStatus(from text: String, current: ServiceParseResult) -> ServiceParseResult {
        var status = current.status
        var isSuccess = current.isSuccess
        
        let lowercased = text.lowercased()
        
        // 成功指标
        if lowercased.contains("✅") ||
           lowercased.contains("成功") ||
           lowercased.contains("完成") ||
           lowercased.contains("done") ||
           lowercased.contains("completed") {
            isSuccess = true
            if status == nil {
                status = .running
            }
        }
        
        // 失败指标
        if lowercased.contains("❌") ||
           lowercased.contains("失败") ||
           lowercased.contains("错误") ||
           lowercased.contains("error") ||
           lowercased.contains("failed") {
            isSuccess = false
            status = .error
        }
        
        return ServiceParseResult(
            isSuccess: isSuccess,
            status: status,
            pid: current.pid,
            port: current.port,
            message: current.message
        )
    }
}

// MARK: - 便捷扩展

extension ServiceStateParser {
    /// 快速检查是否是服务启动相关文本
    static func isServiceStartRelated(_ text: String) -> Bool {
        let keywords = [
            "启动.*MCP", "MCP.*启动",
            "start.*mcp", "mcp.*start",
            "服务.*启动完成", "服务启动"
        ]
        
        for keyword in keywords {
            if let regex = try? NSRegularExpression(pattern: keyword, options: [.caseInsensitive]),
               regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count)) != nil {
                return true
            }
        }
        
        return false
    }
    
    /// 提取服务列表
    static func extractServiceList(from text: String) -> [(name: String, status: String, detail: String)] {
        var services: [(name: String, status: String, detail: String)] = []
        
        // 匹配表格格式：服务名 | 状态 | 端口/PID
        let pattern = try? NSRegularExpression(
            pattern: #"(小红书 MCP|GitHub MCP HTTP|GitHub MCP stdio|富途 MCP|WhatsApp MCP|富途 OpenD).*?(运行中|停止).*?(port \d+|PID: \d+|需.*)"#,
            options: [.caseInsensitive]
        )
        
        let matches = pattern?.matches(
            in: text,
            options: [],
            range: NSRange(location: 0, length: text.utf16.count)
        ) ?? []
        
        for match in matches {
            var name = ""
            var status = ""
            var detail = ""
            
            if match.numberOfRanges > 1 {
                let range = match.range(at: 1)
                if let r = Range(range, in: text) {
                    name = String(text[r])
                }
            }
            
            if match.numberOfRanges > 2 {
                let range = match.range(at: 2)
                if let r = Range(range, in: text) {
                    status = String(text[r])
                }
            }
            
            if match.numberOfRanges > 3 {
                let range = match.range(at: 3)
                if let r = Range(range, in: text) {
                    detail = String(text[r])
                }
            }
            
            services.append((name, status, detail))
        }
        
        return services
    }
}
