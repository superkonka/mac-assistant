//
//  ServiceDiscoveryManager.swift
//  MacAssistant
//
//  服务发现管理器 - 支持三种服务来源
//

import Foundation
import Combine

/// 服务来源类型
enum ServiceSourceType: String, Codable {
    case chatGenerated    // 1. 用户聊天产出
    case diskDiscovered   // 2. 磁盘分析发现
    case remoteCloned     // 3. 远程克隆部署
}

/// 待确认的服务项（用于 Planner 和用户确认）
struct PendingService: Identifiable, Codable {
    let id: String = UUID().uuidString
    let name: String
    let description: String
    let sourceType: ServiceSourceType
    let sourcePath: String?           // 本地路径（磁盘发现）
    let remoteURL: String?            // 远程链接（手动添加）
    let suggestedPort: Int?
    let detectedTech: [String]?       // 检测到的技术栈
    let reason: String                // 推荐理由
    let discoveredAt: Date = Date()
    var confirmed: Bool = false
}

/// 服务发现管理器
@MainActor
final class ServiceDiscoveryManager: ObservableObject {
    static let shared = ServiceDiscoveryManager()
    
    // MARK: - Published
    
    /// 待确认的服务列表
    @Published var pendingServices: [PendingService] = []
    
    /// 磁盘扫描状态
    @Published var isScanningDisk = false
    
    /// 最后扫描时间
    @Published var lastScanTime: Date?
    
    /// 扫描进度
    @Published var scanProgress: String = ""
    
    // MARK: - Private
    
    private let serviceManager = ServiceManager.shared
    private let stateStore = ServiceStateStore.shared
    private var cancellables = Set<AnyCancellable>()
    
    private init() {
        setupNotificationHandlers()
    }
    
    // MARK: - 通知处理
    
