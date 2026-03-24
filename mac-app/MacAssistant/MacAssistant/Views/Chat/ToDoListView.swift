//
//  ToDoListView.swift
//  MacAssistant
//
//  旧待办页兼容壳 - 统一转到新的任务管理器
//

import SwiftUI

struct ToDoListView: View {
    var body: some View {
        UnifiedTaskManagerView()
            .frame(width: 760, height: 620)
    }
}

#Preview {
    ToDoListView()
}
