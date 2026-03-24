//
//  ServiceRow.swift
//  MacAssistant
//
//  服务列表行视图（简化版）
//

import SwiftUI

struct ServiceRow: View {
    let serviceId: String
    
    var body: some View {
        Text(serviceId)
            .padding()
    }
}

#Preview {
    ServiceRow(serviceId: "test")
}
