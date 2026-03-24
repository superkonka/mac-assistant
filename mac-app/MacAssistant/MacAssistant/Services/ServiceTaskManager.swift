//
//  ServiceTaskManager.swift
//  MacAssistant
//
//  服务任务管理器（简化版）
//

import Foundation

@MainActor
final class ServiceTaskManager: ObservableObject {
    static let shared = ServiceTaskManager()
    
    /// 活跃的服务任务ID（兼容旧代码）
    @Published var activeServiceTasks: [String] = []
    
    private init() {}
    
    func hasActiveTask(for serviceId: String) -> Bool {
        return activeServiceTasks.contains(serviceId)
    }
}
