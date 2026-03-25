//
//  ToolExecutor.swift
//  MacAssistant
//
//  工具执行器 - 执行Agent调用的工具
//

import Foundation
import AppKit

// MARK: - Tool Execution Result

/// 工具执行结果
struct ToolExecutionResult {
    let success: Bool
    let output: String?
    let error: String?
    let data: [String: Any]?
    
    init(
        success: Bool,
        output: String? = nil,
        error: String? = nil,
        data: [String: Any]? = nil
    ) {
        self.success = success
        self.output = output
        self.error = error
        self.data = data
    }
    
    /// 成功结果
    static func success(output: String? = nil, data: [String: Any]? = nil) -> ToolExecutionResult {
        ToolExecutionResult(success: true, output: output, error: nil, data: data)
    }
    
    /// 失败结果
    static func failure(error: String, output: String? = nil) -> ToolExecutionResult {
        ToolExecutionResult(success: false, output: output, error: error, data: nil)
    }
}

// MARK: - Tool Error

/// 工具执行错误
enum ToolExecutionError: Error, LocalizedError {
    case invalidTool(String)
    case missingParameter(String)
    case invalidParameter(String, Any?)
    case executionFailed(String)
    case serviceNotFound(String)
    case skillNotFound(String)
    case appNotFound(String)
    case workflowCreationFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidTool(let tool):
            return "无效的工具: \(tool)"
        case .missingParameter(let param):
            return "缺少必需参数: \(param)"
        case .invalidParameter(let param, let value):
            return "无效参数值: \(param) = \(String(describing: value))"
        case .executionFailed(let reason):
            return "执行失败: \(reason)"
        case .serviceNotFound(let serviceId):
            return "服务未找到: \(serviceId)"
        case .skillNotFound(let skillId):
            return "Skill未找到: \(skillId)"
        case .appNotFound(let bundleId):
            return "应用未找到: \(bundleId)"
        case .workflowCreationFailed(let reason):
            return "创建工作流失败: \(reason)"
        }
    }
}

// MARK: - Tool Executor

/// 工具执行器 - 单例
@MainActor
final class ToolExecutor {
    static let shared = ToolExecutor()
    
    // MARK: - 支持的工具类型
    
    enum ToolType: String, CaseIterable {
        case launchApp = "launch_app"
        case manageService = "manage_service"
        case executeSkill = "execute_skill"
        case searchMemory = "search_memory"
        case createWorkflow = "create_workflow"
        
        var displayName: String {
            switch self {
            case .launchApp: return "启动应用"
            case .manageService: return "管理服务"
            case .executeSkill: return "执行Skill"
            case .searchMemory: return "搜索记忆"
            case .createWorkflow: return "创建工作流"
            }
        }
        
        var description: String {
            switch self {
            case .launchApp:
                return "通过bundle ID启动macOS应用"
            case .manageService:
                return "管理系统服务(start/stop/restart/status)"
            case .executeSkill:
                return "执行指定的Skill"
            case .searchMemory:
                return "搜索对话历史记忆"
            case .createWorkflow:
                return "创建新的工作流定义"
            }
        }
    }
    
    // MARK: - 初始化
    
    private init() {
        LogInfo("[ToolExecutor] 工具执行器已初始化")
    }
    
    // MARK: - 主执行方法
    
    /// 执行工具
    /// - Parameters:
    ///   - tool: 工具名称（如 "launch_app"）
    ///   - parameters: 参数字典
    /// - Returns: 执行结果
    func execute(
        tool: String,
        parameters: [String: Any]
    ) async -> ToolExecutionResult {
        LogInfo("[ToolExecutor] 执行工具: \(tool), 参数: \(parameters.keys.joined(separator: ", "))")
        
        guard let toolType = ToolType(rawValue: tool) else {
            LogError("[ToolExecutor] 无效的工具类型: \(tool)")
            return .failure(error: ToolExecutionError.invalidTool(tool).localizedDescription)
        }
        
        do {
            let result: ToolExecutionResult
            
            switch toolType {
            case .launchApp:
                result = try await executeLaunchApp(parameters: parameters)
            case .manageService:
                result = try await executeManageService(parameters: parameters)
            case .executeSkill:
                result = try await executeSkill(parameters: parameters)
            case .searchMemory:
                result = try await executeSearchMemory(parameters: parameters)
            case .createWorkflow:
                result = try await executeCreateWorkflow(parameters: parameters)
            }
            
            if result.success {
                LogInfo("[ToolExecutor] 工具执行成功: \(tool)")
            } else {
                LogWarning("[ToolExecutor] 工具执行失败: \(tool) - \(result.error ?? "未知错误")")
            }
            
            return result
            
        } catch let error as ToolExecutionError {
            LogError("[ToolExecutor] 工具执行错误: \(tool) - \(error.localizedDescription)")
            return .failure(error: error.localizedDescription)
        } catch {
            LogError("[ToolExecutor] 未预期的错误: \(tool) - \(error.localizedDescription)")
            return .failure(error: ToolExecutionError.executionFailed(error.localizedDescription).localizedDescription)
        }
    }
    
