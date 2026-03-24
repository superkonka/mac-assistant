//
//  ServiceDiscoveryManager.swift
//  MacAssistant
//
//  服务发现管理器（简化版）
//

import Foundation

@MainActor
final class ServiceDiscoveryManager: ObservableObject {
    static let shared = ServiceDiscoveryManager()
    
    private init() {}
    
    func discoverServices() async -> [String] {
        return []
    }
}
