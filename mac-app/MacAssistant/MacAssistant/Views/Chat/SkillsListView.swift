//
//  SkillsListView.swift
//  MacAssistant
//
//  Skills 列表面板 - 简化版（OpenClaw 已移除）
//

import SwiftUI

struct SkillsListView: View {
    @StateObject private var marketplace = ClawHubMarketplaceService.shared
    @State private var selectedTab = 0
    
    var body: some View {
        VStack(spacing: 0) {
            // 标签栏
            Picker("", selection: $selectedTab) {
                Text("已安装").tag(0)
                Text("市场").tag(1)
            }
            .pickerStyle(.segmented)
            .padding()
            
            // 内容区
            if selectedTab == 0 {
                installedSkillsView
            } else {
                marketplaceView
            }
        }
        .frame(width: 760, height: 540)
    }
    
    private var installedSkillsView: some View {
        VStack {
            if marketplace.installedSkills.isEmpty {
                ContentUnavailableView(
                    "没有已安装的 Skills",
                    systemImage: "puzzlepiece",
                    description: Text("原生运行时无需外部 Skills")
                )
            } else {
                List(marketplace.installedSkills) { skill in
                    HStack {
                        Text(skill.name)
                        Spacer()
                        Text("就绪")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }
    
    private var marketplaceView: some View {
        ContentUnavailableView(
            "Skill 市场已关闭",
            systemImage: "store.slash",
            description: Text("原生 MacAutoAgent 架构不再需要外部 Skill 市场")
        )
    }
}

// 兼容旧视图
struct SkillDetailSheet: View {
    let skill: ClawHubMarketplaceService.SkillItem
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack {
            Text(skill.name)
                .font(.title)
            Button("关闭") { dismiss() }
        }
        .padding()
    }
}

// 兼容类型
enum SkillCatalogFilter: String, CaseIterable {
    case all = "全部"
    case installed = "已安装"
    case available = "可安装"
}