    // MARK: - launch_app: 启动应用
    
    /// 启动应用
    /// - 参数：
    ///   - bundle_id (String): 应用的Bundle ID
    private func executeLaunchApp(parameters: [String: Any]) async throws -> ToolExecutionResult {
        guard let bundleId = parameters["bundle_id"] as? String else {
            throw ToolExecutionError.missingParameter("bundle_id")
        }
        
        LogInfo("[ToolExecutor] 启动应用: \(bundleId)")
        
        // 1. 查找应用
        let launcher = DesktopAppLauncher.shared
        guard let appInfo = launcher.findApp(byBundleID: bundleId) else {
            // 尝试通过URL查找
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
                throw ToolExecutionError.appNotFound(bundleId)
            }
            
            // 尝试直接启动
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            
            do {
                let runningApp = try await NSWorkspace.shared.openApplication(
                    at: appURL,
                    configuration: configuration
                )
                let pid = runningApp.processIdentifier
                
                return .success(
                    output: "应用 \(bundleId) 已启动 (PID: \(pid))",
                    data: [
                        "bundle_id": bundleId,
                        "pid": Int(pid),
                        "name": runningApp.localizedName ?? bundleId
                    ]
                )
            } catch {
                throw ToolExecutionError.executionFailed("启动失败: \(error.localizedDescription)")
            }
        }
        
        // 2. 启动应用
        let result = await launcher.launchApp(appInfo)
        
