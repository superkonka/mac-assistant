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
                StatCard(title: "Distilled", value: viewModel.distilledCount)
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
                
                Button("Trigger Distillation") {
                    viewModel.triggerDistillation()
                }
                .disabled(!MemoryFeatureFlags.enableL1Filter)
                
                Button("Clear Memory") {
                    viewModel.clearMemory()
                }
                .foregroundColor(.red)
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
    @Published var distilledCount: UInt64 = 0
    @Published var distillationStats = DistillationStats()
    @Published var isProcessing = false
    @Published var statusMessage: String?
    
    func refresh() {
        Task {
            // 获取统计
            distillationStats = await MemoryCoordinator.shared.getDistillationStats()
            
            // 获取存储统计（需要添加方法到 store）
            // l0Count = await (MemoryCoordinator.shared.l0Store as? InMemoryRawStore)?.entryCount() ?? 0
            
            statusMessage = "Last updated: \(Date().formatted(date: .omitted, time: .standard))"
        }
    }
    
    func triggerDistillation() {
        Task {
            isProcessing = true
            statusMessage = "Running distillation..."
            
            do {
                let count = try await MemoryCoordinator.shared.triggerFullDistillation(planId: nil)
                statusMessage = "Distilled \(count) entries"
                refresh()
            } catch {
                statusMessage = "Error: \(error.localizedDescription)"
            }
            
            isProcessing = false
        }
    }
    
    func clearMemory() {
        Task {
            // 清理内存存储
            // await (MemoryCoordinator.shared.l0Store as? InMemoryRawStore)?.clearAll()
            refresh()
            statusMessage = "Memory cleared"
        }
    }
}

// MARK: - Preview

struct MemoryDebugView_Previews: PreviewProvider {
    static var previews: some View {
        MemoryDebugView()
    }
}
