//
//  SkillsManagementView.swift
//  MacAssistant
//
//  Skills 管理中心 - 统一技能管理面板
//

import SwiftUI

struct SkillsManagementView: View {
    @StateObject private var skillCatalog = SkillCatalog.shared
    @State private var searchText = ""
    @State private var showingDeleteConfirm = false
    @State private var skillToDelete: SkillManifest?
    
    var filteredSkills: [SkillManifest] {
        if searchText.isEmpty {
            return skillCatalog.skills.sorted { $0.name < $1.name }
        }
        return skillCatalog.skills.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.description.localizedCaseInsensitiveContains(searchText) ||
            $0.tags.contains(where: { $0.localizedCaseInsensitiveContains(searchText) })
        }.sorted { $0.name < $1.name }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text("Skills 管理")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Spacer()
                
                // 统计信息
                let stats = skillCatalog.statistics()
                Text("\(stats.enabled)/\(stats.total) 已启用")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                // 搜索框
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
            
            Divider()
            
            // Skills 列表
            if filteredSkills.isEmpty {
                ContentUnavailableView(
                    "未找到 Skills",
                    systemImage: "magnifyingglass",
                    description: Text(searchText.isEmpty ? "暂无 Skills" : "尝试其他关键词")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280))], spacing: 12) {
                        ForEach(filteredSkills) { skill in
                            SkillCard(
                                skill: skill,
                                isEnabled: skillCatalog.isEnabled(id: skill.id),
                                onToggle: { enabled in
                                    skillCatalog.setEnabled(id: skill.id, enabled: enabled)
                                },
                                onDelete: {
                                    skillToDelete = skill
                                    showingDeleteConfirm = true
                                }
                            )
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(width: 700, height: 500)
        .alert("确认卸载", isPresented: $showingDeleteConfirm, presenting: skillToDelete) { skill in
            Button("卸载", role: .destructive) {
                do {
                    try skillCatalog.uninstallSkill(id: skill.id)
                } catch {
                    LogError("卸载失败: \(error)")
                }
            }
            Button("取消", role: .cancel) {}
        } message: { skill in
            Text("确定要卸载「\(skill.name)」吗？此操作不可撤销。")
        }
    }
}

// MARK: - Skill 卡片

struct SkillCard: View {
    let skill: SkillManifest
    let isEnabled: Bool
    let onToggle: (Bool) -> Void
    let onDelete: () -> Void
    
    @State private var showingEditSheet = false
    @State private var showingResetConfirm = false
    
    private var hasUserOverride: Bool {
        SkillCatalog.shared.hasOverride(for: skill.id)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 头部
            HStack(spacing: 12) {
                // 图标
                Image(systemName: iconForSkill(skill))
                    .font(.system(size: 24))
                    .foregroundColor(colorForSkill(skill))
                    .frame(width: 40, height: 40)
                    .background(colorForSkill(skill).opacity(0.1))
                    .cornerRadius(8)
                
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(skill.name)
                            .font(.system(size: 14, weight: .semibold))
                        
                        if skill.isBuiltIn {
                            Text("内置")
                                .font(.system(size: 9))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.blue.opacity(0.15))
                                .foregroundColor(.blue)
                                .cornerRadius(3)
                        }
                    }
                    