        switch result {
        case .success(let pid):
            return .success(
                output: "应用 \(appInfo.name) 已启动 (PID: \(pid))",
                data: [
                    "bundle_id": bundleId,
                    "name": appInfo.name,
                    "pid": pid
                ]
            )
        case .alreadyRunning(let pid):
            return .success(
                output: "应用 \(appInfo.name) 已在运行 (PID: \(pid))",
                data: [
                    "bundle_id": bundleId,
                    "name": appInfo.name,
                    "pid": pid,
                    "was_already_running": true
                ]
            )
        case .notFound:
            throw ToolExecutionError.appNotFound(bundleId)
        case .permissionDenied:
            throw ToolExecutionError.executionFailed("权限被拒绝，无法启动应用")
        case .failed(let error):
            throw ToolExecutionError.executionFailed(error)
        }
    }
    
    // MARK: - manage_service: 管理服务
    
    /// 管理服务
    /// - 参数：
    ///   - service_id (String): 服务ID
    ///   - action (String): 操作类型 (start|stop|restart|status)
    private func executeManageService(parameters: [String: Any]) async throws -> ToolExecutionResult {
        guard let serviceId = parameters["service_id"] as? String else {
            throw ToolExecutionError.missingParameter("service_id")
        }
        
        guard let actionString = parameters["action"] as? String else {
            throw ToolExecutionError.missingParameter("action")
        }
        
        let validActions = ["start", "stop", "restart", "status"]
        guard validActions.contains(actionString.lowercased()) else {
            throw ToolExecutionError.invalidParameter("action", actionString)
        }
        
        LogInfo("[ToolExecutor] 管理服务: \(serviceId), 操作: \(actionString)")
        
        let serviceManager = ServiceManager.shared
        
        // 检查服务是否已注册
        if serviceManager.services.first(where: { $0.id == serviceId }) == nil {
            // 尝试注册常用服务
            serviceManager.registerCommonServices()
        }
        
        // 执行操作
        let action = actionString.lowercased()
        let stateStore = ServiceStateStore.shared
        
        switch action {
        case "start":
            await serviceManager.startService(serviceId)
            let state = stateStore.state(for: serviceId)
            return .success(
                output: "服务 \(serviceId) 启动完成",
                data: [
                    "service_id": serviceId,
                    "action": "start",
                    "state": state?.state.rawValue ?? "unknown",
                    "message": state?.lastOperation ?? ""
                ]
            )
            
        case "stop":
            await serviceManager.stopService(serviceId)
            let state = stateStore.state(for: serviceId)
            return .success(
                output: "服务 \(serviceId) 停止完成",
                data: [
                    "service_id": serviceId,
                    "action": "stop",
                    "state": state?.state.rawValue ?? "unknown",
                    "message": state?.lastOperation ?? ""
                ]
            )
            
        case "restart":
            await serviceManager.restartService(serviceId)
            let state = stateStore.state(for: serviceId)
            return .success(
                output: "服务 \(serviceId) 重启完成",
                data: [
                    "service_id": serviceId,
                    "action": "restart",
                    "state": state?.state.rawValue ?? "unknown",
                    "message": state?.lastOperation ?? ""
                ]
            )
            
        case "status":
            await serviceManager.checkService(serviceId)
            let state = stateStore.state(for: serviceId)
            let output = state.map { "服务: \($0.name)\n状态: \($0.state.rawValue)\n最后操作: \($0.lastOperation ?? "无")" } ?? "无法获取服务状态"
            return .success(
                output: output,
                data: [
                    "service_id": serviceId,
                    "action": "status",
                    "state": state?.state.rawValue ?? "unknown",
                    "name": state?.name ?? serviceId,
                    "adapter": state?.adapter as Any,
                    "pid": state?.pid as Any,
                    "port": state?.port as Any,
                    "last_error": state?.lastError as Any
                ]
            )
            
        default:
            throw ToolExecutionError.invalidParameter("action", actionString)
        }
    }
    
    // MARK: - execute_skill: 执行Skill
    
    /// 执行Skill
    /// - 参数：
    ///   - skill_id (String): Skill ID
    ///   - input (Object): 输入参数（字典）
    ///   - input_text (String): 文本输入（兼容旧格式）
    private func executeSkill(parameters: [String: Any]) async throws -> ToolExecutionResult {
        guard let skillId = parameters["skill_id"] as? String else {
            throw ToolExecutionError.missingParameter("skill_id")
        }
        
        // 解析输入参数
        var skillInput: [String: Any] = [:]
        
        if let inputDict = parameters["input"] as? [String: Any] {
            // 新的字典格式
            skillInput = inputDict
        } else if let inputString = parameters["input"] as? String {
            // 字符串格式 - 转为 text 字段
            skillInput["text"] = inputString
        }
        
        // 兼容旧格式 input_text
        if let inputText = parameters["input_text"] as? String {
            skillInput["text"] = inputText
        }
        
        LogInfo("[ToolExecutor] 执行Skill: \(skillId)")
        
        // 使用 SkillExecutor 执行
        let skillExecutor = SkillExecutor.shared
        let context = SkillExecutionContext(
            sessionId: "main_session",
            userIntent: skillInput["text"] as? String ?? ""
        )
        
        let result = await skillExecutor.execute(
            skillId: skillId,
            input: skillInput,
            context: context
        )
        
        // 转换结果为 ToolExecutionResult
        if result.success {
            let outputText = result.output?["response"] ?? "Skill 执行成功"
            var data: [String: Any] = ["skill_id": skillId]
            // 将所有 output 字段加入 data
            if let output = result.output {
                for (key, value) in output {
                    data[key] = value
                }
            }
            return .success(output: outputText, data: data)
        } else {
            let outputText = result.output?["response"]
            return .failure(
                error: result.error ?? "Skill 执行失败",
                output: outputText
            )
        }
    }
    
    // MARK: - search_memory: 搜索记忆
    
    /// 搜索记忆
    /// - 参数：
    ///   - query (String): 搜索查询
    ///   - session_id (String?): 可选的会话ID
    private func executeSearchMemory(parameters: [String: Any]) async throws -> ToolExecutionResult {
        guard let query = parameters["query"] as? String else {
            throw ToolExecutionError.missingParameter("query")
        }
        
        let sessionId = parameters["session_id"] as? String ?? "main_session"
        
        LogInfo("[ToolExecutor] 搜索记忆: \(query.prefix(50))...")
        
        let memoryManager = ConversationMemoryManager.shared
        
        // 1. 获取蒸馏后的上下文
        let context = memoryManager.retrieveDistilledContext(
            for: query,
            currentSessionID: sessionId
        )
        
        // 2. 构建搜索结果
        var results: [[String: Any]] = []
        
        // 添加各类条目
        let allEntries = context.codeEntries + context.fileEntries + context.taskEntries +
                        context.skillEntries + context.serviceEntries + context.queryEntries
        
        for entry in allEntries.suffix(10) {
            results.append([
                "id": entry.id.uuidString,
                "timestamp": entry.timestamp,
                "role": entry.role.rawValue,
                "type": entry.type.rawValue,
                "intent": entry.intent,
                "entities": entry.keyEntities,
                "outcome": entry.outcome as Any
            ])
        }
        
        // 3. 格式化输出
        var outputLines: [String] = []
        
        if !context.topicEvolution.isEmpty {
            outputLines.append("话题演变: \(context.topicEvolution.joined(separator: " => "))")
        }
        
        if !context.activeTasks.isEmpty {
            outputLines.append("\n进行中的任务:")
            for task in context.activeTasks {
                outputLines.append("  - \(task)")
            }
        }
        
        if !results.isEmpty {
            outputLines.append("\n相关记忆:")
            for result in results.suffix(5) {
                if let intent = result["intent"] as? String {
                    outputLines.append("  - \(intent)")
                }
            }
        }
        
        let output = outputLines.isEmpty ? "未找到相关记忆" : outputLines.joined(separator: "\n")
        
        return .success(
            output: output,
            data: [
                "query": query,
                "session_id": sessionId,
                "total_entries": results.count,
                "entries": results,
                "key_entities": context.keyEntities,
                "topic_evolution": context.topicEvolution,
                "active_tasks": context.activeTasks
            ]
        )
    }
    
    // MARK: - create_workflow: 创建工作流
    
    /// 创建工作流
    /// - 参数：
    ///   - name (String): 工作流名称
    ///   - description (String): 工作流描述
    ///   - steps (Array?): 可选的初始步骤
    private func executeCreateWorkflow(parameters: [String: Any]) async throws -> ToolExecutionResult {
        guard let name = parameters["name"] as? String else {
            throw ToolExecutionError.missingParameter("name")
        }
        
        guard let description = parameters["description"] as? String else {
            throw ToolExecutionError.missingParameter("description")
        }
        
        LogInfo("[ToolExecutor] 创建工作流: \(name)")
        
        let store = WorkflowDefinitionStore.shared
        
        // 检查是否已存在同名工作流
        if store.definition(name: name) != nil {
            throw ToolExecutionError.workflowCreationFailed("已存在名为 '\(name)' 的工作流")
        }
        
        // 解析可选的步骤
        var steps: [WorkflowStepDef] = []
        if let stepsData = parameters["steps"] as? [[String: Any]] {
            for stepData in stepsData {
                if let stepName = stepData["name"] as? String,
                   let kindString = stepData["kind"] as? String,
                   let kind = WorkflowStepKind(rawValue: kindString) {
                    
                    let step = WorkflowStepDef(
                        name: stepName,
                        description: stepData["description"] as? String ?? "",
                        kind: kind,
                        requiresApproval: stepData["requires_approval"] as? Bool ?? false
                    )
                    steps.append(step)
                }
            }
        }
        
        // 创建工作流定义
        let definition = WorkflowDefinition(
            name: name,
            description: description,
            steps: steps,
            tags: ["created-by-agent"]
        )
        
        // 保存工作流
        do {
            try store.save(definition)
            
            return .success(
                output: "工作流 '\(name)' 创建成功",
                data: [
                    "workflow_id": definition.id,
                    "name": definition.name,
                    "description": definition.description,
                    "created_at": definition.createdAt,
                    "steps_count": steps.count,
                    "steps": steps.map { [
                        "id": $0.id,
                        "name": $0.name,
                        "kind": $0.kind.rawValue
                    ]}
                ]
            )
        } catch {
            throw ToolExecutionError.workflowCreationFailed(error.localizedDescription)
        }
    }
    
    // MARK: - 工具信息
    
    /// 获取所有可用工具的信息
    func getAvailableTools() -> [[String: Any]] {
        ToolType.allCases.map { tool in
            var parameters: [[String: String]] = []
            
            switch tool {
            case .launchApp:
                parameters = [
                    ["name": "bundle_id", "type": "string", "required": "true", "description": "应用的Bundle ID"]
                ]
            case .manageService:
                parameters = [
                    ["name": "service_id", "type": "string", "required": "true", "description": "服务ID"],
                    ["name": "action", "type": "string", "required": "true", "description": "操作: start|stop|restart|status"]
                ]
            case .executeSkill:
                parameters = [
                    ["name": "skill_id", "type": "string", "required": "true", "description": "Skill ID"],
                    ["name": "input", "type": "string", "required": "false", "description": "输入参数"]
                ]
            case .searchMemory:
                parameters = [
                    ["name": "query", "type": "string", "required": "true", "description": "搜索查询"],
                    ["name": "session_id", "type": "string", "required": "false", "description": "会话ID"]
                ]
            case .createWorkflow:
                parameters = [
                    ["name": "name", "type": "string", "required": "true", "description": "工作流名称"],
                    ["name": "description", "type": "string", "required": "true", "description": "工作流描述"],
                    ["name": "steps", "type": "array", "required": "false", "description": "初始步骤"]
                ]
            }
            
            return [
                "name": tool.rawValue,
                "display_name": tool.displayName,
                "description": tool.description,
                "parameters": parameters
            ] as [String: Any]
        }
    }
    
    /// 获取工具的JSON Schema描述（用于LLM）
    func getToolsSchema() -> [[String: Any]] {
        [
            [
                "name": ToolType.launchApp.rawValue,
                "description": "通过Bundle ID启动macOS应用",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "bundle_id": [
                            "type": "string",
                            "description": "应用的Bundle Identifier，如 com.apple.Safari"
                        ]
                    ],
                    "required": ["bundle_id"]
                ]
            ],
            [
                "name": ToolType.manageService.rawValue,
                "description": "管理系统服务(start/stop/restart/status)",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "service_id": [
                            "type": "string",
                            "description": "服务ID，如 postgresql, redis, mysql"
                        ],
                        "action": [
                            "type": "string",
                            "enum": ["start", "stop", "restart", "status"],
                            "description": "要执行的操作"
                        ]
                    ],
                    "required": ["service_id", "action"]
                ]
            ],
            [
                "name": ToolType.executeSkill.rawValue,
                "description": "执行指定的Skill技能",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "skill_id": [
                            "type": "string",
                            "description": "Skill的唯一标识符"
                        ],
                        "input": [
                            "type": "string",
                            "description": "传递给Skill的输入参数"
                        ]
                    ],
                    "required": ["skill_id"]
                ]
            ],
            [
                "name": ToolType.searchMemory.rawValue,
                "description": "搜索对话历史记忆，获取相关上下文",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "query": [
                            "type": "string",
                            "description": "搜索关键词或查询语句"
                        ],
                        "session_id": [
                            "type": "string",
                            "description": "可选的会话ID，默认为main_session"
                        ]
                    ],
                    "required": ["query"]
                ]
            ],
            [
                "name": ToolType.createWorkflow.rawValue,
                "description": "创建新的工作流定义",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "name": [
                            "type": "string",
                            "description": "工作流的名称"
                        ],
                        "description": [
                            "type": "string",
                            "description": "工作流的详细描述"
                        ],
                        "steps": [
                            "type": "array",
                            "description": "可选的初始步骤列表"
                        ]
                    ],
                    "required": ["name", "description"]
                ]
            ]
        ]
    }
}

