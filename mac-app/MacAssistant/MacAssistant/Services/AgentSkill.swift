//
//  AgentSkill.swift
//  MacAssistant
//
//  轻量级 Agent 工具系统 - 借鉴 OpenClaw Skills 设计
//

import Foundation

// MARK: - Skill 协议

protocol AgentSkill {
    var name: String { get }
    var description: String { get }
    var emoji: String { get }
    var requiredTools: [String] { get }
    
    func canHandle(_ command: String) -> Bool
    func execute(_ command: String, args: [String]) async throws -> String
}

// MARK: - Skill 注册表

class SkillRegistry {
    static let shared = SkillRegistry()
    
    private var skills: [String: AgentSkill] = [:]
    
    init() {
        registerDefaultSkills()
    }
    
    private func registerDefaultSkills() {
        register(SystemSkill())
        register(FileSkill())
        register(AppSkill())
        register(WebSkill())
        register(GitSkill())
        register(FutuSkill())
    }
    
    func register(_ skill: AgentSkill) {
        skills[skill.name] = skill
        LogInfo("✅ 注册 Skill: \(skill.emoji) \(skill.name)")
    }
    
    func getSkill(_ name: String) -> AgentSkill? {
        return skills[name]
    }
    
    func findSkill(for command: String) -> AgentSkill? {
        return skills.values.first { $0.canHandle(command) }
    }

    func allSkillNames() -> [String] {
        skills.keys.sorted()
    }
    
    func allSkillsDescription() -> String {
        return skills.values.map { "\($0.emoji) \($0.name): \($0.description)" }.joined(separator: "\n")
    }

    func formattedSkillOverview() -> String {
        skills.values
            .sorted { $0.name < $1.name }
            .map { "\($0.emoji) `/\($0.name)`: \($0.description)" }
            .joined(separator: "\n")
    }
}

// MARK: - 系统信息 Skill

struct SystemSkill: AgentSkill {
    let name = "system"
    let description = "获取系统信息：CPU、内存、磁盘、运行进程等"
    let emoji = "💻"
    let requiredTools = ["top", "df", "ps", "system_profiler"]
    
    func canHandle(_ command: String) -> Bool {
        let keywords = ["系统", "cpu", "内存", "磁盘", "进程", "system", "memory", "disk", "process"]
        return keywords.contains { command.lowercased().contains($0) }
    }
    
    func execute(_ command: String, args: [String]) async throws -> String {
        var results: [String] = []
        
        // CPU 和内存
        if let cpuMemory = runShellCommand("top -l 1 -n 0 | head -15") {
            results.append("📊 CPU/内存状态:\n\(cpuMemory)")
        }
        
        // 磁盘使用
        if let disk = runShellCommand("df -h /") {
            results.append("\n💾 磁盘使用:\n\(disk)")
        }
        
        // 系统信息
        if let sysInfo = runShellCommand("system_profiler SPHardwareDataType | grep -E '(Model|Memory|Chip)'") {
            results.append("\n🔧 硬件信息:\n\(sysInfo)")
        }
        
        return results.joined(separator: "\n")
    }
}

// MARK: - 文件操作 Skill

struct FileSkill: AgentSkill {
    let name = "file"
    let description = "文件操作：读取、搜索、目录列表等"
    let emoji = "📁"
    let requiredTools = ["ls", "cat", "find", "grep"]
    
    func canHandle(_ command: String) -> Bool {
        let keywords = ["文件", "目录", "读取", "搜索", "file", "folder", "directory", "read", "search", "find"]
        return keywords.contains { command.lowercased().contains($0) }
    }
    
    func execute(_ command: String, args: [String]) async throws -> String {
        // 安全限制：只允许访问用户目录
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        
        // 解析用户意图
        if command.contains("桌面") || command.contains("Desktop") {
            let desktop = "\(home)/Desktop"
            if let result = runShellCommand("ls -la '\(desktop)' | head -20") {
                return "📂 桌面文件:\n\(result)"
            }
        }
        
        if command.contains("下载") || command.contains("Downloads") {
            let downloads = "\(home)/Downloads"
            if let result = runShellCommand("ls -la '\(downloads)' | head -20") {
                return "📥 下载文件夹:\n\(result)"
            }
        }
        
        // 默认列出文档目录
        let documents = "\(home)/Documents"
        if let result = runShellCommand("ls -la '\(documents)' | head -20") {
            return "📄 文档文件夹:\n\(result)"
        }
        
        return "无法解析文件操作请求"
    }
}

