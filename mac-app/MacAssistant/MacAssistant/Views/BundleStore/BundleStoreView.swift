import SwiftUI
import Combine

// MARK: - BundleStoreViewModel

@MainActor
class BundleStoreViewModel: ObservableObject {
    @Published var marketplaceBundles: [BundleMetadata] = []
    @Published var installedBundles: [BundleInstance] = []
    @Published var searchQuery: String = "" {
        didSet { debouncedSearch() }
    }
    @Published var selectedType: BundleType? = nil
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var selectedBundle: BundleMetadata? = nil
    @Published var installProgress: [String: BundleInstallStatus] = [:]
    @Published var recommendedBundles: [BundleMetadata] = []
    @Published var categories: [BundleMarketplaceCategory] = []
    
    private let bundleService: BundleService
    private var cancellables = Set<AnyCancellable>()
    private var searchTask: Task<Void, Never>?
    
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
    
    init(bundleService: BundleService = .shared) {
        self.bundleService = bundleService
        setupNotifications()
    }
    
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
            await loadRecommendations()
        } catch {
            errorMessage = "加载失败: \(error.localizedDescription)"
        }
        isLoading = false
    }
    
    func refresh() async { await loadData() }
    
    func search() async {
        guard !searchQuery.isEmpty else { await loadData(); return }
        isLoading = true
        do {
            let result = try await bundleService.searchBundles(query: searchQuery, type: selectedType)
            self.marketplaceBundles = result.bundles
        } catch {
            errorMessage = "搜索失败: \(error.localizedDescription)"
        }
        isLoading = false
    }
    
    func installBundle(_ bundle: BundleMetadata) async {
        updateProgress(id: bundle.id, status: .installing(progress: 0))
        let result = await bundleService.installBundle(id: bundle.id)
        switch result {
        case .success(let instance):
            updateProgress(id: bundle.id, status: .installed(version: bundle.version))
            installedBundles.append(instance)
            if let index = marketplaceBundles.firstIndex(where: { $0.id == bundle.id }) {
                marketplaceBundles.remove(at: index)
            }
        case .failure(let error):
            updateProgress(id: bundle.id, status: .error(error.localizedDescription))
            errorMessage = error.localizedDescription
        }
    }
    
    func selectBundle(_ bundle: BundleMetadata) { selectedBundle = bundle }
    func deselectBundle() { selectedBundle = nil }
    func isInstalled(_ bundle: BundleMetadata) -> Bool { installedBundles.contains { $0.id == bundle.id } }
    func installStatus(for bundle: BundleMetadata) -> BundleInstallStatus {
        installProgress[bundle.id] ?? (isInstalled(bundle) ? .installed(version: bundle.version) : .notInstalled)
    }
    
    func getRecommendations(for intent: UserIntent) async {
        let bundles = await bundleService.recommendBundles(for: intent)
        recommendedBundles = bundles
    }
    
    private func debouncedSearch() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await search()
        }
    }
    
    private func loadCategories() async -> [BundleMarketplaceCategory] { [
        BundleMarketplaceCategory(name: "编程开发", icon: "chevron.left.forwardslash.chevron.right", bundles: BundleMetadata.samples.filter { $0.capabilities.contains(.codeAnalysis) || $0.capabilities.contains(.codeGeneration) }),
        BundleMarketplaceCategory(name: "AI 助手", icon: "brain", bundles: BundleMetadata.samples.filter { $0.capabilities.contains(.reasoning) }),
        BundleMarketplaceCategory(name: "创作工具", icon: "paintbrush", bundles: BundleMetadata.samples.filter { $0.capabilities.contains(.imageGeneration) })
    ]}
    
    private func loadRecommendations() async {
        let bundles = await bundleService.recommendBundles(for: .coding)
        recommendedBundles = bundles
    }
    
    private func updateProgress(id: String, status: BundleInstallStatus) { installProgress[id] = status }
    
    private func setupNotifications() {
        NotificationCenter.default.publisher(for: .bundleInstalled)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in Task { await self?.refresh() } }
            .store(in: &cancellables)
    }
}

extension BundleStoreViewModel {
    static var preview: BundleStoreViewModel {
        let vm = BundleStoreViewModel()
        vm.marketplaceBundles = BundleMetadata.samples
        return vm
    }
}

// MARK: - BundleStoreView