// MARK: - 便捷扩展

extension ToolExecutor {
    
    /// 批量执行工具
    /// - Parameter tasks: [(tool, parameters)] 数组
    /// - Returns: 结果数组
    func executeBatch(tasks: [(tool: String, parameters: [String: Any])]) async -> [ToolExecutionResult] {
        var results: [ToolExecutionResult] = []
        
        for task in tasks {
            let result = await execute(tool: task.tool, parameters: task.parameters)
            results.append(result)
        }
        
        return results
    }
    
    /// 验证工具参数
    /// - Parameters:
    ///   - tool: 工具名称
    ///   - parameters: 参数字典
    /// - Returns: 验证结果 (isValid, missingParams)
    func validateParameters(tool: String, parameters: [String: Any]) -> (isValid: Bool, missingParams: [String]) {
        guard let toolType = ToolType(rawValue: tool) else {
            return (false, ["invalid_tool"])
        }
        
        var requiredParams: [String] = []
        
        switch toolType {
        case .launchApp:
            requiredParams = ["bundle_id"]
        case .manageService:
            requiredParams = ["service_id", "action"]
        case .executeSkill:
            requiredParams = ["skill_id"]
        case .searchMemory:
            requiredParams = ["query"]
        case .createWorkflow:
            requiredParams = ["name", "description"]
        }
        
        let missing = requiredParams.filter { parameters[$0] == nil }
        return (missing.isEmpty, missing)
    }
}
