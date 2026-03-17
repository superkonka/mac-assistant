//
//  ExtensionManagerView.swift
//  MacAssistant
//
//  扩展管理界面 - 统一管理 Skills 和 Agents
//

import SwiftUI

struct ExtensionManagerView: View {
    @StateObject private var skillManager = SkillExtensionManager.shared
    @StateObject private var templateManager = AgentTemplateManager.shared
    
    @State private var selectedTab: Tab = .skills
    @State private var showCreateAgent = false
    @State private var showInstallSkill = false
    
    enum Tab {
        case skills, agents, market
    }
    
    var body: some View {
        NavigationView {
            sidebar
            
            mainContent
        }
        .frame(minWidth: 800, minHeight: 600)
    }
    
    // MARK: - Sidebar
    
    private var sidebar: some View {
        List(selection: Binding(
            get: { selectedTab },
            set: { selectedTab = $0 }
        )) {
            Section("已安装") {
                NavigationLink(destination: SkillsListView(), tag: Tab.skills, selection: $selectedTab) {
                    Label("Skills (\(skillManager.installedSkills.count))", systemImage: "wand.and.stars")
                }
                
                NavigationLink(destination: AgentsListView(), tag: Tab.agents, selection: $selectedTab) {
                    Label("Agents", systemImage: "person.2")
                }
            }
            
            Section("发现") {
                NavigationLink(destination: ExtensionMarketView(), tag: Tab.market, selection: $selectedTab) {
                    Label("市场", systemImage: "bag")
                }
            }
        }
        .listStyle(SidebarListStyle())
        .frame(minWidth: 200)
    }
    
    // MARK: - Main Content
    
    @ViewBuilder
    private var mainContent: some View {
        switch selectedTab {
        case .skills:
            SkillsListView()
        case .agents:
            AgentsListView()
        case .market:
            ExtensionMarketView()
        }
    }
}

// MARK: - Skills 列表

struct SkillsListView: View {
    @StateObject private var manager = SkillExtensionManager.shared
    @State private var selectedSkill: SkillManifest?
    @State private var searchText = ""
    
    var body: some View {
        VStack(spacing: 0) {
            // 工具栏
            HStack {
                TextField("搜索 Skills...", text: $searchText)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .frame(width: 200)
                
                Spacer()
                
                Button(action: { /* 安装新 Skill */ }) {
                    Label("安装", systemImage: "plus")
                }
                .buttonStyle(BorderlessButtonStyle())
            }
            .padding()
            
            // 列表
            List(selection: $selectedSkill) {
                ForEach(filteredSkills, id: \.id) { skill in
                    SkillRow(manifest: skill)
                        .tag(skill)
                        .contextMenu {
                            Button("配置") { /* 配置 */ }
                            Button("禁用") { /* 禁用 */ }
                            Divider()
                            Button("卸载", role: .destructive) { /* 卸载 */ }
                        }
                }
            }
            .listStyle(InsetListStyle())
            
            // 详情面板
            if let skill = selectedSkill {
                SkillDetailPanel(manifest: skill)
                    .frame(height: 200)
            }
        }
    }
    
    private var filteredSkills: [SkillManifest] {
        if searchText.isEmpty {
            return manager.installedSkills
        }
        return manager.installedSkills.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.description.localizedCaseInsensitiveContains(searchText)
        }
    }
}

struct SkillRow: View {
    let manifest: SkillManifest
    
    var body: some View {
        HStack {
            Image(systemName: manifest.icon)
                .font(.title2)
                .frame(width: 40)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(manifest.name)
                    .font(.headline)
                Text(manifest.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            
            Spacer()
            
            ExecutionModeBadge(mode: manifest.executionMode)
        }
        .padding(.vertical, 4)
    }
}

struct ExecutionModeBadge: View {
    let mode: SkillManifest.ExecutionMode
    
    var body: some View {
        Text(mode.label)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(mode.color.opacity(0.2))
            .foregroundColor(mode.color)
            .cornerRadius(4)
    }
}

extension SkillManifest.ExecutionMode {
    var label: String {
        switch self {
        case .localScript: return "本地脚本"
        case .remoteAPI: return "远程 API"
        case .mcpTool: return "MCP"
        case .agentDelegation: return "Agent"
        case .builtin: return "内置"
        }
    }
    
    var color: Color {
        switch self {
        case .localScript: return .blue
        case .remoteAPI: return .green
        case .mcpTool: return .purple
        case .agentDelegation: return .orange
        case .builtin: return .gray
        }
    }
}

struct SkillDetailPanel: View {
    let manifest: SkillManifest
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: manifest.icon)
                    .font(.largeTitle)
                
                VStack(alignment: .leading) {
                    Text(manifest.name)
                        .font(.title2)
                    Text("v\(manifest.version) · \(manifest.author)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Divider()
            
            Text(manifest.description)
                .font(.body)
            
            HStack {
                CategoryBadge(category: manifest.category)
                ExecutionModeBadge(mode: manifest.executionMode)
            }
            
            Spacer()
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }
}

// MARK: - Agents 列表

struct AgentsListView: View {
    @StateObject private var templateManager = AgentTemplateManager.shared
    @State private var selectedCategory: AgentTemplate.AgentCategory?
    @State private var showCreateSheet = false
    
