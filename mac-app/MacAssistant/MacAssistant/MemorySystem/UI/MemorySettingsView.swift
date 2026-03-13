//
//  MemorySettingsView.swift
//  MacAssistant
//
//  Phase 6: Memory System Configuration UI
//

import SwiftUI

struct MemorySettingsView: View {
    @StateObject private var settings = MemorySettings.shared
    @State private var showingResetConfirmation = false
    @State private var showingExportSheet = false
    @State private var showingImportSheet = false
    @State private var importText = ""
    @State private var exportText = ""
    @State private var showingAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    
    var body: some View {
        Form {
            // MARK: - Phase Settings
            Section(header: Text("功能阶段")) {
                Picker("当前阶段", selection: $settings.currentPhase) {
                    ForEach(MemoryPhase.allCases, id: \.self) { phase in
                        Text(phase.description).tag(phase)
                    }
                }
                
                Toggle("L0 原始存储", isOn: $settings.enableL0Storage)
                Toggle("L1 过滤蒸馏", isOn: $settings.enableL1Filter)
                Toggle("L2 认知蒸馏", isOn: $settings.enableL2Distill)
                Toggle("新检索系统", isOn: $settings.enableNewRetrieval)
                Toggle("完整集成", isOn: $settings.enableFullIntegration)
            }
            
            // MARK: - Storage Backend
            Section(header: Text("存储后端")) {
                Picker("L0 后端", selection: $settings.l0Backend) {
                    Text("内存 (测试)").tag(StorageBackend.inMemory)
                    Text("ClickHouse").tag(StorageBackend.clickHouse)
                }
                
                Picker("L1 后端", selection: $settings.l1Backend) {
                    Text("内存 (测试)").tag(StorageBackend.inMemory)
                    Text("PostgreSQL").tag(StorageBackend.postgreSQL)
                }
                
                Picker("L2 后端", selection: $settings.l2Backend) {
                    Text("内存 (测试)").tag(StorageBackend.inMemory)
                    Text("PostgreSQL").tag(StorageBackend.postgreSQL)
                    Text("Pinecone").tag(StorageBackend.pinecone)
                    Text("Milvus").tag(StorageBackend.milvus)
                }
            }
            
            // MARK: - Embedding Service
            Section(header: Text("嵌入服务")) {
                Picker("提供商", selection: $settings.embeddingProvider) {
                    ForEach(EmbeddingProvider.allCases, id: \.self) { provider in
                        Text(provider.description).tag(provider)
                    }
                }
                
                if settings.embeddingProvider == .openAI {
                    SecureField("API Key", text: $settings.openAIAPIKey)
                        
                    Picker("模型", selection: $settings.embeddingModel) {
                        Text("text-embedding-3-small").tag("text-embedding-3-small")
                        Text("text-embedding-3-large").tag("text-embedding-3-large")
                        Text("text-embedding-ada-002").tag("text-embedding-ada-002")
                    }
                }
            }
            
            // MARK: - Context Injection
            Section(header: Text("上下文注入")) {
                Toggle("启用注入", isOn: $settings.injectionEnabled)
                
                if settings.injectionEnabled {
                    Picker("注入位置", selection: $settings.injectionPosition) {
                        Text("System之后").tag(InjectionPosition.afterSystem)
                        Text("User之前").tag(InjectionPosition.beforeUser)
                        Text("System前缀").tag(InjectionPosition.asSystemPrefix)
                    }
                    
                    Picker("格式", selection: $settings.injectionFormat) {
                        Text("结构化").tag(InjectionFormat.structured)
                        Text("自然语言").tag(InjectionFormat.natural)
                        Text("紧凑").tag(InjectionFormat.compact)
                        Text("Markdown").tag(InjectionFormat.markdown)
                    }
                    
                    VStack(alignment: .leading) {
                        Text("Token 预算: \(settings.contextBudget)")
                        Slider(value: Binding(
                            get: { Double(settings.contextBudget) },
                            set: { settings.contextBudget = Int($0) }
                        ), in: 500...8000, step: 100)
                    }
                }
            }
            
            // MARK: - Distillation Settings
            Section(header: Text("蒸馏配置")) {
                Picker("L1 最小重要性", selection: $settings.l1MinImportance) {
                    Text("Trivial").tag(ImportanceScore.trivial)
                    Text("Normal").tag(ImportanceScore.normal)
                    Text("Significant").tag(ImportanceScore.significant)
                    Text("Critical").tag(ImportanceScore.critical)
                }
                
                Toggle("L1 异步蒸馏", isOn: $settings.l1AsyncDistillation)
                
                VStack(alignment: .leading) {
                    Text("L2 最小概念置信度: \(String(format: "%.1f", settings.l2MinConceptConfidence))")
                    Slider(value: $settings.l2MinConceptConfidence, in: 0.0...1.0, step: 0.1)
                }
                
                Stepper("L2 批处理大小: \(settings.l2BatchSize)", value: $settings.l2BatchSize, in: 1...100)
            }
            
            // MARK: - Retention Policy
            Section(header: Text("数据保留策略")) {
                Stepper("L0 保留天数: \(settings.l0RetentionDays)", value: $settings.l0RetentionDays, in: 1...365)
                Stepper("L1 保留天数: \(settings.l1RetentionDays)", value: $settings.l1RetentionDays, in: 7...730)
                Stepper("L2 保留天数: \(settings.l2RetentionDays)", value: $settings.l2RetentionDays, in: 30...3650)
            }
            
            // MARK: - Actions
            Section(header: Text("操作")) {
                Button("应用设置") {
                    applySettings()
                }
                .foregroundColor(.blue)
                
                Button("导出配置") {
                    exportSettings()
                }
                
                Button("导入配置") {
                    showingImportSheet = true
                }
                
                Button("重置为默认") {
                    showingResetConfirmation = true
                }
                .foregroundColor(.orange)
            }
        }
        .navigationTitle("记忆系统设置")
        .sheet(isPresented: $showingExportSheet) {
            ExportSettingsView(text: exportText)
        }
        .sheet(isPresented: $showingImportSheet) {
            ImportSettingsView(text: $importText, onImport: importSettings)
        }
        .alert(isPresented: $showingAlert) {
            Alert(title: Text(alertTitle), message: Text(alertMessage), dismissButton: .default(Text("确定")))
        }
        .confirmationDialog("重置设置", isPresented: $showingResetConfirmation, titleVisibility: .visible) {
            Button("重置", role: .destructive) {
                settings.resetToDefaults()
                showAlert(title: "成功", message: "设置已重置为默认值")
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("确定要重置所有设置吗？此操作不可撤销。")
        }
    }
    
    // MARK: - Actions
    
    private func applySettings() {
        settings.syncToFeatureFlags()
        showAlert(title: "成功", message: "设置已应用")
    }
    
    private func exportSettings() {
        if let json = settings.exportSettings() {
            exportText = json
            showingExportSheet = true
        } else {
            showAlert(title: "错误", message: "导出失败")
        }
    }
    
    private func importSettings() {
        if settings.importSettings(from: importText) {
            showAlert(title: "成功", message: "配置已导入")
            showingImportSheet = false
            importText = ""
        } else {
            showAlert(title: "错误", message: "导入失败，请检查 JSON 格式")
        }
    }
    
    private func showAlert(title: String, message: String) {
        alertTitle = title
        alertMessage = message
        showingAlert = true
    }
}

// MARK: - Export Settings View

struct ExportSettingsView: View {
    let text: String
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            VStack {
                TextEditor(text: .constant(text))
                    .font(.system(.body, design: .monospaced))
                    .padding()
                
                Button("复制到剪贴板") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    dismiss()
                }
                .padding()
            }
            .navigationTitle("导出配置")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Import Settings View

struct ImportSettingsView: View {
    @Binding var text: String
    let onImport: () -> Void
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            VStack {
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .padding()
                
                Button("导入") {
                    onImport()
                }
                .disabled(text.isEmpty)
                .padding()
            }
            .navigationTitle("导入配置")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Memory Phase Extension

extension MemoryPhase {
    var description: String {
        switch self {
        case .l0Storage:
            return "Phase 0: L0 存储"
        case .l1Filter:
            return "Phase 1: L1 过滤"
        case .l2Distill:
            return "Phase 2: L2 蒸馏"
        case .retrieval:
            return "Phase 3: 检索"
        case .integration:
            return "Phase 4: 集成"
        }
    }
}

// MemoryPhase already conforms to CaseIterable in FeatureFlags.swift

// MARK: - Storage Backend Extension

extension StorageBackend {
    var description: String {
        switch self {
        case .inMemory:
            return "内存"
        case .clickHouse:
            return "ClickHouse"
        case .postgreSQL:
            return "PostgreSQL"
        case .pinecone:
            return "Pinecone"
        case .milvus:
            return "Milvus"
        case .neo4j:
            return "Neo4j"
        }
    }
}

// MARK: - Preview

struct MemorySettingsView_Previews: PreviewProvider {
    static var previews: some View {
        MemorySettingsView()
    }
}
