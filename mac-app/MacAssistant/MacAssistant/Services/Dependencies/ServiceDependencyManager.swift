//
//  ServiceDependencyManager.swift
//  MacAssistant
//
//  服务依赖管理器（简化版）
//

import Foundation

@MainActor
final class ServiceDependencyManager: ObservableObject {
    static let shared = ServiceDependencyManager()
    
    private init() {}
    
    func checkDependencies(for serviceId: String) -> [String] {
        // 简化实现
        return []
    }
}
