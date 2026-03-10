//
//  UserPreferenceStore.swift
//  MacAssistant
//
//  用户偏好存储 - 记住用户选择，减少重复提示
//

import Foundation

/// 用户偏好存储
class UserPreferenceStore: ObservableObject {
    static let shared = UserPreferenceStore()
    
    private let userDefaults = UserDefaults.standard
    private let preferencesKey = "macassistant.user_preferences.v1"
    
    // MARK: - 偏好类型
    
    /// 拒绝的 Skill 检测
    var rejectedSkills: Set<String> {
        get {
            Set(userDefaults.stringArray(forKey: "\(preferencesKey).rejected_skills") ?? [])
        }
        set {
            userDefaults.set(Array(newValue), forKey: "\(preferencesKey).rejected_skills")
        }
    }
    
    /// 自动确认的 Skill（用户信任的技能）
    var autoConfirmSkills: Set<String> {
        get {
            Set(userDefaults.stringArray(forKey: "\(preferencesKey).auto_confirm_skills") ?? [])
        }
        set {
            userDefaults.set(Array(newValue), forKey: "\(preferencesKey).auto_confirm_skills")
        }
    }
    
    /// 偏好使用的 Agent
    var preferredAgent: String? {
        get {
            userDefaults.string(forKey: "\(preferencesKey).preferred_agent")
        }
        set {
            userDefaults.set(newValue, forKey: "\(preferencesKey).preferred_agent")
        }
    }
    
    /// 每种任务类型的首选 Agent
    var taskPreferredAgents: [String: String] {
        get {
            userDefaults.dictionary(forKey: "\(preferencesKey).task_agents") as? [String: String] ?? [:]
        }
        set {
            userDefaults.set(newValue, forKey: "\(preferencesKey).task_agents")
        }
    }
    
    /// 是否禁用自然语言意图检测
    var disableNaturalIntentDetection: Bool {
        get {
            userDefaults.bool(forKey: "\(preferencesKey).disable_natural_intent")
        }
        set {
            userDefaults.set(newValue, forKey: "\(preferencesKey).disable_natural_intent")
        }
    }
    
    /// 连续拒绝计数（用于自动调整敏感度）
    var consecutiveRejections: Int {
        get {
            userDefaults.integer(forKey: "\(preferencesKey).consecutive_rejections")
        }
        set {
            userDefaults.set(newValue, forKey: "\(preferencesKey).consecutive_rejections")
            
            // 如果连续拒绝超过3次，自动禁用自然语言检测
            if newValue >= 3 && !disableNaturalIntentDetection {
                disableNaturalIntentDetection = true
                print("⚠️ 连续拒绝 \(newValue) 次意图检测，已自动禁用自然语言检测")
            }
        }
    }
    
    /// 会话统计
    var sessionStats: SessionPreferences {
        get {
            guard let data = userDefaults.data(forKey: "\(preferencesKey).session_stats"),
                  let stats = try? JSONDecoder().decode(SessionPreferences.self, from: data) else {
                return SessionPreferences()
            }
            return stats
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                userDefaults.set(data, forKey: "\(preferencesKey).session_stats")
            }
        }
    }
    
    // MARK: - 方法
    
    /// 记录拒绝的 Skill
    func recordSkillRejection(_ skill: AISkill) {
        rejectedSkills.insert(skill.rawValue)
        consecutiveRejections += 1
        
        print("📊 记录拒绝 Skill: \(skill.name) (连续拒绝: \(consecutiveRejections))")
    }
    
    /// 记录接受的 Skill
    func recordSkillAcceptance(_ skill: AISkill) {
        // 重置拒绝计数
        consecutiveRejections = 0
        
        // 记录使用次数
        var stats = sessionStats
        stats.skillUsageCount[skill.rawValue, default: 0] += 1
        
        // 如果使用超过3次，添加到自动确认列表
        if stats.skillUsageCount[skill.rawValue, default: 0] >= 3 {
            autoConfirmSkills.insert(skill.rawValue)
            print("✅ Skill '\(skill.name)' 已添加到自动确认列表")
        }
        
        sessionStats = stats
    }
    
    /// 检查是否应该跳过检测
    func shouldSkipDetection(_ skill: AISkill) -> Bool {
        // 如果用户明确拒绝了该 Skill
        if rejectedSkills.contains(skill.rawValue) {
            return true
        }
        
        // 如果自然语言检测被禁用
        if disableNaturalIntentDetection {
            return true
        }
        
        return false
    }
    
    /// 检查是否应该自动确认
    func shouldAutoConfirm(_ skill: AISkill) -> Bool {
        return autoConfirmSkills.contains(skill.rawValue)
    }
    
    /// 记录 Agent 偏好
    func recordAgentPreference(agent: Agent, for task: String? = nil) {
        if let task = task {
            var agents = taskPreferredAgents
            agents[task] = agent.id
            taskPreferredAgents = agents
        } else {
            preferredAgent = agent.id
        }
    }
    
    /// 获取推荐 Agent
    func getPreferredAgent(for task: String? = nil) -> String? {
        if let task = task, let agentId = taskPreferredAgents[task] {
            return agentId
        }
        return preferredAgent
    }
    
    /// 获取常用的 Skill 列表
    func getFrequentlyUsedSkills(minUsage: Int = 2) -> [String] {
        let stats = sessionStats
        return stats.skillUsageCount
            .filter { $0.value >= minUsage }
            .sorted { $0.value > $1.value }
            .map { $0.key }
    }
    
    /// 重置所有偏好
    func resetAllPreferences() {
        rejectedSkills.removeAll()
        autoConfirmSkills.removeAll()
        preferredAgent = nil
        taskPreferredAgents.removeAll()
        disableNaturalIntentDetection = false
        consecutiveRejections = 0
        sessionStats = SessionPreferences()
        
        print("✅ 所有用户偏好已重置")
    }
    
    /// 导出偏好设置
    func exportPreferences() -> [String: Any] {
        return [
            "rejected_skills": Array(rejectedSkills),
            "auto_confirm_skills": Array(autoConfirmSkills),
            "preferred_agent": preferredAgent as Any,
            "task_agents": taskPreferredAgents,
            "disable_natural_intent": disableNaturalIntentDetection,
            "consecutive_rejections": consecutiveRejections,
            "session_stats": try? JSONEncoder().encode(sessionStats)
        ]
    }
}

// MARK: - 会话偏好

struct SessionPreferences: Codable {
    var skillUsageCount: [String: Int] = [:]
    var agentUsageCount: [String: Int] = [:]
    var totalSessions: Int = 0
    var totalMessages: Int = 0
}
