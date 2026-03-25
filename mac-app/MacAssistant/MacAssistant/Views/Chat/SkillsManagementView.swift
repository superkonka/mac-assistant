//
//  SkillsManagementView.swift
//  MacAssistant
//
//  Skills 管理中心 - 统一技能管理面板
//

import SwiftUI

struct SkillsManagementView: View {
    @StateObject private var skillCatalog = SkillCatalog.shared
    @StateObject private var skillSystem = SkillSystem.shared
    @State private var selectedTab = 0
    @State private var searchText = ""
    
    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text("Skills 管理")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Spacer()
                
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("搜索...", text: $searchText)
                        .textFieldStyle(.plain)
                        .frame(width: 150)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(8)
            }
            .padding()
            
            // 标签栏
            Picker("", selection: $selectedTab) {
                Text("内置 Skills").tag(0)
                Text("自定义").tag(1)
                Text("目录").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            
            // 内容
            Group {
                switch selectedTab {
                case 0: builtinSkillsView
                case 1: customSkillsView
                case 2: catalogView
                default: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 700, height: 500)
    }
    
    private var builtinSkillsView: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250))], spacing: 16) {
                ForEach(AISkill.allCases) { skill in
                    BuiltinSkillCard(skill: skill)
                }
            }
            .padding()
        }
    }
    
    private var customSkillsView: some View {
        VStack {
            if skillSystem.skills.isEmpty {
                ContentUnavailableView(
                    "暂无自定义 Skills",
                    systemImage: "wrench",
                    description: Text("创建可进化的命令技能")
                )
            } else {
                List(skillSystem.skills) { skill in
                    Text(skill.name)
                }
            }
        }
    }
    
    private var catalogView: some View {
        List(skillCatalog.skills, id: \.id) { skill in
            VStack(alignment: .leading) {
                Text(skill.name)
                    .font(.headline)
                Text(skill.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

struct BuiltinSkillCard: View {
    let skill: AISkill
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(skill.emoji)
                    .font(.title2)
                Spacer()
                Text("就绪")
                    .font(.caption)
                    .foregroundColor(.green)
            }
            
            Text(skill.name)
                .font(.headline)
            
            Text(skill.description)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
    }
}
