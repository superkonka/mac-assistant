//
//  ServiceLogsView.swift
//  MacAssistant
//
//  服务日志视图（简化版）
//

import SwiftUI

struct ServiceLogsView: View {
    let serviceId: String
    
    var body: some View {
        Text("服务日志: \(serviceId)")
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    ServiceLogsView(serviceId: "test")
}
