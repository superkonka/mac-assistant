//
//  ServiceEntryButton.swift
//  MacAssistant
//
//  服务入口按钮 - 快速访问服务管理
//

import SwiftUI

struct ServiceEntryButton: View {
    @StateObject private var manager = ServiceManager.shared
    @State private var showPanel = false
    
    /// 计算运行中数量
    private var runningCount: Int {
        manager.services.filter { $0.state == .running }.count
    }
    
    /// 计算异常数量
    private var errorCount: Int {
        manager.services.filter { $0.state == .error }.count
    }
    
    private var statusColor: Color {
        if errorCount > 0 {
            return .red
        } else if runningCount > 0 {
            return .green
        } else {
            return .secondary
        }
    }
    
    private var badgeText: String? {
        if errorCount > 0 {
            return "\(errorCount)"
        } else if runningCount > 0 {
            return "\(runningCount)"
        }
        return nil
    }
    
    var body: some View {
        Button(action: { showPanel = true }) {
            HStack(spacing: 6) {
                Image(systemName: "server.rack")
                    .font(.system(size: 13))
                
                Text("服务")
                    .font(.system(size: 12, weight: .medium))
                
                if let badge = badgeText {
                    Text(badge)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(statusColor)
                        .clipShape(Capsule())
                }
            }
            .foregroundColor(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .help("管理本地服务")
        .popover(isPresented: $showPanel, arrowEdge: .bottom) {
            ServiceManagerView()
                .frame(width: 500, height: 450)
        }
    }
}

#Preview {
    ServiceEntryButton()
        .padding()
}
