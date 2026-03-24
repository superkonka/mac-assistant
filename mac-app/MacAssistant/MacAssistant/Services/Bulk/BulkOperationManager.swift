//
//  BulkOperationManager.swift
//  MacAssistant
//
//  批量操作管理器（简化版）
//

import Foundation

@MainActor
final class BulkOperationManager: ObservableObject {
    static let shared = BulkOperationManager()
    
    private init() {}
    
    func executeBulkOperation(services: [String], operation: String) async -> Bool {
        // 简化实现
        return true
    }
}
