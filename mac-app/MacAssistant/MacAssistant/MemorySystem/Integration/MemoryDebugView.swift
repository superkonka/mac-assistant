//
//  MemoryDebugView.swift
//  MacAssistant
//
//  Debug UI for Hierarchical Memory System (Phase 2)
//

import SwiftUI

/// 记忆系统调试视图
struct MemoryDebugView: View {
    @StateObject private var viewModel = MemoryDebugViewModel()
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 标题
            HStack {
                Text("🧠 Memory System Debug")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                PhaseBadge(phase: MemoryFeatureFlags.currentPhase)
            }
            
            Divider()
            
            // 功能开关状态
            FeatureStatusSection()
            
            Divider()
            
            // 统计信息
            StatsSection(viewModel: viewModel)
            
            Divider()
            
            // 操作按钮
            ActionsSection(viewModel: viewModel)
            
            Spacer()
        }
        .padding()
        .frame(width: 400, height: 500)
        .onAppear {
            viewModel.refresh()
        }
    }
}

// MARK: - Subviews

struct PhaseBadge: View {
    let phase: MemoryPhase
    
    var body: some View {
        Text(phase.rawValue)
            .font(.caption)
            .fontWeight(.semibold)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(phaseColor)
            .foregroundColor(.white)
            .cornerRadius(4)
    }
    
    var phaseColor: Color {
        switch phase {
        case .l0Storage: return .blue
        case .l1Filter: return .green
        case .l2Distill: return .orange
        case .retrieval: return .purple
        case .integration: return .red
        }
    }
}

struct FeatureStatusSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Feature Status")
                .font(.headline)
            
            FeatureRow(name: "L0 Storage", enabled: MemoryFeatureFlags.enableL0Storage)
            FeatureRow(name: "L1 Filter (Phase 2)", enabled: MemoryFeatureFlags.enableL1Filter)
            FeatureRow(name: "L2 Distill", enabled: MemoryFeatureFlags.enableL2Distill)
            FeatureRow(name: "New Retrieval", enabled: MemoryFeatureFlags.enableNewRetrieval)
        }
    }
}

struct FeatureRow: View {
    let name: String
    let enabled: Bool
    
    var body: some View {
        HStack {
            Text(name)
            Spacer()
            Image(systemName: enabled ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundColor(enabled ? .green : .gray)
        }
    }
}

struct StatsSection: View {
    @ObservedObject var viewModel: MemoryDebugViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Statistics")
                .font(.headline)
            
            HStack {
                StatCard(title: "L0 Entries", value: viewModel.l0Count)
                StatCard(title: "L1 Entries", value: viewModel.l1Count)
                StatCard(title: "L2 Entries", value: viewModel.l2Count)
            }
            
            if MemoryFeatureFlags.enableL2Distill {
                HStack {
                    StatCard(title: "Concepts", value: viewModel.conceptCount)
                    StatCard(title: "Relations", value: viewModel.relationCount)
                    StatCard(title: "Patterns", value: viewModel.patternCount)
                }
            }
            
            if viewModel.distillationStats.totalProcessed > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Distillation Progress")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    ProgressView(
                        value: viewModel.distillationStats.successRate,
                        total: 1.0
                    )
                    
                    Text("\(viewModel.distillationStats.totalProcessed) processed, \(viewModel.distillationStats.totalFailed) failed")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

struct StatCard: View {
    let title: String
    let value: UInt64
    
    var body: some View {
        VStack {
            Text("\(value)")
                .font(.title3)
                .fontWeight(.bold)
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
    }
}

struct ActionsSection: View {
    @ObservedObject var viewModel: MemoryDebugViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Actions")
                .font(.headline)
            
            HStack {
                Button("Refresh") {
                    viewModel.refresh()
                }
                
                if MemoryFeatureFlags.enableL1Filter {
                    Button("L1 Distill") {
                        viewModel.triggerDistillation()
                    }
                }
                
                if MemoryFeatureFlags.enableL2Distill {
                    Button("L2 Distill") {
                        viewModel.triggerL2Distillation()
                    }
                }
                
                Button("Clear") {
                    viewModel.clearMemory()
                }
                .foregroundColor(.red)
            }
            