// MARK: - 应用控制 Skill

struct AppSkill: AgentSkill {
    let name = "app"
    let description = "原生控制 macOS 应用：枚举、启动、退出，并校验是否真的成功"
    let emoji = "🚀"
    let requiredTools = ["NSWorkspace", "NSRunningApplication"]
    
    func canHandle(_ command: String) -> Bool {
        let keywords = ["启动", "打开", "退出", "关闭", "应用", "app", "open", "launch", "quit", "close"]
        return keywords.contains { command.lowercased().contains($0) }
    }
    
    func execute(_ command: String, args: [String]) async throws -> String {
        await MacSystemAgent.shared.handleAppCommand(command)
    }
}

// MARK: - Web 操作 Skill

struct WebSkill: AgentSkill {
    let name = "web"
    let description = "网络操作：搜索、打开网页、获取信息等"
    let emoji = "🌐"
    let requiredTools = ["open", "curl"]
    
    func canHandle(_ command: String) -> Bool {
        let keywords = ["搜索", "google", "百度", "网页", "网站", "search", "web", "url", "http"]
        return keywords.contains { command.lowercased().contains($0) }
    }
    
    func execute(_ command: String, args: [String]) async throws -> String {
        let lowerCommand = command.lowercased()
        
        // 提取搜索词
        var searchTerm: String?
        
        if command.contains("搜索") {
            if let range = command.range(of: "搜索") {
                searchTerm = String(command[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        } else if lowerCommand.contains("search for") {
            if let range = lowerCommand.range(of: "search for") {
                searchTerm = String(command[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        } else if lowerCommand.contains("google") {
            if let range = lowerCommand.range(of: "google") {
                searchTerm = String(command[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        
        if let term = searchTerm, !term.isEmpty {
            let encoded = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? term
            let url = "https://www.google.com/search?q=\(encoded)"
            _ = runShellCommand("open '\(url)'")
            return "🔍 已在浏览器中搜索: \(term)"
        }
        
        return "请提供搜索关键词"
    }
}

// MARK: - Git 操作 Skill

struct GitSkill: AgentSkill {
    let name = "git"
    let description = "Git 操作：状态、日志、分支等"
    let emoji = "🌿"
    let requiredTools = ["git"]
    
    func canHandle(_ command: String) -> Bool {
        let keywords = ["git", "提交", "commit", "分支", "branch", "日志", "log", "状态", "status"]
        return keywords.contains { command.lowercased().contains($0) }
    }
    
    func execute(_ command: String, args: [String]) async throws -> String {
        // 检查是否是 git 仓库
        let isGitRepo = runShellCommand("git rev-parse --git-dir 2>/dev/null") != nil
        
        guard isGitRepo else {
            return "❌ 当前目录不是 Git 仓库"
        }
        
        var results: [String] = []
        
        // Git 状态
        if let status = runShellCommand("git status --short") {
            results.append("📋 Git 状态:\n\(status.isEmpty ? "工作区干净" : status)")
        }
        
        // 最近提交
        if let log = runShellCommand("git log --oneline -5") {
            results.append("\n📝 最近提交:\n\(log)")
        }
        
        // 当前分支
        if let branch = runShellCommand("git branch --show-current") {
            results.append("\n🌿 当前分支: \(branch)")
        }
        
        return results.joined(separator: "\n")
    }
}

// MARK: - Futu OpenD Skill

struct FutuSkill: AgentSkill {
    let name = "futu"
    let description = "原生控制 FutuOpenD：启动、检查进程与端口，并验证是否真正就绪"
    let emoji = "📈"
    let requiredTools = ["NSWorkspace", "NWConnection"]
    
    func canHandle(_ command: String) -> Bool {
        let keywords = ["futu", "富途", "opend", "股票", "行情", "trade", "stock"]
        return keywords.contains { command.lowercased().contains($0) }
    }
    
    func execute(_ command: String, args: [String]) async throws -> String {
        await MacSystemAgent.shared.handleFutuCommand(command)
    }
}

// MARK: - 辅助函数

private func runShellCommand(_ command: String) -> String? {
    let task = Process()
    let pipe = Pipe()
    
    task.executableURL = URL(fileURLWithPath: "/bin/zsh")
    task.arguments = ["-c", command]
    task.standardOutput = pipe
    task.standardError = pipe
    
    do {
        try task.run()
        task.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        
        return output?.isEmpty == false ? output : nil
    } catch {
        LogError("Shell 命令失败: \(command)", error: error)
        return nil
    }
}
