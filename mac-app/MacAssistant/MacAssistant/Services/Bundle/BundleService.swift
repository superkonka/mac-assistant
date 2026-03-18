import Foundation
import Combine

/// Bundle 服务协议
protocol BundleServiceProtocol: Actor {
    /// 获取已安装的 Bundles
    func installedBundles() async -> [BundleInstance]
    
    /// 搜索市场 Bundles
    func searchBundles(query: String, type: BundleType?) async throws -> BundleSearchResult
    
    /// 获取 Bundle 详情
    func bundleDetail(id: String) async throws -> BundleMetadata
    
    /// 安装 Bundle
    func installBundle(id: String) async -> BundleInstallResult
    
    /// 卸载 Bundle
    func uninstallBundle(id: String) async throws
    
    /// 更新 Bundle
    func updateBundle(id: String) async -> BundleInstallResult
    
    /// 启用/禁用 Bundle
    func setBundleEnabled(id: String, enabled: Bool) async throws
    
    /// 获取 Bundle 安装状态
    func installStatus(id: String) -> BundleInstallStatus
    
    /// 检查依赖是否满足
    func checkDependencies(_ bundle: BundleMetadata) async -> [String]
    
    /// 推荐 Bundles（基于用户意图）
    func recommendBundles(for intent: UserIntent) async -> [BundleMetadata]
}

/// 用户意图
enum UserIntent: String, CaseIterable {
    case coding = "coding"
    case writing = "writing"
    case analysis = "analysis"
    case search = "search"
    case imageGeneration = "image_generation"
    case learning = "learning"
    case debugging = "debugging"
    
    var displayName: String {
        switch self {
        case .coding: return "编程开发"
        case .writing: return "写作创作"
        case .analysis: return "数据分析"
        case .search: return "信息搜索"
        case .imageGeneration: return "图片生成"
        case .learning: return "学习辅助"
        case .debugging: return "调试排错"
        }
    }
    
    var icon: String {
        switch self {
        case .coding: return "chevron.left.forwardslash.chevron.right"
        case .writing: return "pencil.line"
        case .analysis: return "chart.bar"
        case .search: return "magnifyingglass"
        case .imageGeneration: return "photo.artframe"
        case .learning: return "graduationcap"
        case .debugging: return "ant.fill"
        }
    }
    
    var suggestedBundles: [String] {
        switch self {
        case .coding:
            return ["claude-coding", "codex-pro", "cursor-ai"]
        case .writing:
            return ["claude-writing", "gpt-writer"]
        case .analysis:
            return ["claude-analysis", "data-science-kit"]
        case .search:
            return ["firecrawl-search", "web-researcher"]
        case .imageGeneration:
            return ["dalle-generator", "midjourney-assistant"]
        case .learning:
            return ["claude-tutor", "explainer-pro"]
        case .debugging:
            return ["debug-assistant", "error-explainer"]
        }
    }
}

