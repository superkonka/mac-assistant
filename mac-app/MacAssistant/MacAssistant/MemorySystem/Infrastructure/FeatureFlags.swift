//
//  FeatureFlags.swift
//  MacAssistant
//
//  Hierarchical Memory System - Feature Flags
//

import Foundation

/// 记忆系统开发阶段
enum MemoryPhase: String, CaseIterable, Sendable {
    case l0Storage      = "L0_Storage"      // 原始数据存储
    case l1Filter       = "L1_Filter"       // 信息过滤
    case l2Distill      = "L2_Distill"      // 认知蒸馏
    case retrieval      = "Retrieval"       // 分层检索
    case integration    = "Integration"     // 系统集成
}

/// 记忆系统特性开关
struct MemoryFeatureFlags {
    
    // MARK: - Phase Control
    
    static var currentPhase: MemoryPhase = .retrieval  // Phase 2
    
    // MARK: - Feature Switches
    
    /// L0: 原始数据存储
    static var enableL0Storage: Bool = true
    
    /// L1: 信息过滤层 (Phase 2)
    static var enableL1Filter: Bool = true  // 开启 Phase 2
    
    /// L2: 认知蒸馏层
    static var enableL2Distill: Bool = true  // Phase 3 enabled
    
    /// 新检索引擎
    static var enableNewRetrieval: Bool = true  // Phase 4 enabled
    
    /// 完整系统集成
    static var enableFullIntegration: Bool = false
    
    // MARK: - Configuration
    
    /// L0 存储保留时间（天）
    static var l0RetentionDays: Int = 30
    
    /// L1 存储保留时间（天）
    static var l1RetentionDays: Int = 90
    
    /// L2 永久保留
    static var l2Permanent: Bool = true
    
    /// 蒸馏批大小
    static var distillationBatchSize: Int = 100
    
    /// 是否异步蒸馏（不阻塞主流程）
    static var asyncDistillation: Bool = true
    
    // MARK: - Phase Switching
    
    static func switchToPhase(_ phase: MemoryPhase) {
        currentPhase = phase
        
        // 重置所有开关
        enableL0Storage = false
        enableL1Filter = false
        enableL2Distill = false
        enableNewRetrieval = false
        enableFullIntegration = false
        
        // 根据阶段开启对应功能
        switch phase {
        case .l0Storage:
            enableL0Storage = true
            
        case .l1Filter:
            enableL0Storage = true
            enableL1Filter = true
            
        case .l2Distill:
            enableL0Storage = true
            enableL1Filter = true
            enableL2Distill = true
            
        case .retrieval:
            enableL0Storage = true
            enableL1Filter = true
            enableL2Distill = true
            enableNewRetrieval = true
            
        case .integration:
            enableAll()
        }
        
        LogInfo("[MemorySystem] Switched to phase: \(phase.rawValue)")
    }
    
    static func enableAll() {
        enableL0Storage = true
        enableL1Filter = true
        enableL2Distill = true
        enableNewRetrieval = true
        enableFullIntegration = true
        currentPhase = .integration
    }
    
    static func disableAll() {
        enableL0Storage = false
        enableL1Filter = false
        enableL2Distill = false
        enableNewRetrieval = false
        enableFullIntegration = false
    }
    
    // MARK: - Debug Helpers
    
    static var statusDescription: String {
        """
        [Memory System Status]
        Current Phase: \(currentPhase.rawValue)
        L0 Storage: \(enableL0Storage ? "✅" : "❌")
        L1 Filter: \(enableL1Filter ? "✅" : "❌")
        L2 Distill: \(enableL2Distill ? "✅" : "❌")
        New Retrieval: \(enableNewRetrieval ? "✅" : "❌")
        Full Integration: \(enableFullIntegration ? "✅" : "❌")
        """
    }
}