    var body: some View {
        VStack(spacing: 0) {
            // 工具栏
            HStack {
                Text("Agent 模板")
                    .font(.headline)
                
                Spacer()
                
                Button(action: { showCreateSheet = true }) {
                    Label("新建 Agent", systemImage: "plus")
                }
                .buttonStyle(BorderlessButtonStyle())
            }
            .padding()
            
            // 分类筛选
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    CategoryButton(
                        title: "全部",
                        isSelected: selectedCategory == nil,
                        action: { selectedCategory = nil }
                    )
                    
                    ForEach(AgentTemplate.AgentCategory.allCases, id: \.self) { category in
                        CategoryButton(
                            title: category.rawValue,
                            isSelected: selectedCategory == category,
                            action: { selectedCategory = category }
                        )
                    }
                }
                .padding(.horizontal)
            }
            .padding(.vertical, 8)
            
            // 模板网格
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280))], spacing: 16) {
                    ForEach(filteredTemplates, id: \.id) { template in
                        AgentTemplateCard(template: template)
                    }
                }
                .padding()
            }
        }
        .sheet(isPresented: $showCreateSheet) {
            AgentCreationWizard()
        }
    }
    
    private var filteredTemplates: [AgentTemplate] {
        if let category = selectedCategory {
            return templateManager.templates(in: category)
        }
        return templateManager.templates
    }
}

struct CategoryButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .fontWeight(isSelected ? .semibold : .regular)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.blue : Color.gray.opacity(0.2))
                .foregroundColor(isSelected ? .white : .primary)
                .cornerRadius(16)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct AgentTemplateCard: View {
    let template: AgentTemplate
    @State private var isHovering = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(template.emoji)
                    .font(.title)
                
                Spacer()
                
                CategoryBadge(category: template.category)
            }
            
            Text(template.name)
                .font(.headline)
            
            Text(template.description)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)
            
            Divider()
            
            HStack {
                // 推荐模型
                HStack(spacing: 4) {
                    ForEach(template.recommendedModels.prefix(2), id: \.self) { model in
                        Text(model)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.gray.opacity(0.1))
                            .cornerRadius(4)
                    }
                }
                
                Spacer()
                
                Button("使用模板") {
                    // 打开创建向导
                }
                .buttonStyle(BorderlessButtonStyle())
                .foregroundColor(.blue)
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isHovering ? Color.blue.opacity(0.3) : Color.clear, lineWidth: 2)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovering = hovering
            }
        }
    }
}

struct CategoryBadge: View {
    let category: AgentTemplate.AgentCategory
    
    var body: some View {
        Text(category.rawValue)
            .font(.caption2)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(category.color.opacity(0.15))
            .foregroundColor(category.color)
            .cornerRadius(4)
    }
}

extension AgentTemplate.AgentCategory {
    var color: Color {
        switch self {
        case .programming: return .blue
        case .writing: return .green
        case .analysis: return .purple
        case .creative: return .pink
        case .business: return .orange
        case .system: return .gray
        case .custom: return .indigo
        }
    }
}

// MARK: - 扩展市场

struct ExtensionMarketView: View {
    @State private var searchText = ""
    @State private var selectedType: ExtensionType = .all
    
    enum ExtensionType: String, CaseIterable {
        case all = "全部"
        case skills = "Skills"
        case agents = "Agents"
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 搜索栏
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                
                TextField("搜索扩展...", text: $searchText)
                    .textFieldStyle(PlainTextFieldStyle())
                
                Picker("", selection: $selectedType) {
                    ForEach(ExtensionType.allCases, id: \.self) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
                .frame(width: 200)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            
            // 内容区域
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // 推荐扩展
                    SectionHeader(title: "推荐", icon: "star.fill")
                    
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300))], spacing: 16) {
                        ForEach(0..<3) { _ in
                            MarketItemCard()
                        }
                    }
                    
                    // 热门分类
                    SectionHeader(title: "热门分类", icon: "flame.fill")
                    
                    HStack(spacing: 12) {
                        ForEach(["开发工具", "生产力", "系统", "AI 助手"], id: \.self) { category in
                            CategoryCard(name: category)
                        }
                    }
                    
                    // 最新上架
                    SectionHeader(title: "最新上架", icon: "clock.fill")
                    
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300))], spacing: 16) {
                        ForEach(0..<4) { _ in
                            MarketItemCard()
                        }
                    }
                }
                .padding()
            }
        }
    }
}

struct SectionHeader: View {
    let title: String
    let icon: String
    
    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(.blue)
            Text(title)
                .font(.headline)
            Spacer()
        }
    }
}

struct MarketItemCard: View {
    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.2))
                .frame(width: 60, height: 60)
                .overlay(
                    Image(systemName: "puzzlepiece")
                        .font(.title2)
                        .foregroundColor(.secondary)
                )
            
            VStack(alignment: .leading, spacing: 4) {
                Text("示例扩展")
                    .font(.headline)
                Text("这是一个示例扩展描述")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                
                HStack {
                    Label("4.8", systemImage: "star.fill")
                        .font(.caption2)
                    Text("·")
                    Text("1.2k 下载")
                        .font(.caption2)
                }
                .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button("安装") {}
                .buttonStyle(BorderlessButtonStyle())
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
}

struct CategoryCard: View {
    let name: String
    
    var body: some View {
        Button(action: {}) {
            VStack {
                Image(systemName: "folder")
                    .font(.title2)
                Text(name)
                    .font(.caption)
            }
            .frame(width: 80, height: 80)
            .background(Color.gray.opacity(0.1))
            .cornerRadius(8)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - 创建向导

struct AgentCreationWizard: View {
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            Text("Agent 创建向导")
                .navigationTitle("新建 Agent")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }
                    }
                }
        }
        .frame(minWidth: 600, minHeight: 400)
    }
}
