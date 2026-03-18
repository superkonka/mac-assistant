import Foundation
import Combine

@MainActor
class BundleStoreViewModel: ObservableObject {
    // MARK: - Published Properties
    
    /// 市场 Bundles
    @Published var marketplaceBundles: [BundleMetadata] = []
    
    /// 已安装 Bundles
    @Published var installedBundles: [BundleInstance] = []
    
    /// 搜索查询
    @Published var searchQuery: String = "" {
        didSet {
            debouncedSearch()
        }
    }
    
    /// 选中的 Bundle 类型过滤
    @Published var selectedType: BundleType? = nil
    
    /// 加载状态
    @Published var isLoading = false
    
    /// 错误信息
    @Published var errorMessage: String?
    
    /// 当前显示的 Bundle 详情
    @Published var selectedBundle: BundleMetadata? = nil
    
    /// 安装进度
    @Published var installProgress: [String: BundleInstallStatus] = [:]
    
    /// 用户意图推荐
    @Published var recommendedBundles: [BundleMetadata] = []
    
    /// 分类列表
    @Published var categories: [BundleMarketplaceCategory] = []
    
    // MARK: - Private Properties
    
    private let bundleService: BundleService
    private var cancellables = Set<AnyCancellable>()
    private var searchTask: Task<Void, Never>?
    
    // MARK: - Computed Properties
    
    /// 过滤后的 Bundles
    var filteredBundles: [BundleMetadata] {
        var bundles = marketplaceBundles
        
        if !searchQuery.isEmpty {
            bundles = bundles.filter {
                $0.name.localizedCaseInsensitiveContains(searchQuery) ||
                $0.description.localizedCaseInsensitiveContains(searchQuery)
            }
        }
        
        if let type = selectedType {
            bundles = bundles.filter { $0.type == type }
        }
        
        return bundles
    }
    
    /// 是否需要显示空状态
    var shouldShowEmptyState: Bool {
        !isLoading && filteredBundles.isEmpty && !searchQuery.isEmpty
    }
    
    /// 是否有更新可用
    var hasUpdatesAvailable: Bool {
        // TODO: 检查已安装 Bundle 是否有更新
        false
    }
    
    // MARK: - Initialization
    
    init(bundleService: BundleService = .shared) {
        self.bundleService = bundleService
        setupNotifications()
    }
    
    // MARK: - Public Methods
    
    /// 加载初始数据
    func loadData() async {
        isLoading = true
        errorMessage = nil
        
        do {
            async let installedTask = bundleService.installedBundles()
            async let marketplaceTask = bundleService.searchBundles(query: "", type: nil)
            async let categoriesTask = loadCategories()
            
            let (installed, marketplace, cats) = try await (installedTask, marketplaceTask, categoriesTask)
            
            self.installedBundles = installed
            self.marketplaceBundles = marketplace.bundles
            self.categories = cats
            
            // 加载用户意图推荐
            await loadRecommendations()
            
        } catch {
            errorMessage = "加载失败: \(error.localizedDescription)"
        }
        
        isLoading = false
    }
    
    /// 刷新数据
    func refresh() async {
        await loadData()
    }
    
    /// 搜索 Bundles
    func search() async {
        guard !searchQuery.isEmpty else {
            await loadData()
            return
        }
        
        isLoading = true
        
        do {
            let result = try await bundleService.searchBundles(
                query: searchQuery,
                type: selectedType
            )
            self.marketplaceBundles = result.bundles
        } catch {
            errorMessage = "搜索失败: \(error.localizedDescription)"
        }
        
        isLoading = false
    }
    
    /// 安装 Bundle
    func installBundle(_ bundle: BundleMetadata) async {
        updateProgress(id: bundle.id, status: .installing(progress: 0))
        
        let result = await bundleService.installBundle(id: bundle.id)
        
        switch result {
        case .success(let instance):
            updateProgress(id: bundle.id, status: .installed(version: bundle.version))
            // 添加到已安装列表
            installedBundles.append(instance)
            // 从市场列表移除或标记
            if let index = marketplaceBundles.firstIndex(where: { $0.id == bundle.id }) {
                marketplaceBundles.remove(at: index)
            }
            
        case .failure(let error):
            updateProgress(id: bundle.id, status: .error(error.localizedDescription))
            errorMessage = error.localizedDescription
        }
    }
    
    /// 卸载 Bundle
    func uninstallBundle(_ bundle: BundleInstance) async {
        updateProgress(id: bundle.id, status: .uninstalling)
        
        do {
            try await bundleService.uninstallBundle(id: bundle.id)
            // 从已安装列表移除
            installedBundles.removeAll { $0.id == bundle.id }
            // 重新加载市场列表
            await loadData()
            
        } catch {
            updateProgress(id: bundle.id, status: .error(error.localizedDescription))
            errorMessage = error.localizedDescription
        }
    }
    
