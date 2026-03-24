//
//  HealthMonitorEngine.swift
//  MacAssistant
//
//  健康监控引擎（简化版）
//

import Foundation

@MainActor
final class HealthMonitorEngine: ObservableObject {
    static let shared = HealthMonitorEngine()
    
    private init() {}
    
    func checkHealth(for serviceId: String) async -> Bool {
        return true
    }
}