/// Bundle 服务实现
actor BundleService: BundleServiceProtocol {
    static let shared = BundleService()
    
    private var installedBundlesCache: [String: BundleInstance] = [:]
    private var installProgress: [String: BundleInstallStatus] = [:]
    private var cancellables = Set<AnyCancellable>()
    
    private let commandRunner: OpenClawCommandRunner
    private let storage: BundleStorage
    
    init(
        commandRunner: OpenClawCommandRunner = .shared,
        storage: BundleStorage = .shared
    ) {
        self.commandRunner = commandRunner
        self.storage = storage
    }
    
    // MARK: - 公开方法
    
    func installedBundles() async -> [BundleInstance] {
        // 优先从缓存读取
        if !installedBundlesCache.isEmpty {
            return Array(installedBundlesCache.values).sorted { $0.installedAt > $1.installedAt }
        }
        
        // 从存储加载
        let bundles = await storage.loadInstalledBundles()
        for bundle in bundles {
            installedBundlesCache[bundle.id] = bundle
        }
        return bundles.sorted { $0.installedAt > $1.installedAt }
    }
    
    func searchBundles(query: String, type: BundleType?) async throws -> BundleSearchResult {
        // TODO: 调用 OpenClaw CLI: openclaw bundle search <query> --json
        // 目前返回模拟数据
        var bundles = BundleMetadata.samples
        
        // 搜索过滤
        if !query.isEmpty {
            bundles = bundles.filter {
                $0.name.localizedCaseInsensitiveContains(query) ||
                $0.description.localizedCaseInsensitiveContains(query) ||
                $0.capabilities.contains(where: { $0.displayName.localizedCaseInsensitiveContains(query) })
            }
        }
        
        // 类型过滤
        if let type = type {
            bundles = bundles.filter { $0.type == type }
        }
        
        return BundleSearchResult(
            bundles: bundles,
            totalCount: bundles.count,
            hasMore: false,
            query: query
        )
    }
    
    func bundleDetail(id: String) async throws -> BundleMetadata {
        // 先检查本地
        if let local = installedBundlesCache[id] {
            return local.metadata
        }
        
        // 从市场获取详情
        // TODO: 调用 OpenClaw CLI: openclaw bundle show <id> --json
        if let sample = BundleMetadata.samples.first(where: { $0.id == id }) {
            return sample
        }
        
        throw BundleError.notFound
    }
    
    func installBundle(id: String) async -> BundleInstallResult {
        // 检查是否已安装
        if installedBundlesCache[id] != nil {
            return .failure(.alreadyInstalled)
        }
        
        // 获取 Bundle 详情
        guard let metadata = try? await bundleDetail(id: id) else {
            return .failure(.invalidBundle)
        }
        
        // 检查依赖
        let missingDeps = await checkDependencies(metadata)
        if !missingDeps.isEmpty {
            return .failure(.dependencyMissing(missingDeps))
        }
        
        // 检查 Provider 配置
        let unconfiguredProviders = await checkProviderConfiguration(metadata.requiredProviders)
        if !unconfiguredProviders.isEmpty {
            return .failure(.providerNotConfigured(unconfiguredProviders))
        }
        
        // 开始安装
        await updateStatus(id: id, status: .installing(progress: 0))
        
        do {
            // 模拟安装进度
            for progress in stride(from: 0.0, through: 1.0, by: 0.1) {
                try await Task.sleep(nanoseconds: 200_000_000) // 200ms
                await updateStatus(id: id, status: .installing(progress: progress))
            }
            
            // TODO: 实际调用 OpenClaw CLI
            // let result = try await commandRunner.run("bundle", "install", id, "--json")
            
            let instance = BundleInstance(
                id: id,
                metadata: metadata,
                installPath: "~/.openclaw/bundles/\(id)",
                installedAt: Date(),
                lastUsedAt: nil,
                config: [:],
                isEnabled: true
            )
            
            // 保存到缓存和存储
            installedBundlesCache[id] = instance
            await storage.saveBundle(instance)
            
            // 自动配置沙箱（如果需要）
            if let sandboxConfig = metadata.sandboxConfig, sandboxConfig.required {
                _ = await configureSandbox(for: instance)
            }
            
            await updateStatus(id: id, status: .installed(version: metadata.version))
            
            // 发送安装成功通知
            await NotificationCenter.default.post(
                name: .bundleInstalled,
                object: nil,
                userInfo: ["bundleId": id]
            )
            
            return .success(instance)
            
        } catch {
            await updateStatus(id: id, status: .error(error.localizedDescription))
            return .failure(.unknown(error.localizedDescription))
        }
    }
    
    func uninstallBundle(id: String) async throws {
        guard installedBundlesCache[id] != nil else {
            throw BundleError.notFound
        }
        
        await updateStatus(id: id, status: .uninstalling)
        
        // TODO: 调用 OpenClaw CLI: openclaw bundle uninstall <id>
        // try await commandRunner.run("bundle", "uninstall", id)
        
        // 清理缓存和存储
        installedBundlesCache.removeValue(forKey: id)
        await storage.removeBundle(id: id)
        installProgress.removeValue(forKey: id)
        
        await NotificationCenter.default.post(
            name: .bundleUninstalled,
            object: nil,
            userInfo: ["bundleId": id]
        )
    }
    
    func updateBundle(id: String) async -> BundleInstallResult {
        guard let current = installedBundlesCache[id] else {
            return .failure(.unknown("Bundle 未安装"))
        }
        
        do {
            let metadata = try await bundleDetail(id: id)
            
            guard metadata.version != current.metadata.version else {
                return .success(current) // 已是最新
            }
            
            await updateStatus(id: id, status: .updating(
                fromVersion: current.metadata.version,
                toVersion: metadata.version
            ))
            
            // TODO: 调用 OpenClaw CLI: openclaw bundle update <id>
            
            let updated = BundleInstance(
                id: id,
                metadata: metadata,
                installPath: current.installPath,
                installedAt: current.installedAt,
                lastUsedAt: current.lastUsedAt,
                config: current.config,
                isEnabled: current.isEnabled
            )
            
            installedBundlesCache[id] = updated
            await storage.saveBundle(updated)
            await updateStatus(id: id, status: .installed(version: metadata.version))
            
            await NotificationCenter.default.post(
                name: .bundleUpdated,
                object: nil,
                userInfo: ["bundleId": id]
            )
            
            return .success(updated)
            
        } catch {
            return .failure(.unknown(error.localizedDescription))
        }
    }
    
    func setBundleEnabled(id: String, enabled: Bool) async throws {
        guard var bundle = installedBundlesCache[id] else {
            throw BundleError.notFound
        }
        
        // 创建新的实例（因为 struct 是值类型）
        let updated = BundleInstance(
            id: bundle.id,
            metadata: bundle.metadata,
            installPath: bundle.installPath,
            installedAt: bundle.installedAt,
            lastUsedAt: bundle.lastUsedAt,
            config: bundle.config,
            isEnabled: enabled
        )
        
        installedBundlesCache[id] = updated
        await storage.saveBundle(updated)
        
        // TODO: 调用 OpenClaw CLI 启用/禁用
    }
    
    func installStatus(id: String) -> BundleInstallStatus {
        installProgress[id] ?? .notInstalled
    }
    
    func checkDependencies(_ bundle: BundleMetadata) async -> [String] {
        let installed = await installedBundles()
        let installedIds = installed.map { $0.id }
        
        return bundle.dependencies.compactMap { dep in
            dep.optional ? nil : (installedIds.contains(dep.name) ? nil : dep.name)
        }
    }
    
    func recommendBundles(for intent: UserIntent) async -> [BundleMetadata] {
        let suggestedIds = intent.suggestedBundles
        var results: [BundleMetadata] = []
        
        for id in suggestedIds {
            if let bundle = try? await bundleDetail(id: id) {
                results.append(bundle)
            }
        }
        
        // 如果推荐的都不可用，返回同类型的热门 Bundle
        if results.isEmpty {
            results = BundleMetadata.samples.filter {
                $0.capabilities.contains(where: { capability in
                    switch intent {
                    case .coding:
                        return [.codeAnalysis, .codeGeneration].contains(capability)
                    case .writing:
                        return [.writing, .longContext].contains(capability)
                    case .analysis:
                        return [.reasoning, .codeAnalysis].contains(capability)
                    case .search:
                        return [.webSearch].contains(capability)
                    case .imageGeneration:
                        return [.imageGeneration].contains(capability)
                    case .learning:
                        return [.reasoning, .writing].contains(capability)
                    case .debugging:
                        return [.codeAnalysis, .reasoning].contains(capability)
                    }
                })
            }
        }
        
        return results
    }
    
    // MARK: - 私有方法
    
    private func updateStatus(id: String, status: BundleInstallStatus) {
        installProgress[id] = status
    }
    
    private func checkProviderConfiguration(_ providers: [ProviderType]) async -> [ProviderType] {
        // TODO: 检查每个 provider 是否已配置
        // 临时返回空数组（假设都已配置）
        return []
    }
    
    private func configureSandbox(for bundle: BundleInstance) async -> Result<Void, Error> {
        guard let config = bundle.metadata.sandboxConfig else {
            return .success(())
        }
        
        // TODO: 调用 SandboxService 配置沙箱
        // 临时返回成功
        return .success(())
    }
}

// MARK: - 错误类型

enum BundleError: Error {
    case notFound
    case installationFailed(String)
    case networkError
}

// MARK: - 通知名称

extension Notification.Name {
    static let bundleInstalled = Notification.Name("bundleInstalled")
    static let bundleUninstalled = Notification.Name("bundleUninstalled")
    static let bundleUpdated = Notification.Name("bundleUpdated")
}

// MARK: - 辅助类型

/// OpenClaw 命令执行器（占位）
actor OpenClawCommandRunner {
    static let shared = OpenClawCommandRunner()
    
    func run(_ args: String...) async throws -> Data {
        // TODO: 实际调用 openclaw CLI
        return Data()
    }
}

/// Bundle 存储（占位）
actor BundleStorage {
    static let shared = BundleStorage()
    
    func loadInstalledBundles() async -> [BundleInstance] {
        // TODO: 从本地存储加载
        return []
    }
    
    func saveBundle(_ bundle: BundleInstance) async {
        // TODO: 保存到本地存储
    }
    
    func removeBundle(id: String) async {
        // TODO: 从本地存储删除
    }
}
