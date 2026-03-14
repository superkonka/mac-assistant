//
//  SkillBrowserView.swift
//  MacAssistant
//
//  轻量级 Skill 浏览器 - 基于新的 SkillRegistry
//

import SwiftUI

/// Skill 浏览器视图
struct SkillBrowserView: View {
    @StateObject private var registry = SkillRegistry.shared
    @State private var searchText = ""
    @State private var selectedCategory: CapabilityTag?
    @State private var selectedSkill: SkillManifest?
    
    private var filteredSkills: [SkillManifest] {
        var skills = registry.allSkills
        
        if let category = selectedCategory {
            skills = skills.filter { $0.requiredCapabilities.contains(category) }
        }
        
        if !searchText.isEmpty {
            skills = registry.search(query: searchText)
        }
        
        return skills
    }
    
    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            categoryFilter
            Divider()
            skillGrid
        }
        .frame(minWidth: 700, minHeight: 500)
        .background(Color(.windowBackgroundColor))
        .sheet(item: $selectedSkill) { skill in
            SkillDetailView(skill: skill)
        }
    }
    
    private var toolbar: some View {
        HStack(spacing: 16) {
            Text("Skills")
                .font(.system(size: 20, weight: .semibold))
            
            Text("\(registry.builtinSkills.count) 内置 · \(registry.installedSkills.count) 已安装")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Spacer()
            
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 13))
                TextField("搜索 Skills...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(.controlBackgroundColor))
            .cornerRadius(8)
            .frame(width: 200)
            
            Button {
                Task { await registry.syncFromOpenClaw() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.plain)
            .help("从 OpenClaw Core 同步")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
    
    private var categoryFilter: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                CategoryButton(
                    title: "全部",
                    icon: "square.grid.2x2",
                    isSelected: selectedCategory == nil
                ) { selectedCategory = nil }
                
                ForEach(CapabilityTag.allCases, id: \.self) { tag in
                    CategoryButton(
                        title: tag.displayName,
                        icon: tag.icon,
                        isSelected: selectedCategory == tag
                    ) { selectedCategory = tag }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }
    
    private var skillGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 280, maximum: 320), spacing: 16)],
                spacing: 16
            ) {
                ForEach(filteredSkills) { skill in
                    SkillCard(skill: skill) { selectedSkill = skill }
                }
            }
            .padding(20)
        }
    }
}

struct CategoryButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor : Color(.controlBackgroundColor))
            .foregroundColor(isSelected ? .white : .primary)
            .cornerRadius(16)
        }
        .buttonStyle(.plain)
    }
}

struct SkillCard: View {
    let skill: SkillManifest
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: skill.icon ?? "puzzlepiece.extension")
                        .font(.system(size: 24))
                        .foregroundColor(.accentColor)
                        .frame(width: 40, height: 40)
                        .background(Color.accentColor.opacity(0.1))
                        .cornerRadius(8)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(skill.name)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                        
                        HStack(spacing: 6) {
                            if skill.isBuiltin {
                                Label("内置", systemImage: "checkmark.shield")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Text(skill.version)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Spacer()
                }
                
                Text(skill.description)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                
                Spacer()
                
                HStack(spacing: 4) {
                    ForEach(skill.requiredCapabilities.prefix(3), id: \.self) { cap in
                        CapabilityBadge(tag: cap)
                    }
                }
            }
            .padding(16)
            .frame(height: 140)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.controlBackgroundColor))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.separator.opacity(0.5), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

struct CapabilityBadge: View {
    let tag: CapabilityTag
    
    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: tag.icon)
                .font(.system(size: 8))
            Text(tag.shortName)
                .font(.system(size: 10))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(tag.color.opacity(0.15))
        .foregroundColor(tag.color)
        .cornerRadius(4)
    }
}

struct SkillDetailView: View {
    let skill: SkillManifest
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(skill.name)
                        .font(.system(size: 18, weight: .semibold))
                    
                    HStack(spacing: 8) {
                        Text(skill.id)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("·")
                            .foregroundColor(.secondary)
                        Text("v\(skill.version)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.escape)
            }
            .padding(20)
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    InfoSection(title: "描述") {
                        Text(skill.description)
                            .font(.system(size: 13))
                    }
                    
                    InfoSection(title: "能力要求") {
                        FlowLayout(spacing: 8) {
                            ForEach(skill.requiredCapabilities, id: \.self) { cap in
                                CapabilityBadge(tag: cap)
                            }
                        }
                    }
                    
                    if !skill.parameters.isEmpty {
                        InfoSection(title: "参数") {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(skill.parameters.indices, id: \.self) { index in
                                    ParameterRow(param: skill.parameters[index])
                                }
                            }
                        }
                    }
                    
                    InfoSection(title: "信息") {
                        InfoRow(label: "来源", value: skill.installSource ?? "未知")
                        InfoRow(label: "内置", value: skill.isBuiltin ? "是" : "否")
                        if let author = skill.author {
                            InfoRow(label: "作者", value: author)
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 500, height: 400)
    }
}

struct InfoSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            content
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(width: 60, alignment: .leading)
            Text(value)
                .font(.system(size: 13))
            Spacer()
        }
    }
}

struct ParameterRow: View {
    let param: SkillManifest.ParameterSchema
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(param.name)
                    .font(.system(size: 13, weight: .medium))
                
                Text(param.type.rawValue)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(4)
                
                if param.required {
                    Text("必需")
                        .font(.caption2)
                        .foregroundColor(.red)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(4)
                }
            }
            
            Text(param.description)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(12)
        .background(Color(.controlBackgroundColor))
        .cornerRadius(8)
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(in: proposal.width ?? 0, subviews: subviews, spacing: spacing)
        return result.size
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.positions[index].x,
                                      y: bounds.minY + result.positions[index].y),
                         proposal: .unspecified)
        }
    }
    
    struct FlowResult {
        var size: CGSize = .zero
        var positions: [CGPoint] = []
        
        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var x: CGFloat = 0
            var y: CGFloat = 0
            var lineHeight: CGFloat = 0
            
            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                
                if x + size.width > maxWidth && x > 0 {
                    x = 0
                    y += lineHeight + spacing
                    lineHeight = 0
                }
                
                positions.append(CGPoint(x: x, y: y))
                lineHeight = max(lineHeight, size.height)
                x += size.width + spacing
                
                self.size.width = max(self.size.width, x)
            }
            
            self.size.height = y + lineHeight
        }
    }
}

#Preview {
    SkillBrowserView()
        .frame(width: 800, height: 600)
}