struct BundleStoreView: View {
    @StateObject private var viewModel = BundleStoreViewModel()
    @State private var selectedTab = 0
    @State private var showingIntentSelector = false
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 0) {
            // 自定义工具栏
            HStack {
                // 标签切换
                Picker("", selection: $selectedTab) {
                    Text("发现").tag(0)
                    Text("已安装").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
                
                Spacer()
                
                Button(action: { showingIntentSelector = true }) {
                    Image(systemName: "wand.and.stars")
                    Text("智能推荐")
                }
                .buttonStyle(.borderless)
                
                Divider().frame(height: 20)
                
                Button(action: { Task { await viewModel.refresh() } }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            if selectedTab == 0 {
                // 搜索栏
                HStack {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                    TextField("搜索 Bundles...", text: $viewModel.searchQuery)
                        .textFieldStyle(.plain)
                    if !viewModel.searchQuery.isEmpty {
                        Button(action: { viewModel.searchQuery = "" }) {
                            Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                        }.buttonStyle(.plain)
                    }
                }
                .padding(8)
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(8)
                .padding(.horizontal)
                .padding(.top, 12)
                
                // 类型过滤
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        FilterChip(title: "全部", isSelected: viewModel.selectedType == nil) { viewModel.selectedType = nil }
                        ForEach(BundleType.allCases) { type in
                            FilterChip(title: type.displayName, isSelected: viewModel.selectedType == type) { viewModel.selectedType = type }
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical, 8)
            }
            
            // 内容区域
            if viewModel.isLoading {
                Spacer()
                ProgressView("加载中...")
                Spacer()
            } else if let error = viewModel.errorMessage {
                Spacer()
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundColor(.orange)
                    Text(error).multilineTextAlignment(.center)
                    Button("重试") { Task { await viewModel.refresh() } }.buttonStyle(.borderedProminent)
                }
                .padding()
                Spacer()
            } else {
                if selectedTab == 0 {
                    DiscoveryView(viewModel: viewModel)
                } else {
                    InstalledBundlesView(viewModel: viewModel)
                }
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .sheet(item: $viewModel.selectedBundle) { bundle in
            BundleDetailSheet(bundle: bundle)
        }
        .sheet(isPresented: $showingIntentSelector) {
            IntentSelectorView { intent in
                Task { await viewModel.getRecommendations(for: intent); showingIntentSelector = false }
            }
        }
        .task { await viewModel.loadData() }
    }
}

struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .fontWeight(isSelected ? .semibold : .regular)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.accentColor : Color(NSColor.controlBackgroundColor))
                .foregroundColor(isSelected ? .white : .primary)
                .cornerRadius(16)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - DiscoveryView

struct DiscoveryView: View {
    @ObservedObject var viewModel: BundleStoreViewModel
    
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 20, pinnedViews: [.sectionHeaders]) {
                // 推荐区域
                if !viewModel.recommendedBundles.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("为你推荐", systemImage: "sparkles").font(.headline)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(viewModel.recommendedBundles) { bundle in
                                    RecommendedBundleCard(bundle: bundle, onTap: { viewModel.selectBundle(bundle) })
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                    .padding(.top)
                }
                
                // 分类
                ForEach(viewModel.categories) { category in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label(category.name, systemImage: category.icon).font(.headline)
                            Spacer()
                            Button("查看全部") {}.font(.caption)
                        }
                        .padding(.horizontal)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(category.bundles) { bundle in
                                    CompactBundleCard(bundle: bundle, onTap: { viewModel.selectBundle(bundle) })
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                }
                
                // 全部 Bundles
                Section {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 16)], spacing: 16) {
                        ForEach(viewModel.filteredBundles) { bundle in
                            BundleCard(
                                bundle: bundle,
                                installStatus: viewModel.installStatus(for: bundle),
                                isInstalled: viewModel.isInstalled(bundle),
                                onInstall: { Task { await viewModel.installBundle(bundle) } },
                                onSelect: { viewModel.selectBundle(bundle) }
                            )
                        }
                    }
                    .padding()
                } header: {
                    Text("全部 Bundles").font(.headline).padding().frame(maxWidth: .infinity, alignment: .leading).background(Color(NSColor.controlBackgroundColor))
                }
            }
            .padding(.bottom, 20)
        }
    }
}

// MARK: - InstalledBundlesView

struct InstalledBundlesView: View {
    @ObservedObject var viewModel: BundleStoreViewModel
    
    var body: some View {
        List {
            if viewModel.installedBundles.isEmpty {
                Section {
                    VStack(spacing: 16) {
                        Image(systemName: "cube.box").font(.system(size: 48)).foregroundColor(.secondary)
                        Text("还没有安装 Bundle").font(.headline)
                        Text("去商店发现适合你的 Bundles").font(.subheadline).foregroundColor(.secondary)
                        Button("去商店看看") {}
                            .buttonStyle(.borderedProminent)
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                }
            } else {
                let enabled = viewModel.installedBundles.filter { $0.isEnabled }
                let disabled = viewModel.installedBundles.filter { !$0.isEnabled }
                
                if !enabled.isEmpty {
                    Section("已启用") {
                        ForEach(enabled) { bundle in
                            InstalledBundleRow(bundle: bundle, onToggle: {}, onUpdate: nil, onUninstall: {})
                        }
                    }
                }
                
                if !disabled.isEmpty {
                    Section("已禁用") {
                        ForEach(disabled) { bundle in
                            InstalledBundleRow(bundle: bundle, onToggle: {}, onUpdate: nil, onUninstall: {})
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Preview

#Preview("Bundle Store") {
    BundleStoreView()
        .frame(width: 900, height: 700)
}