    /// 更新 Bundle
    func updateBundle(_ bundle: BundleInstance) async {
        updateProgress(id: bundle.id, status: .updating(
            fromVersion: bundle.metadata.version,
            toVersion: "latest"
        ))
        
        let result = await bundleService.updateBundle(id: bundle.id)
        
        switch result {
        case .success(let updated):
            updateProgress(id: bundle.id, status: .installed(version: updated.metadata.version))
            // 更新已安装列表
            if let index = installedBundles.firstIndex(where: { $0.id == bundle.id }) {
                installedBundles[index] = updated
            }
            
        case .failure(let error):
            updateProgress(id: bundle.id, status: .error(error.localizedDescription))
            errorMessage = error.localizedDescription
        }
    }
    
    /// 切换 Bundle 启用状态
    func toggleBundle(_ bundle: BundleInstance) async {
        do {
            try await bundleService.setBundleEnabled(id: bundle.id, enabled: !bundle.isEnabled)
            // 更新本地状态
            if let index = installedBundles.firstIndex(where: { $0.id == bundle.id }) {
                let updated = BundleInstance(
                    id: bundle.id,
                    metadata: bundle.metadata,
                    installPath: bundle.installPath,
                    installedAt: bundle.installedAt,
                    lastUsedAt: bundle.lastUsedAt,
                    config: bundle.config,
                    isEnabled: !bundle.isEnabled
                )
                installedBundles[index] = updated
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    
    /// 选择 Bundle 查看详情
    func selectBundle(_ bundle: BundleMetadata) {
        selectedBundle = bundle
    }
    
    /// 关闭详情
    func deselectBundle() {
        selectedBundle = nil
    }
    
    /// 检查 Bundle 是否已安装
    func isInstalled(_ bundle: BundleMetadata) -> Bool {
        installedBundles.contains { $0.id == bundle.id }
    }
    
    /// 获取 Bundle 安装状态
    func installStatus(for bundle: BundleMetadata) -> BundleInstallStatus {
        installProgress[bundle.id] ?? (isInstalled(bundle) ? .installed(version: bundle.version) : .notInstalled)
    }
    
    /// 基于意图获取推荐
    func getRecommendations(for intent: UserIntent) async {
        let bundles = await bundleService.recommendBundles(for: intent)
        recommendedBundles = bundles
    }
    
    /// 一键配置 Bundle（自动创建 Agent）
    func quickSetupBundle(_ bundle: BundleMetadata) async -> Result<AgentConfigurationSuggestion, Error> {
        // 1. 检查是否已安装
        if !isInstalled(bundle) {
            await installBundle(bundle)
        }
        
        guard let instance = installedBundles.first(where: { $0.id == bundle.id }) else {
            return .failure(BundleInstallResult.BundleInstallError.unknown("安装失败"))
        }
        
        // 2. 返回 Agent 配置建议
        let suggestion = instance.agentConfiguration()
        return .success(suggestion)
    }
    
    // MARK: - Private Methods
    
    private func debouncedSearch() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000) // 300ms debounce
            guard !Task.isCancelled else { return }
            await search()
        }
    }
    
    private func loadCategories() async -> [BundleMarketplaceCategory] {
        // 基于类型和能力分类
        [
            BundleMarketplaceCategory(
                name: "编程开发",
                icon: "chevron.left.forwardslash.chevron.right",
                bundles: BundleMetadata.samples.filter {
                    $0.capabilities.contains(.codeAnalysis) || $0.capabilities.contains(.codeGeneration)
                }
            ),
            BundleMarketplaceCategory(
                name: "AI 助手",
                icon: "brain",
                bundles: BundleMetadata.samples.filter {
                    $0.capabilities.contains(.reasoning)
                }
            ),
            BundleMarketplaceCategory(
                name: "创作工具",
                icon: "paintbrush",
                bundles: BundleMetadata.samples.filter {
                    $0.capabilities.contains(.writing) || $0.capabilities.contains(.imageGeneration)
                }
            )
        ]
    }
    
    private func loadRecommendations() async {
        // 默认推荐编程相关
        let bundles = await bundleService.recommendBundles(for: .coding)
        recommendedBundles = bundles
    }
    
    private func updateProgress(id: String, status: BundleInstallStatus) {
        installProgress[id] = status
    }
    
    private func setupNotifications() {
        NotificationCenter.default.publisher(for: .bundleInstalled)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task {
                    await self?.refresh()
                }
            }
            .store(in: &cancellables)
    }
}

// MARK: - 预览支持

extension BundleStoreViewModel {
    static var preview: BundleStoreViewModel {
        let vm = BundleStoreViewModel()
        vm.marketplaceBundles = BundleMetadata.samples
        vm.categories = [
            BundleMarketplaceCategory(
                name: "编程开发",
                icon: "chevron.left.forwardslash.chevron.right",
                bundles: BundleMetadata.samples
            )
        ]
        return vm
    }
}
