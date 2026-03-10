//
//  SkillsListView.swift
//  MacAssistant
//
//  技能列表展示视图
//

import SwiftUI

struct SkillsListView: View {
    @ObservedObject var registry = AISkillRegistry.shared
    @ObservedObject var orchestrator = AgentOrchestrator.shared
    
    @State private var selectedCategory: SkillCategory? = nil
    @State private var searchText: String = ""
    @State private var hoveredSkill: AISkill? = nil
    
    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            header
            
            Divider()
            
            // 分类标签
            categoryTabs
            
            Divider()
            
            // 技能网格
            skillsGrid
        }
        .frame(width: 500, height: 400)
        .background(Color(NSColor.controlBackgroundColor))
    }
    
    // MARK: - 子视图
    
    private var header: some View {
        HStack {
            Text("✨ Skills")
                .font(.system(size: 16, weight: .semibold))
            
            Spacer()
            
            // 搜索框
            HStack {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                
                TextField("搜索技能...", text: $searchText)
                    .textFieldStyle(PlainTextFieldStyle())
                    .font(.system(size: 13))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(NSColor.textBackgroundColor))
            .cornerRadius(6)
            .frame(width: 180)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
    
    private var categoryTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // 全部
                CategoryTab(
                    title: "全部",
                    icon: "square.grid.2x2",
                    isSelected: selectedCategory == nil,
                    count: registry.skills.count
                ) {
                    selectedCategory = nil
                }
                
                // 各分类
                ForEach(SkillCategory.allCases, id: \.self) { category in
                    CategoryTab(
                        title: category.rawValue,
                        icon: category.icon,
                        isSelected: selectedCategory == category,
                        count: registry.skills(in: category).count
                    ) {
                        selectedCategory = category
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }
    
    private var skillsGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: 140, maximum: 160), spacing: 12)
                ],
                spacing: 12
            ) {
                ForEach(filteredSkills) { skill in
                    AISkillCard(
                        skill: skill,
                        isAvailable: registry.isAvailable(skill),
                        isHovered: hoveredSkill == skill
                    )
                    .onHover { isHovered in
                        hoveredSkill = isHovered ? skill : nil
                    }
                    .onTapGesture {
                        executeSkill(skill)
                    }
                }
            }
            .padding(16)
        }
    }
    
    // MARK: - 过滤逻辑
    
    private var filteredSkills: [AISkill] {
        var skills = registry.skills
        
        // 按分类过滤
        if let category = selectedCategory {
            skills = registry.skills(in: category)
        }
        
        // 按搜索词过滤
        if !searchText.isEmpty {
            skills = skills.filter {
                $0.name.contains(searchText) ||
                $0.description.contains(searchText)
            }
        }
        
        return skills
    }
    
    // MARK: - 执行技能
    
    private func executeSkill(_ skill: AISkill) {
        let context = MacAssistant.SkillContext(
            currentAgent: orchestrator.currentAgent,
            runner: CommandRunner.shared
        )
        
        Task {
            let result = await registry.execute(skill, context: context)
            
            await MainActor.run {
                handleResult(result, for: skill)
            }
        }
    }
    
    private func handleResult(_ result: SkillResult, for skill: AISkill) {
        switch result {
        case .success(let message):
            print("✅ \(skill.name): \(message)")
            
        case .requiresInput(let prompt):
            // 在聊天中提示用户输入
            let message = MacAssistant.ChatMessage(
                id: UUID(),
                role: .assistant,
                content: "🎯 **\(skill.name)**\n\n\(prompt)",
                timestamp: Date()
            )
            CommandRunner.shared.messages.append(message)
            
        case .requiresAgentCreation(let gap):
            // 触发 Agent 创建流程
            NotificationCenter.default.post(
                name: NSNotification.Name("ShowCapabilityDiscovery"),
                object: gap
            )
            
        case .error(let message):
            print("❌ \(skill.name) 失败: \(message)")
        }
    }
}

// MARK: - 子组件

struct CategoryTab: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let count: Int
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                Text("\(count)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(8)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Color.blue.opacity(0.15) : Color.clear)
            .foregroundColor(isSelected ? .blue : .primary)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.blue.opacity(0.3) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct AISkillCard: View {
    let skill: AISkill
    let isAvailable: Bool
    let isHovered: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 顶部：图标和快捷方式
            HStack {
                Text(skill.emoji)
                    .font(.system(size: 28))
                
                Spacer()
                
                if let shortcut = skill.shortcut {
                    Text(shortcut)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(4)
                }
            }
            
            // 名称
            Text(skill.name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(isAvailable ? .primary : .secondary)
                .lineLimit(1)
            
            // 描述
            Text(skill.description)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            
            // 状态标签
            HStack {
                if !isAvailable {
                    HStack(spacing: 2) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 8))
                        Text("需创建 Agent")
                            .font(.system(size: 9))
                    }
                    .foregroundColor(.orange)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(4)
                }
                
                Spacer()
                
                // 分类标签
                HStack(spacing: 2) {
                    Image(systemName: skill.category.icon)
                        .font(.system(size: 8))
                    Text(skill.category.rawValue)
                        .font(.system(size: 9))
                }
                .foregroundColor(categoryColor)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(categoryColor.opacity(0.1))
                .cornerRadius(4)
            }
        }
        .padding(12)
        .frame(height: 120)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isHovered ? Color.blue.opacity(0.05) : Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    isHovered ? Color.blue.opacity(0.3) :
                    isAvailable ? Color.gray.opacity(0.2) : Color.orange.opacity(0.3),
                    lineWidth: isHovered ? 2 : 1
                )
        )
        .opacity(isAvailable ? 1.0 : 0.7)
    }
    
    private var categoryColor: Color {
        switch skill.category {
        case .productivity: return .yellow
        case .analysis: return .blue
        case .creation: return .purple
        case .system: return .gray
        case .agent: return .green
        }
    }
}

// MARK: - Preview

#Preview {
    SkillsListView()
}