    private func setupNotificationHandlers() {
        // 监听 AI 发现的服务
        NotificationCenter.default.publisher(for: .init("AIServiceDiscovered"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleAIServiceDiscovery(notification)
            }
            .store(in: &cancellables)
    }
    
    // MARK: - 1. 聊天产出服务
    
    /// 从对话中解析出服务需求
    func discoverFromChat(
        userMessage: String,
        aiResponse: String
    ) -> [PendingService] {
        var discovered: [PendingService] = []
        
        // 检测用户提到的服务需求
        let patterns: [(regex: String, tech: String, port: Int)] = [
            ("postgres|postgresql|数据库", "PostgreSQL", 5432),
            ("redis|缓存", "Redis", 6379),
            ("mongo|mongodb", "MongoDB", 27017),
            ("mysql", "MySQL", 3306),
            ("elasticsearch|es|搜索", "Elasticsearch", 9200),
            ("kafka|消息队列", "Kafka", 9092),
            ("nginx|代理", "Nginx", 80),
            ("rabbitmq|消息", "RabbitMQ", 5672),
        ]
        
        let lowerMessage = (userMessage + " " + aiResponse).lowercased()
        
        for (pattern, tech, port) in patterns {
            if lowerMessage.range(of: pattern, options: .regularExpression) != nil {
                // 检查是否已存在
                let exists = pendingServices.contains { 
                    $0.name.lowercased().contains(tech.lowercased()) 
                } || serviceManager.services.contains { 
                    $0.name.lowercased().contains(tech.lowercased()) 
                }
                
                if !exists {
                    let service = PendingService(
                        name: "\(tech) 服务",
                        description: "从对话中检测到可能需要 \(tech) 服务",
                        sourceType: .chatGenerated,
                        sourcePath: nil,
                        remoteURL: nil,
                        suggestedPort: port,
                        detectedTech: [tech],
                        reason: "对话中提到 '\(pattern)' 相关需求"
                    )
                    discovered.append(service)
                }
            }
        }
        
        // 添加到待确认列表
        if !discovered.isEmpty {
            pendingServices.append(contentsOf: discovered)
            notifyUserOfPendingServices()
        }
        
        return discovered
    }
    
    // MARK: - 2. 磁盘分析发现
    
    /// 扫描磁盘发现可部署的本地项目
    func scanDiskForProjects(
        rootPath: String = NSHomeDirectory(),
        depth: Int = 3
    ) async {
        guard !isScanningDisk else { return }
        
        isScanningDisk = true
        scanProgress = "开始扫描..."
        
        var discovered: [PendingService] = []
        
        // 常见项目配置文件和对应的技术栈
        let projectIndicators: [(file: String, tech: String, port: Int)] = [
            ("package.json", "Node.js", 3000),
            ("requirements.txt", "Python", 8000),
            ("Cargo.toml", "Rust", 8080),
            ("go.mod", "Go", 8080),
            ("pom.xml", "Java", 8080),
            ("build.gradle", "Java", 8080),
            ("Dockerfile", "Docker", 80),
            ("docker-compose.yml", "Docker Compose", 80),
            ("main.py", "Python", 8000),
            ("app.py", "Python Flask", 5000),
            ("manage.py", "Python Django", 8000),
            ("server.js", "Node.js", 3000),
            ("index.js", "Node.js", 3000),
        ]
        
        // 扫描目录
        let fileManager = FileManager.default
        let excludedDirs = [".git", "node_modules", ".venv", "venv", "target", "build", ".build", "dist", "Pods"]
        
        func scanDirectory(_ path: String, currentDepth: Int) {
            guard currentDepth <= depth else { return }
            
            scanProgress = "扫描: \(path)"
            
            do {
                let contents = try fileManager.contentsOfDirectory(atPath: path)
                
                // 检查是否是项目目录
                for (configFile, tech, port) in projectIndicators {
                    if contents.contains(configFile) {
                        let projectName = URL(fileURLWithPath: path).lastPathComponent
                        
                        // 检查是否已存在
                        let exists = pendingServices.contains { 
                            $0.sourcePath == path 
                        } || serviceManager.services.contains {
                            $0.metadata["sourcePath"] as? String == path
                        }
                        
                        if !exists {
                            let service = PendingService(
                                name: "\(projectName) (\(tech))",
                                description: "发现本地 \(tech) 项目",
                                sourceType: .diskDiscovered,
                                sourcePath: path,
                                remoteURL: nil,
                                suggestedPort: port,
                                detectedTech: [tech],
                                reason: "在 \(path) 发现 \(configFile)"
                            )
                            discovered.append(service)
                        }
                        
                        // 找到项目文件后不再深入扫描
                        return
                    }
                }
                
                // 递归扫描子目录
                for item in contents {
                    let itemPath = "\(path)/\(item)"
                    var isDir: ObjCBool = false
                    
                    if fileManager.fileExists(atPath: itemPath, isDirectory: &isDir) && isDir.boolValue {
                        // 排除特定目录
                        if !excludedDirs.contains(item) && !item.hasPrefix(".") {
                            scanDirectory(itemPath, currentDepth: currentDepth + 1)
                        }
                    }
                }
                
            } catch {
                // 忽略无权限访问的目录
            }
        }
        
        // 开始扫描（限制几个常用目录）
        let scanPaths = [
            "\(rootPath)/Documents",
            "\(rootPath)/Projects",
            "\(rootPath)/Code",
            "\(rootPath)/Developer",
        ]
        
        for path in scanPaths where FileManager.default.fileExists(atPath: path) {
            scanDirectory(path, currentDepth: 0)
        }
        
        // 添加到待确认列表
        if !discovered.isEmpty {
            pendingServices.append(contentsOf: discovered)
            notifyUserOfPendingServices()
        }
        
        isScanningDisk = false
        lastScanTime = Date()
        scanProgress = "扫描完成，发现 \(discovered.count) 个潜在服务"
    }
    
    // MARK: - 3. 手动添加远程
    
    /// 添加远程服务（clone 并部署）
    func addRemoteService(
        name: String,
        gitURL: String,
        branch: String = "main",
        deployPath: String? = nil
    ) async -> Result<PendingService, Error> {
        let service = PendingService(
            name: name,
            description: "远程仓库: \(gitURL)",
            sourceType: .remoteCloned,
            sourcePath: deployPath,
            remoteURL: gitURL,
            suggestedPort: nil,
            detectedTech: nil,
            reason: "用户手动添加的远程服务"
        )
        
        pendingServices.append(service)
        
        // 异步执行 clone
        Task {
            await cloneAndSetupService(service)
        }
        
        return .success(service)
    }
    
    /// Clone 并设置服务
    private func cloneAndSetupService(_ service: PendingService) async {
        guard let gitURL = service.remoteURL,
              let deployPath = service.sourcePath else { return }
        
        do {
            // 执行 git clone
            let process = Process()
            process.launchPath = "/usr/bin/git"
            process.arguments = ["clone", gitURL, deployPath]
            
            try process.run()
            process.waitUntilExit()
            
            if process.terminationStatus == 0 {
                // Clone 成功，尝试检测技术栈
                await analyzeClonedProject(service)
            }
        } catch {
            print("[ServiceDiscovery] Clone 失败: \(error)")
        }
    }
    
    /// 分析已 clone 的项目
    private func analyzeClonedProject(_ service: PendingService) async {
        guard let path = service.sourcePath else { return }
        
        // 这里可以调用 disk discovery 的逻辑分析项目
        // 简化版：直接注册为服务
    }
    
    // MARK: - 用户确认流程
    
    /// 用户确认添加服务
    func confirmService(_ pendingService: PendingService) {
        guard let index = pendingServices.firstIndex(where: { $0.id == pendingService.id }) else { return }
        
        pendingServices[index].confirmed = true
        
        // 注册到服务管理器
        let serviceId = "service.\(pendingService.name.lowercased().replacingOccurrences(of: " ", with: "_"))"
        
        serviceManager.registerService(
            id: serviceId,
            name: pendingService.name,
            port: pendingService.suggestedPort,
            preferredAdapter: pendingService.detectedTech?.first?.lowercased()
        )
        
        // 从待确认列表移除
        pendingServices.remove(at: index)
    }
    
    /// 用户拒绝添加服务
    func rejectService(_ pendingService: PendingService) {
        pendingServices.removeAll { $0.id == pendingService.id }
    }
    
    /// 忽略所有待确认服务
    func ignoreAllPending() {
        pendingServices.removeAll()
    }
    
    // MARK: - 通知
    
    private func notifyUserOfPendingServices() {
        NotificationCenter.default.post(
            name: .init("PendingServicesAvailable"),
            object: nil,
            userInfo: ["count": pendingServices.count]
        )
    }
    
    private func handleAIServiceDiscovery(_ notification: Notification) {
        // 处理 AI 主动发现的服务
        guard let userInfo = notification.userInfo,
              let services = userInfo["services"] as? [PendingService] else { return }
        
        pendingServices.append(contentsOf: services)
        notifyUserOfPendingServices()
    }
    
    // MARK: - 批量操作
    
    /// 确认所有待处理服务
    func confirmAll() {
        let toConfirm = pendingServices.filter { !$0.confirmed }
        for service in toConfirm {
            confirmService(service)
        }
    }
}

// MARK: - 扩展通知名

extension Notification.Name {
    static let pendingServicesAvailable = Notification.Name("PendingServicesAvailable")
}
