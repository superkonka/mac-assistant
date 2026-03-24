//
//  HealthMonitorConfig.swift
//  MacAssistant
//
//  健康监控配置（简化版）
//

import Foundation

@MainActor
final class HealthMonitorConfig: ObservableObject {
    static let shared = HealthMonitorConfig()
    
    private init() {}
}
