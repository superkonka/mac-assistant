//
//  CLIExecutor.swift
//  MacAssistant
//
//  接收 ExecutionContext 的无状态执行器
//

import Foundation

/// CLI 执行结果
struct CLIExecutionResult {
    let success: Bool
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let command: String
    let executionTime: TimeInterval
    let attempts: Int                      // 重试次数
    
    // 根据上下文处理后的友好输出
    let friendlyOutput: String
}

/// CLI 执行配置
struct CLIExecutionConfig {
    let maxRetries: Int
    let retryDelay: TimeInterval
    let retryableExitCodes: [Int32]
    
    static let `default` = CLIExecutionConfig(
        maxRetries: 3,
        retryDelay: 1.0,
        retryableExitCodes: [1, 126, 127, 130]  // 可重试的错误码
    )
}

/// 无状态 CLI 执行器 - 接收完整上下文，执行后销毁
enum CLIExecutor {
    
    // MARK: - 执行入口
    
    /// 执行服务管理任务（带完整上下文，支持重试）
    static func execute(
        context: ExecutionContext,
        config: CLIExecutionConfig = .default,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async -> CLIExecutionResult {
        
        let startTime = Date()
        let progressActor = ProgressActor(onProgress: onProgress)
        
        await progressActor.report("[Planner] 任务 \(context.taskId) 开始执行")
        await progressActor.report("[Planner] 使用适配器: \(context.prerequisites.detectedAdapter ?? "auto")")
        
        // 1. 根据上下文构建命令
        let commands = buildCommands(from: context)
        
        // 2. 设置环境
        var env = ProcessInfo.processInfo.environment
        env.merge(context.environment) { _, new in new }
        
        // 3. 顺序执行命令（带重试）
        var combinedOutput: [String] = []
        var finalExitCode: Int32 = 0
        var totalAttempts = 0
        var hasError = false
        
        for (index, command) in commands.enumerated() {
            guard !hasError || context.userPreferences.autoConfirm else { break }
            
            await progressActor.report("[执行 \(index+1)/\(commands.count)] \(command.prefix(50))...")
            
            // 执行命令（带重试）
            let (result, attempts) = await executeWithRetry(
                command: command,
                environment: env,
                workingDirectory: context.workingDirectory,
                timeout: context.timeout,
                config: config,
                onProgress: { msg in Task { await progressActor.report(msg) } }
            )
            
            totalAttempts += attempts
            
            combinedOutput.append("$ \(command)")
            combinedOutput.append(result.stdout)
            if !result.stderr.isEmpty {
                combinedOutput.append("[stderr] \(result.stderr)")
            }
            
            finalExitCode = result.exitCode
            
            // 处理错误
            if !result.success {
                hasError = true
                await progressActor.report("[错误] 命令失败，exit code: \(result.exitCode)，尝试次数: \(attempts)")
                
                // 尝试错误恢复
                if let recovery = attemptRecovery(
                    context: context,
                    command: command,
                    error: result.stderr,
                    exitCode: result.exitCode
                ) {
                    await progressActor.report("[恢复] \(recovery.message)")
                    combinedOutput.append("[恢复操作] \(recovery.command)")
                    
                    let recoveryResult = await executeCommand(
                        recovery.command,
                        environment: env,
                        workingDirectory: context.workingDirectory,
                        timeout: context.timeout
                    )
                    
                    if recoveryResult.success {
                        await progressActor.report("[恢复] 成功，重试原命令...")
                        hasError = false
                        // 重试原命令
                        let retryResult = await executeCommand(
                            command,
                            environment: env,
                            workingDirectory: context.workingDirectory,
                            timeout: context.timeout
                        )
                        if retryResult.success {
                            hasError = false
                            finalExitCode = 0
                        }
                    }
                }
            }
        }
        
        let executionTime = Date().timeIntervalSince(startTime)
        let fullOutput = combinedOutput.joined(separator: "\n")
        
        // 4. 生成友好输出
        let friendlyOutput = generateFriendlyOutput(
            context: context,
            success: finalExitCode == 0,
            output: fullOutput
        )
        
        return CLIExecutionResult(
            success: finalExitCode == 0,
            exitCode: finalExitCode,
            stdout: fullOutput,
            stderr: "",
            command: commands.joined(separator: "; "),
            executionTime: executionTime,
            attempts: totalAttempts,
            friendlyOutput: friendlyOutput
        )
    }
    
    // MARK: - 带重试的命令执行
    
    private static func executeWithRetry(
        command: String,
        environment: [String: String],
        workingDirectory: String?,
        timeout: TimeInterval,
        config: CLIExecutionConfig,
        onProgress: (@Sendable (String) -> Void)?
    ) async -> (result: (stdout: String, stderr: String, exitCode: Int32, success: Bool), attempts: Int) {
        
        var lastResult: (stdout: String, stderr: String, exitCode: Int32, success: Bool)!
        
        for attempt in 1...config.maxRetries {
            lastResult = await executeCommand(
                command,
                environment: environment,
                workingDirectory: workingDirectory,
                timeout: timeout
            )
            
            if lastResult.success {
                return (lastResult, attempt)
            }
            
            // 检查是否应该重试
            if attempt < config.maxRetries && config.retryableExitCodes.contains(lastResult.exitCode) {
                onProgress?("[重试] 第 \(attempt) 次失败，\(Int(config.retryDelay))秒后重试...")
                try? await Task.sleep(nanoseconds: UInt64(config.retryDelay * 1_000_000_000))
            } else {
                return (lastResult, attempt)
            }
        }
        
        return (lastResult, config.maxRetries)
    }
    
    // MARK: - 命令构建
    
    private static func buildCommands(from context: ExecutionContext) -> [String] {
        var commands: [String] = []
        
        let adapter = context.prerequisites.detectedAdapter ?? detectBestAdapter()
        let service = context.serviceId
        
        switch context.operation {
        case "start":
            // 前置检查
            if context.prerequisites.portAvailable != nil {
                commands.append("echo '检查端口 \(context.prerequisites.portAvailable!)...'")
            }
            
            // 根据适配器构建启动命令
            switch adapter {
            case "homebrew":
                commands.append("brew services start \(service)")
            case "docker":
                commands.append("docker start \(service) 2>/dev/null || docker run -d --name \(service) \(service)")
            default:
                commands.append("nohup \(service) > /dev/null 2>&1 &")
            }
            
            // 等待启动
            commands.append("sleep 2")
            
            // 健康检查
            if context.prerequisites.portAvailable != nil {
                commands.append("nc -z 127.0.0.1 \(context.prerequisites.portAvailable!) && echo '端口就绪'")
            }
            
        case "stop":
            switch adapter {
            case "homebrew":
                commands.append("brew services stop \(service)")
            case "docker":
                commands.append("docker stop \(service)")
            default:
                commands.append("pkill -TERM -x \(service) || true")
                commands.append("sleep 1")
                commands.append("pkill -9 -x \(service) || true")
            }
            
        case "install":
            switch adapter {
            case "homebrew":
                commands.append("brew install \(service)")
            case "docker":
                commands.append("docker pull \(service):latest")
            default:
                commands.append("echo '不支持自动安装 \(service)'")
            }
            
        case "status":
            switch adapter {
            case "homebrew":
                commands.append("brew services list | grep \(service) | awk '{print $2}'")
            case "docker":
                commands.append("docker ps --filter name=\(service) --format '{{.Status}}'")
            default:
                commands.append("pgrep -x \(service) > /dev/null && echo 'running' || echo 'stopped'")
            }
            
        case "logs":
            let lines = context.userPreferences.verboseOutput ? "100" : "20"
            switch adapter {
            case "homebrew":
                commands.append("tail -n \(lines) ~/Library/Logs/Homebrew/\(service).log 2>/dev/null || echo '无日志'")
            case "docker":
                commands.append("docker logs --tail \(lines) \(service)")
            default:
                commands.append("echo '原生进程日志需手动查看'")
            }
            
        default:
            commands.append("echo '未知操作: \(context.operation)'")
        }
        
        return commands
    }
    
    // MARK: - 单命令执行
    
    private static func executeCommand(
        _ command: String,
        environment: [String: String],
        workingDirectory: String?,
        timeout: TimeInterval
    ) async -> (stdout: String, stderr: String, exitCode: Int32, success: Bool) {
        
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-c", command]
        task.environment = environment
        
        if let wd = workingDirectory {
            task.currentDirectoryURL = URL(fileURLWithPath: wd)
        }
        
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        task.standardOutput = stdoutPipe
        task.standardError = stderrPipe
        
        do {
            try task.run()
            
            // 超时处理
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if task.isRunning {
                    task.terminate()
                }
            }
            
            task.waitUntilExit()
            timeoutTask.cancel()
            
            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            
            return (
                stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                stderr: String(data: stderrData, encoding: .utf8) ?? "",
                exitCode: task.terminationStatus,
                success: task.terminationStatus == 0
            )
            
        } catch {
            return (
                stdout: "",
                stderr: error.localizedDescription,
                exitCode: -1,
                success: false
            )
        }
    }
    
