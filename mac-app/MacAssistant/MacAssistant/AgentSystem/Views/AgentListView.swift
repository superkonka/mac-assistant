//
//  AgentListView.swift
//  MacAssistant
//
//  Agent 列表管理界面
//

import SwiftUI

struct AgentListView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var agentStore = AgentStore.shared
    @State private var showingWizard = false
    @State private var selectedGap: CapabilityGap?
    @State private var showingDeleteConfirm = false
    @State private var agentToDelete: Agent?
    
    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // 头部
                header
                
                Divider()
                
                // Agent 列表
                List {
                    Section(header: Text("当前可用 Agents").font(.caption)) {
                        ForEach(agentStore.agents) { agent in
                            AgentRow(agent: agent) {
                                agentStore.setDefaultAgent(agent)
                            } onEdit: {
                                // TODO: 显示编辑界面
                            } onDelete: {
                                agentToDelete = agent
                                showingDeleteConfirm = true
                            }
                        }
                    }
                    
                    Section(header: Text("可用能力").font(.caption)) {
                        FlowLayout(spacing: 8) {
                            ForEach(agentStore.allCapabilities, id: \.self) { capability in
                                AgentCapabilityBadge(capability: capability)
                            }
                        }
                    }
                }
                .listStyle(InsetListStyle())
                
                // 底部关闭按钮区域（占位）
                Spacer(minLength: 60)
            }
            
            // 悬浮关闭按钮（底部正中间）
            VStack {
                Spacer()
                
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)
                        .background(
                            Circle()
                                .fill(Color(NSColor.windowBackgroundColor))
                                .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
                        )
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.bottom, 20)
            }
        }
        .frame(width: 400, height: 520)
        .sheet(isPresented: $showingWizard) {
            AgentConfigurationWizard(gap: selectedGap) { newAgent in
                agentStore.switchToAgent(newAgent)
            }
        }
        .alert("确认删除", isPresented: $showingDeleteConfirm, presenting: agentToDelete) { agent in
            Button("删除", role: .destructive) {
                agentStore.deleteAgent(agent)
            }
            Button("取消", role: .cancel) {}
        } message: { agent in
            Text("确定要删除 Agent 「\(agent.name)」吗？此操作不可撤销。")
        }
    }
    
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Agent 管理")
                    .font(.system(size: 16, weight: .semibold))
                Text("\(agentStore.agents.count) 个 Agents，\(agentStore.allCapabilities.count) 种能力")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button(action: { showingWizard = true }) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 28, height: 28)
                    .background(Color.blue)
                    .cornerRadius(6)
            }
            .buttonStyle(PlainButtonStyle())
            .help("添加新 Agent")
        }
        .padding()
    }
}

// MARK: - Agent 行

struct AgentRow: View {
    let agent: Agent
    let onSetDefault: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            // Emoji
            Text(agent.emoji)
                .font(.title2)
            
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(agent.name)
                        .font(.system(size: 13, weight: .medium))
                    
                    if agent.isDefault {
                        Text("默认")
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.15))
                            .foregroundColor(.blue)
                            .cornerRadius(4)
                    }
                    
                    if agent.isActive {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                    }
                }
                
                Text(agent.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                
                HStack(spacing: 4) {
                    Text(agent.provider.displayName)
                        .font(.caption2)
                        .foregroundColor(.blue)
                    
                    Text("•")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    
                    Text(agent.model)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                // 能力标签
                HStack(spacing: 4) {
                    ForEach(agent.capabilities.prefix(3), id: \.self) { cap in
                        Image(systemName: cap.icon)
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                    }
                    if agent.capabilities.count > 3 {
                        Text("+\(agent.capabilities.count - 3)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Spacer()
            
            // 操作按钮
            HStack(spacing: 8) {
                if !agent.isDefault {
                    Button("设为默认") {
                        onSetDefault()
                    }
                    .font(.caption)
                    .buttonStyle(LinkButtonStyle())
                }
                
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.system(size: 12))
                        .foregroundColor(.blue.opacity(0.7))
                }
                .buttonStyle(PlainButtonStyle())
                .help("编辑 Agent")
                
                if !agent.isDefault {
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundColor(.red.opacity(0.7))
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 能力徽章

struct AgentCapabilityBadge: View {
    let capability: Capability
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: capability.icon)
                .font(.system(size: 10))
            Text(capability.displayName)
                .font(.system(size: 11))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.gray.opacity(0.1))
        .foregroundColor(.secondary)
        .cornerRadius(4)
    }
}

// MARK: - FlowLayout

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

// MARK: - 自检和引导视图

struct CapabilityDiscoveryView: View {
    let gap: CapabilityGap
    @Binding var isPresented: Bool
    let onConfigure: () -> Void
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lightbulb.fill")
                .font(.system(size: 48))
                .foregroundColor(.yellow)
            
            Text("发现新需求")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("您需要 \(gap.missingCapability.displayName) 能力")
                .font(.headline)
            
            Text(gap.solutionDescription)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            Divider()
            
            Text("推荐解决方案:")
                .font(.caption)
                .foregroundColor(.secondary)
            
            ForEach(gap.suggestedAgents.prefix(2), id: \.name) { suggestion in
                HStack {
                    Text(suggestion.emoji)
                        .font(.title2)
                    VStack(alignment: .leading) {
                        Text(suggestion.name)
                            .font(.system(size: 13, weight: .medium))
                        Text(suggestion.description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(8)
            }
            
            HStack(spacing: 12) {
                Button("暂时跳过") {
                    isPresented = false
                }
                .buttonStyle(SecondaryButtonStyle())
                
                Button("立即配置") {
                    onConfigure()
                    isPresented = false
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(24)
        .frame(width: 400)
    }
}
