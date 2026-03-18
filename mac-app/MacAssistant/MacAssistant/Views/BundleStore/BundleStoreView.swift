import SwiftUI

struct BundleStoreView: View {
    @StateObject private var viewModel = BundleStoreViewModel()
    @State private var selectedTab = 0
    @State private var showingIntentSelector = false
    
    var body: some View {
        VStack(spacing: 0) {
            // 标签切换
            Picker("视图", selection: $selectedTab) {
                Text("发现").tag(0)
                Text("已安装").tag(1)
            }
            .pickerStyle(.segmented)
            .padding()
            
            // 搜索栏
            SearchBar(
                text: $viewModel.searchQuery,
                placeholder: "搜索 Bundles..."
            )
            .padding(.horizontal)
            
            // 类型过滤
            if selectedTab == 0 {
                BundleTypeFilter(
                    selectedType: $viewModel.selectedType
                )
                .padding(.horizontal)
            }
            
            // 主要内容
            if viewModel.isLoading {
                Spacer()
                ProgressView("加载中...")
                Spacer()
            } else if let error = viewModel.errorMessage {
                Spacer()
                ErrorView(message: error, retryAction: {
                    Task {
                        await viewModel.refresh()
                    }
                })
                Spacer()
            } else {
                TabView(selection: $selectedTab) {
                    // 发现页
                    DiscoveryView(viewModel: viewModel)
                        .tag(0)
                    
                    // 已安装页
                    InstalledBundlesView(viewModel: viewModel)
                        .tag(1)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
        }
        .navigationTitle("Bundle 商店")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: {
                    showingIntentSelector = true
                }) {
                    Image(systemName: "wand.and.stars")
                    Text("智能推荐")
                }
            }
            
            ToolbarItem(placement: .cancellationAction) {
                Button(action: {
                    Task {
                        await viewModel.refresh()
                    }
                }) {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .sheet(item: $viewModel.selectedBundle) { bundle in
            BundleDetailSheet(
                bundle: bundle,
                viewModel: viewModel
            )
        }
        .sheet(isPresented: $showingIntentSelector) {
            IntentSelectorView { intent in
                Task {
                    await viewModel.getRecommendations(for: intent)
                    showingIntentSelector = false
                }
            }
        }
        .task {
            await viewModel.loadData()
        }
    }
}

// MARK: - 发现视图

struct DiscoveryView: View {
    @ObservedObject var viewModel: BundleStoreViewModel
    
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16, pinnedViews: [.sectionHeaders]) {
                // 推荐区域
                if !viewModel.recommendedBundles.isEmpty {
                    RecommendedSection(
                        bundles: viewModel.recommendedBundles,
                        onSelect: { viewModel.selectBundle($0) }
                    )
                }
                
                // 分类浏览
                ForEach(viewModel.categories) { category in
                    CategorySection(
                        category: category,
                        onSelect: { viewModel.selectBundle($0) }
                    )
                }
                
                // 全部 Bundles
                Section {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 300))],
                        spacing: 16
                    ) {
                        ForEach(viewModel.filteredBundles) { bundle in
                            BundleCard(
                                bundle: bundle,
                                installStatus: viewModel.installStatus(for: bundle),
                                isInstalled: viewModel.isInstalled(bundle),
                                onInstall: {
                                    Task {
                                        await viewModel.installBundle(bundle)
                                    }
                                },
                                onSelect: {
                                    viewModel.selectBundle(bundle)
                                }
                            )
                        }
                    }
                    .padding()
                } header: {
                    HStack {
                        Text("全部 Bundles")
                            .font(.headline)
                        Spacer()
                    }
                    .padding()
                    .background(Color(NSColor.controlBackgroundColor))
                }
            }
        }
    }
}

// MARK: - 已安装视图

struct InstalledBundlesView: View {
    @ObservedObject var viewModel: BundleStoreViewModel
    
    var body: some View {
        List {
            if viewModel.installedBundles.isEmpty {
                Section {
                    EmptyStateView(
                        icon: "cube.box",
                        title: "还没有安装 Bundle",
                        subtitle: "去商店发现适合你的 Bundles",
                        actionTitle: "去商店看看",
                        action: {
                            // 切换到发现页
                        }
                    )
                }
            } else {
                Section("已启用") {
                    ForEach(viewModel.installedBundles.filter { $0.isEnabled }) { bundle in
                        InstalledBundleRow(
                            bundle: bundle,
                            onToggle: {
                                Task {
                                    await viewModel.toggleBundle(bundle)
                                }
                            },
                            onUpdate: {
                                Task {
                                    await viewModel.updateBundle(bundle)
                                }
                            },
                            onUninstall: {
                                Task {
                                    await viewModel.uninstallBundle(bundle)
                                }
                            }
                        )
                    }
                }
                
                Section("已禁用") {
                    ForEach(viewModel.installedBundles.filter { !$0.isEnabled }) { bundle in
                        InstalledBundleRow(
                            bundle: bundle,
                            onToggle: {
                                Task {
                                    await viewModel.toggleBundle(bundle)
                                }
                            },
                            onUpdate: nil,
                            onUninstall: {
                                Task {
                                    await viewModel.uninstallBundle(bundle)
                                }
                            }
                        )
                    }
                }
            }
        }
    }
}

// MARK: - 推荐区域

struct RecommendedSection: View {
    let bundles: [BundleMetadata]
    let onSelect: (BundleMetadata) -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("为你推荐", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(bundles) { bundle in
                        RecommendedBundleCard(
                            bundle: bundle,
                            onTap: { onSelect(bundle) }
                        )
                    }
                }
                .padding(.horizontal)
            }
        }
        .padding(.vertical, 8)
    }
}

// MARK: - 分类区域

struct CategorySection: View {
    let category: BundleMarketplaceCategory
    let onSelect: (BundleMetadata) -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(category.name, systemImage: category.icon)
                    .font(.headline)
                Spacer()
                Button("查看全部") {
                    // 查看更多
                }
                .font(.caption)
            }
            .padding(.horizontal)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(category.bundles) { bundle in
                        CompactBundleCard(
                            bundle: bundle,
                            onTap: { onSelect(bundle) }
                        )
                    }
                }
                .padding(.horizontal)
            }
        }
        .padding(.vertical, 8)
    }
}

// MARK: - 辅助视图

struct SearchBar: View {
    @Binding var text: String
    let placeholder: String
    
    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
            
            if !text.isEmpty {
                Button(action: { text = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
}

struct BundleTypeFilter: View {
    @Binding var selectedType: BundleType?
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(
                    title: "全部",
                    isSelected: selectedType == nil
                ) {
                    selectedType = nil
                }
                
                ForEach(BundleType.allCases) { type in
                    FilterChip(
                        title: type.displayName,
                        isSelected: selectedType == type
                    ) {
                        selectedType = type
                    }
                }
            }
            .padding(.horizontal)
        }
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

struct ErrorView: View {
    let message: String
    let retryAction: () -> Void
    
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundColor(.orange)
            
            Text(message)
                .multilineTextAlignment(.center)
            
            Button("重试", action: retryAction)
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

struct EmptyStateView: View {
    let icon: String
    let title: String
    let subtitle: String
    let actionTitle: String
    let action: () -> Void
    
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            
            Text(title)
                .font(.headline)
            
            Text(subtitle)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            Button(action: action) {
                Text(actionTitle)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 预览

#Preview("Bundle Store") {
    NavigationView {
        BundleStoreView()
    }
    .frame(width: 800, height: 600)
}