                    Text(skill.id)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // 开关
                Toggle("", isOn: Binding(
                    get: { isEnabled },
                    set: { onToggle($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)
            
            // 描述
            Text(skill.description)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(2)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            
            // 标签
            HStack(spacing: 4) {
                ForEach(skill.tags.prefix(3), id: \.self) { tag in
                    Text(tag)
                        .font(.system(size: 9))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.gray.opacity(0.1))
                        .foregroundColor(.secondary)
                        .cornerRadius(3)
                }
                
                Spacer()
                
                // 执行器类型标签
                Text(executorTypeLabel(skill.executorType))
                    .font(.system(size: 9))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(executorTypeColor(skill.executorType).opacity(0.1))
                    .foregroundColor(executorTypeColor(skill.executorType))
                    .cornerRadius(3)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            
            Divider()
            
            // 底部操作
            HStack(spacing: 8) {
                // 状态
                HStack(spacing: 4) {
                    Circle()
                        .fill(isEnabled ? Color.green : Color.gray)
                        .frame(width: 6, height: 6)
                    Text(isEnabled ? "已启用" : "已禁用")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // 内置 Skill 的编辑按钮
                if skill.isBuiltIn {
                    // 重置按钮（如果有用户覆盖）
                    if hasUserOverride {
                        Button(action: { showingResetConfirm = true }) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 11))
                            Text("重置")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.orange)
                        .help("恢复到默认版本")
                    }
                    
                    // 编辑按钮
                    Button(action: { showingEditSheet = true }) {
                        Image(systemName: "pencil")
                            .font(.system(size: 11))
                        Text(hasUserOverride ? "已修改" : "编辑")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(hasUserOverride ? .green : .blue)
                    .help("编辑 Skill 配置")
                }
                
                // 卸载按钮（仅非内置）
                if !skill.isBuiltIn {
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                        Text("卸载")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.red)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
        }
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isEnabled ? Color.clear : Color.gray.opacity(0.2), lineWidth: 1)
        )
        .opacity(isEnabled ? 1.0 : 0.7)
        .sheet(isPresented: $showingEditSheet) {
            SkillEditSheet(skill: skill, onSave: { updatedSkill in
                do {
                    try SkillCatalog.shared.saveSkillOverride(updatedSkill)
                } catch {
                    LogError("保存 Skill 覆盖失败: \(error)")
                }
            })
        }
        .alert("确认重置", isPresented: $showingResetConfirm) {
            Button("重置", role: .destructive) {
                do {
                    try SkillCatalog.shared.resetSkillToDefault(id: skill.id)
                } catch {
                    LogError("重置 Skill 失败: \(error)")
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("确定要重置「\(skill.name)」到默认版本吗？您的自定义修改将被删除。")
        }
    }
    
    private func iconForSkill(_ skill: SkillManifest) -> String {
        // 根据 domain 返回图标
        let domain = skill.capabilities.first?.domain ?? ""
        switch domain {
        case "system":
            if skill.id.contains("screenshot") { return "camera" }
            if skill.id.contains("clipboard") { return "doc.on.clipboard" }
            if skill.id.contains("notification") { return "bell" }
            if skill.id.contains("volume") { return "speaker.wave.2" }
            if skill.id.contains("search") { return "magnifyingglass" }
            return "gearshape"
        case "development":
            if skill.id.contains("git") { return "git.branch" }
            if skill.id.contains("port") { return "network" }
            return "hammer"
        default:
            return "puzzlepiece"
        }
    }
    
    private func colorForSkill(_ skill: SkillManifest) -> Color {
        let domain = skill.capabilities.first?.domain ?? ""
        switch domain {
        case "system": return .blue
        case "development": return .orange
        case "communication": return .green
        case "browser": return .purple
        default: return .gray
        }
    }
    
    private func executorTypeLabel(_ type: SkillExecutorType) -> String {
        switch type {
        case .local: return "本地"
        case .javascript: return "脚本"
        case .remote: return "远程"
        case .agent: return "Agent"
        case .browser: return "浏览器"
        case .mcp: return "MCP"
        }
    }
    
    private func executorTypeColor(_ type: SkillExecutorType) -> Color {
        switch type {
        case .local: return .blue
        case .javascript: return .yellow
        case .remote: return .purple
        case .agent: return .green
        case .browser: return .orange
        case .mcp: return .pink
        }
    }
}

// MARK: - 内置技能卡片（旧版兼容）

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

// MARK: - Skill 编辑表单

struct SkillEditSheet: View {
    let skill: SkillManifest
    let onSave: (SkillManifest) -> Void
    
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var description: String
    @State private var command: String
    @State private var showingDiscardConfirm = false
    
    init(skill: SkillManifest, onSave: @escaping (SkillManifest) -> Void) {
        self.skill = skill
        self.onSave = onSave
        _name = State(initialValue: skill.name)
        _description = State(initialValue: skill.description)
        _command = State(initialValue: skill.executorConfig["command"] ?? "")
    }
    
    var hasChanges: Bool {
        name != skill.name ||
        description != skill.description ||
        command != (skill.executorConfig["command"] ?? "")
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text("编辑 Skill")
                    .font(.headline)
                
                Spacer()
                
                Text(skill.id)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            
            Divider()
            
            // 表单
            Form {
                Section("基本信息") {
                    TextField("名称", text: $name)
                    TextField("描述", text: $description, axis: .vertical)
                        .lineLimit(2...4)
                }
                
                Section("执行配置") {
                    if skill.executorType == .local {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Shell 命令")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            TextEditor(text: $command)
                                .font(.system(.body, design: .monospaced))
                                .frame(height: 80)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(Color.gray.opacity(0.2))
                                )
                            
                            Text("支持变量: {{参数名}} 将被替换为实际值")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Text("此类型 Skill 暂不支持编辑执行配置")
                            .foregroundColor(.secondary)
                    }
                }
                
                Section("参数定义") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(skill.inputSchema.parameters, id: \.name) { param in
                            HStack {
                                Text(param.name)
                                    .font(.system(.body, weight: .medium))
                                Spacer()
                                Text(param.type.rawValue)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                if skill.inputSchema.required.contains(param.name) {
                                    Text("必填")
                                        .font(.caption2)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Color.red.opacity(0.1))
                                        .foregroundColor(.red)
                                        .cornerRadius(2)
                                }
                            }
                            Text(param.description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minHeight: 300)
            
            Divider()
            
            // 底部按钮
            HStack {
                Button("取消") {
                    if hasChanges {
                        showingDiscardConfirm = true
                    } else {
                        dismiss()
                    }
                }
                
                Spacer()
                
                Button("保存") {
                    saveSkill()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasChanges || name.isEmpty)
            }
            .padding()
        }
        .frame(width: 500, height: 500)
        .alert("确认放弃", isPresented: $showingDiscardConfirm) {
            Button("放弃修改", role: .destructive) {
                dismiss()
            }
            Button("继续编辑", role: .cancel) {}
        } message: {
            Text("您有未保存的修改，确定要放弃吗？")
        }
    }
    
    private func saveSkill() {
        var newConfig = skill.executorConfig
        if skill.executorType == .local {
            newConfig["command"] = command
        }
        
        let updatedSkill = skill.copyWith(
            name: name,
            description: description,
            executorConfig: newConfig,
            hasUserOverride: true
        )
        
        onSave(updatedSkill)
        dismiss()
    }
}
