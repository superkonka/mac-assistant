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
    private let detectionPoliciesKey = "macassistant.user_preferences.v1.skill_detection_policies"
    private let plannerShadowEnabledKey = "macassistant.user_preferences.v1.planner_shadow_enabled"
    private let plannerShadowPreferredAgentKey = "macassistant.user_preferences.v1.planner_shadow_agent_id"
    private let plannerPrimaryStrategyKey = "macassistant.user_preferences.v1.planner_primary_strategy"
    private let plannerPreferredAgentKey = "macassistant.user_preferences.v1.planner_agent_id"
    
    // MARK: - 偏好类型
    
    /// 拒绝的 Skill 检测
    var rejectedSkills: Set<String> {
        get {
            Set(userDefaults.stringArray(forKey: "\(preferencesKey).rejected_skills") ?? [])
        }
        set {
            objectWillChange.send()
            userDefaults.set(Array(newValue), forKey: "\(preferencesKey).rejected_skills")
        }
    }
    
    /// 自动确认的 Skill（用户信任的技能）
    var autoConfirmSkills: Set<String> {
        get {
            Set(userDefaults.stringArray(forKey: "\(preferencesKey).auto_confirm_skills") ?? [])
        }
        set {
            objectWillChange.send()
            userDefaults.set(Array(newValue), forKey: "\(preferencesKey).auto_confirm_skills")
        }
    }
    
    /// 偏好使用的 Agent
    var preferredAgent: String? {
        get {
            userDefaults.string(forKey: "\(preferencesKey).preferred_agent")
        }
        set {
            objectWillChange.send()
            userDefaults.set(newValue, forKey: "\(preferencesKey).preferred_agent")
        }
    }
    
    /// 每种任务类型的首选 Agent
    var taskPreferredAgents: [String: String] {
        get {
            userDefaults.dictionary(forKey: "\(preferencesKey).task_agents") as? [String: String] ?? [:]
        }
        set {
            objectWillChange.send()
            userDefaults.set(newValue, forKey: "\(preferencesKey).task_agents")
        }
    }
    
    /// 是否禁用自然语言意图检测
    var disableNaturalIntentDetection: Bool {
        get {
            userDefaults.bool(forKey: "\(preferencesKey).disable_natural_intent")
        }
        set {
            objectWillChange.send()
            userDefaults.set(newValue, forKey: "\(preferencesKey).disable_natural_intent")
        }
    }
    
    /// 连续拒绝计数（用于自动调整敏感度）
    var consecutiveRejections: Int {
        get {
            userDefaults.integer(forKey: "\(preferencesKey).consecutive_rejections")
        }
        set {
            objectWillChange.send()
            userDefaults.set(newValue, forKey: "\(preferencesKey).consecutive_rejections")
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
            objectWillChange.send()
            if let data = try? JSONEncoder().encode(newValue) {
                userDefaults.set(data, forKey: "\(preferencesKey).session_stats")
            }
        }
    }

    var skillDetectionPolicies: [String: String] {
        get {
            userDefaults.dictionary(forKey: detectionPoliciesKey) as? [String: String] ?? [:]
        }
        set {
            objectWillChange.send()
            userDefaults.set(newValue, forKey: detectionPoliciesKey)
        }
    }

    var plannerShadowEnabled: Bool {
        get {
            userDefaults.bool(forKey: plannerShadowEnabledKey)
        }
        set {
            objectWillChange.send()
            userDefaults.set(newValue, forKey: plannerShadowEnabledKey)
        }
    }

    var plannerShadowPreferredAgentID: String? {
        get {
            userDefaults.string(forKey: plannerShadowPreferredAgentKey)
        }
        set {
            objectWillChange.send()
            userDefaults.set(newValue, forKey: plannerShadowPreferredAgentKey)
        }
    }

    var plannerPrimaryStrategy: PlannerPrimaryStrategy {
        get {
            guard let rawValue = userDefaults.string(forKey: plannerPrimaryStrategyKey),
                  let strategy = PlannerPrimaryStrategy(rawValue: rawValue) else {
                return .ruleBased
            }
            return strategy
        }
        set {
            objectWillChange.send()
            userDefaults.set(newValue.rawValue, forKey: plannerPrimaryStrategyKey)
        }
    }

    var plannerPreferredAgentID: String? {
        get {
            userDefaults.string(forKey: plannerPreferredAgentKey) ?? userDefaults.string(forKey: plannerShadowPreferredAgentKey)
        }
        set {
            objectWillChange.send()
            userDefaults.set(newValue, forKey: plannerPreferredAgentKey)
        }
    }
    
    // MARK: - 方法
    
    /// 记录拒绝的 Skill
    func recordSkillRejection(_ skill: AISkill) {
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
        sessionStats = stats
    }

    func detectionPreference(for skill: AISkill) -> SkillDetectionPreference {
        if let rawValue = skillDetectionPolicies[skill.rawValue],
           let preference = SkillDetectionPreference(rawValue: rawValue) {
            return preference
        }

        if rejectedSkills.contains(skill.rawValue) {
            return .neverSuggest
        }

        if autoConfirmSkills.contains(skill.rawValue) {
            return .autoRun
        }

        return .askEveryTime
    }

    func setDetectionPreference(_ preference: SkillDetectionPreference, for skill: AISkill) {
        var policies = skillDetectionPolicies
        policies[skill.rawValue] = preference.rawValue
        skillDetectionPolicies = policies

        var rejected = rejectedSkills
        var autoConfirm = autoConfirmSkills

        switch preference {
        case .askEveryTime:
            rejected.remove(skill.rawValue)
            autoConfirm.remove(skill.rawValue)
        case .autoRun:
            rejected.remove(skill.rawValue)
            autoConfirm.insert(skill.rawValue)
        case .neverSuggest:
            autoConfirm.remove(skill.rawValue)
            rejected.insert(skill.rawValue)
        }

        rejectedSkills = rejected
        autoConfirmSkills = autoConfirm
    }
    
    /// 检查是否应该跳过检测
    func shouldSkipDetection(_ skill: AISkill) -> Bool {
        if detectionPreference(for: skill) == .neverSuggest {
            return true
        }
        
        if disableNaturalIntentDetection {
            return true
        }
        
        return false
    }
    
    /// 检查是否应该自动确认
    func shouldAutoConfirm(_ skill: AISkill) -> Bool {
        detectionPreference(for: skill) == .autoRun
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
        skillDetectionPolicies.removeAll()
        preferredAgent = nil
        taskPreferredAgents.removeAll()
        disableNaturalIntentDetection = false
        plannerPrimaryStrategy = .ruleBased
        plannerPreferredAgentID = nil
        plannerShadowEnabled = false
        plannerShadowPreferredAgentID = nil
        consecutiveRejections = 0
        sessionStats = SessionPreferences()
        
        print("✅ 所有用户偏好已重置")
    }
    
    /// 导出偏好设置
    func exportPreferences() -> [String: Any] {
        return [
            "rejected_skills": Array(rejectedSkills),
            "auto_confirm_skills": Array(autoConfirmSkills),
            "skill_detection_policies": skillDetectionPolicies,
            "preferred_agent": preferredAgent as Any,
            "task_agents": taskPreferredAgents,
            "disable_natural_intent": disableNaturalIntentDetection,
            "planner_primary_strategy": plannerPrimaryStrategy.rawValue,
            "planner_preferred_agent_id": plannerPreferredAgentID as Any,
            "planner_shadow_enabled": plannerShadowEnabled,
            "planner_shadow_preferred_agent_id": plannerShadowPreferredAgentID as Any,
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