    // MARK: - 错误恢复
    
    private struct RecoveryAction {
        let command: String
        let message: String
    }
    
    private static func attemptRecovery(
        context: ExecutionContext,
        command: String,
        error: String,
        exitCode: Int32
    ) -> RecoveryAction? {
        let lowerError = error.lowercased()
        
        // 端口冲突恢复
        if lowerError.contains("address already in use") || lowerError.contains("port is already allocated") {
            if let port = context.prerequisites.portAvailable {
                return RecoveryAction(
                    command: "lsof -ti:\(port) | xargs kill -9 2>/dev/null || true",
                    message: "尝试终止占用端口 \(port) 的进程"
                )
            }
        }
        
        // 权限问题恢复
        if exitCode == 126 || lowerError.contains("permission denied") {
            return RecoveryAction(
                command: "echo '需要 sudo 权限'",
                message: "检测到权限问题，建议检查服务配置或使用 sudo"
            )
        }
        
        // Docker 容器不存在
        if lowerError.contains("no such container") {
            return RecoveryAction(
                command: "echo '容器不存在，将重新创建'",
                message: "Docker 容器不存在，需要重新创建"
            )
        }
        
        return nil
    }
    
    // MARK: - 线程安全进度报告
    
    private actor ProgressActor {
        private let onProgress: ((String) -> Void)?
        
        init(onProgress: ((String) -> Void)?) {
            self.onProgress = onProgress
        }
        
        func report(_ message: String) {
            onProgress?(message)
        }
    }
    
    // MARK: - 辅助方法
    
    private static func detectBestAdapter() -> String {
        if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/brew") ||
           FileManager.default.fileExists(atPath: "/usr/local/bin/brew") {
            return "homebrew"
        }
        return "native"
    }
    
    private static func generateFriendlyOutput(
        context: ExecutionContext,
        success: Bool,
        output: String
    ) -> String {
        if success {
            switch context.operation {
            case "start":
                if let intent = context.userIntent {
                    return "✅ \(intent) - 服务已启动"
                }
                return "✅ \(context.serviceId) 已启动"
            case "stop":
                return "✅ \(context.serviceId) 已停止"
            case "install":
                return "✅ \(context.serviceId) 安装完成"
            default:
                return "✅ 操作完成"
            }
        } else {
            return "❌ \(context.serviceId) 操作失败，请检查日志"
        }
    }
}