            if MemoryFeatureFlags.enableL2Distill {
                HStack {
                    Button("Build Context") {
                        viewModel.buildContext()
                    }
                    
                    Button("Search") {
                        viewModel.semanticSearch()
                    }
                    
                    Button("Graph Query") {
                        viewModel.queryGraph()
                    }
                }
            }
            
            if viewModel.isProcessing {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
            }
            
            if let message = viewModel.statusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - ViewModel

@MainActor
class MemoryDebugViewModel: ObservableObject {
    @Published var l0Count: UInt64 = 0
    @Published var l1Count: UInt64 = 0
    @Published var l2Count: UInt64 = 0
    @Published var conceptCount: UInt64 = 0
    @Published var relationCount: UInt64 = 0
    @Published var patternCount: UInt64 = 0
    @Published var distillationStats = DistillationStats()
    @Published var isProcessing = false
    @Published var statusMessage: String?
    
    func refresh() {
        Task {
            // 获取统计
            distillationStats = await MemoryCoordinator.shared.getDistillationStats()
            
            // 获取 L2 统计
            if let context = try? await MemoryCoordinator.shared.buildContext() {
                conceptCount = UInt64(context.cognition.concepts.count)
                patternCount = UInt64(context.cognition.insights.count)
            }
            
            statusMessage = "Updated: \(Date().formatted(date: .omitted, time: .standard))"
        }
    }
    
    func triggerDistillation() {
        Task {
            isProcessing = true
            statusMessage = "Running L1 distillation..."
            
            do {
                let count = try await MemoryCoordinator.shared.triggerFullDistillation(planId: nil)
                statusMessage = "L1 distilled \(count) entries"
                refresh()
            } catch {
                statusMessage = "Error: \(error.localizedDescription)"
            }
            
            isProcessing = false
        }
    }
    
    func triggerL2Distillation() {
        Task {
            isProcessing = true
            statusMessage = "Running L2 distillation..."
            
            // 触发 Plan 结束时的 L2 处理
            do {
                try await MemoryCoordinator.shared.finalizePlan(planId: "test-plan")
                statusMessage = "L2 distillation complete"
                refresh()
            } catch {
                statusMessage = "Error: \(error.localizedDescription)"
            }
            
            isProcessing = false
        }
    }
    
    func buildContext() {
        Task {
            isProcessing = true
            statusMessage = "Building context..."
            
            do {
                let context = try await MemoryCoordinator.shared.buildContext()
                statusMessage = "Context: \(context?.tokenEstimate ?? 0) tokens, \(context?.cognition.concepts.count ?? 0) concepts"
            } catch {
                statusMessage = "Error: \(error.localizedDescription)"
            }
            
            isProcessing = false
        }
    }
    
    func semanticSearch() {
        Task {
            isProcessing = true
            statusMessage = "Searching..."
            
            do {
                let results = try await MemoryCoordinator.shared.semanticSearch(query: "test", limit: 5)
                statusMessage = "Found \(results.count) results"
            } catch {
                statusMessage = "Error: \(error.localizedDescription)"
            }
            
            isProcessing = false
        }
    }
    
    func queryGraph() {
        Task {
            isProcessing = true
            statusMessage = "Querying graph..."
            
            do {
                let results = try await MemoryCoordinator.shared.queryKnowledgeGraph(conceptName: "test")
                statusMessage = "Found \(results.count) graph nodes"
            } catch {
                statusMessage = "Error: \(error.localizedDescription)"
            }
            
            isProcessing = false
        }
    }
    
    func clearMemory() {
        Task {
            statusMessage = "Memory cleared (mock)"
            refresh()
        }
    }
}

// MARK: - Preview

struct MemoryDebugView_Previews: PreviewProvider {
    static var previews: some View {
        MemoryDebugView()
    }
}
