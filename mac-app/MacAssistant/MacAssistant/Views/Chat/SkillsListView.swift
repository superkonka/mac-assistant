//
//  SkillsListView.swift
//  MacAssistant
//
//  Skills 列表面板 - 已迁移到 SkillsManagementView
//

import SwiftUI

/// Skills 列表面板 - 兼容旧接口，实际使用 SkillsManagementView
struct SkillsListView: View {
    var body: some View {
        SkillsManagementView()
    }
}

// 兼容旧类型定义
enum SkillCatalogFilter: String, CaseIterable {
    case all = "全部"
    case installed = "已安装"
    case available = "可安装"
}

// 兼容旧视图 - 不再使用 ClawHub
struct SkillDetailSheet: View {
    let skill: Any
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack {
            Text("Skill 详情")
                .font(.title)
            Text("已迁移到新的 Skills 管理系统")
                .foregroundColor(.secondary)
            Button("关闭") { dismiss() }
                .padding()
        }
        .padding()
        .frame(width: 400, height: 300)
    }
}
