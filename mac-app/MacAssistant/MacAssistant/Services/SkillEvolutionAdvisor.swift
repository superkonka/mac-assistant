import Combine
import Foundation

struct SkillEvolutionProposal: Codable, Identifiable, Equatable {
    let id: String
    let skillId: String
    let skillName: String
    let currentVersion: Int
    let suggestedVersion: Int
    let reason: String
    let improvements: [String]
    let evidence: [String]
    let createdAt: Date

    init(
        id: String = UUID().uuidString,
        skillId: String,
        skillName: String,
        currentVersion: Int,
        suggestedVersion: Int,
        reason: String,
        improvements: [String],
        evidence: [String],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.skillId = skillId
        self.skillName = skillName
        self.currentVersion = currentVersion
        self.suggestedVersion = suggestedVersion
        self.reason = reason
        self.improvements = improvements
        self.evidence = evidence
        self.createdAt = createdAt
    }
}

final class SkillEvolutionAdvisor {
    static let shared = SkillEvolutionAdvisor()

    private let storage = StorageManager.shared
    private let skillSystem = SkillSystem.shared
    private let defaults = UserDefaults.standard
    private let proposalsKey = "skill.evolution.proposals.v1"
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        self.observeEvolutionSignals()
    }

    func scanNow() -> [SkillEvolutionProposal] {
        var discovered: [SkillEvolutionProposal] = []
        for skill in self.storage.getSkills() {
            let stats = self.storage.getSkillUsageStats(skillId: skill.id)
            guard self.shouldPropose(skill: skill, stats: stats),
                  let proposal = self.createProposal(skill: skill, stats: stats) else {
                continue
            }
            if self.saveProposalIfNeeded(proposal) {
                discovered.append(proposal)
            }
        }
        return discovered
    }

    func pendingProposals() -> [SkillEvolutionProposal] {
        self.loadProposals().sorted { $0.createdAt > $1.createdAt }
    }

    func summaryMessage() -> String {
        let proposals = self.pendingProposals()
        guard !proposals.isEmpty else {
            return """
            当前还没有待确认的 Skill 优化提案。

            当某个 Skill 成功率偏低、失败较多，或者积累了改进建议时，我会自动给出优化方案并请你确认。
            """
        }

        let lines = proposals.prefix(8).map { proposal in
            "• \(proposal.skillName) v\(proposal.currentVersion) -> v\(proposal.suggestedVersion)：\(proposal.reason)"
        }

        return """
        当前待确认的 Skill 优化提案：
        \(lines.joined(separator: "\n"))

        如果你同意其中某一条，我会在提案消息下面直接等你回复“是”来落地更新。
        """
    }

    func acceptProposal(id: String) -> String {
        let proposals = self.loadProposals()
        guard let proposal = proposals.first(where: { $0.id == id }) else {
            return "这条 Skill 优化提案已经不存在了，可能已经处理过。"
        }

        self.skillSystem.evolveSkill(
            proposal.skillId,
            reason: proposal.reason,
            improvements: proposal.improvements
        )
        self.removeProposal(id: id)

        let improvements = proposal.improvements.map { "• \($0)" }.joined(separator: "\n")
        return """
        ✅ 已应用 \(proposal.skillName) 的优化提案
        • 版本: v\(proposal.currentVersion) -> v\(proposal.suggestedVersion)
        • 原因: \(proposal.reason)

        已落实的调整：
        \(improvements)
        """
    }

    func rejectProposal(id: String) -> String {
        let proposals = self.loadProposals()
        guard let proposal = proposals.first(where: { $0.id == id }) else {
            return "这条 Skill 优化提案已经不存在了，可能已经处理过。"
        }

        self.removeProposal(id: id)
        return "好的，已忽略 \(proposal.skillName) 的这条 Skill 优化提案。后续如果再次出现明显问题，我会重新提出建议。"
    }

    private func observeEvolutionSignals() {
        NotificationCenter.default.publisher(for: .skillShouldEvolve)
            .sink { [weak self] notification in
                guard let self,
                      let skillId = notification.userInfo?["skillId"] as? String,
                      let skill = self.storage.getSkill(id: skillId) else {
                    return
                }

                let stats = self.storage.getSkillUsageStats(skillId: skill.id)
                guard let proposal = self.createProposal(skill: skill, stats: stats),
                      self.saveProposalIfNeeded(proposal) else {
                    return
                }

                NotificationCenter.default.post(
                    name: .skillEvolutionProposalReady,
                    object: proposal
                )
            }
            .store(in: &self.cancellables)
    }

    private func shouldPropose(skill: Skill, stats: SkillUsageStats) -> Bool {
        guard stats.totalUses >= 5 else { return false }

        if !stats.improvementSuggestions.isEmpty {
            return true
        }

        if stats.successRate < 0.7 && stats.failCount >= 2 {
            return true
        }

        if stats.totalUses >= 20 && stats.successRate >= 0.9 {
            return true
        }

        return false
    }

    private func createProposal(skill: Skill, stats: SkillUsageStats) -> SkillEvolutionProposal? {
        let improvements = self.improvements(for: skill, stats: stats)
        guard !improvements.isEmpty else {
            return nil
        }

        let reason = self.reason(for: skill, stats: stats)
        let evidence = self.evidence(for: skill, stats: stats)

        return SkillEvolutionProposal(
            skillId: skill.id,
            skillName: skill.name,
            currentVersion: skill.version,
            suggestedVersion: skill.version + 1,
            reason: reason,
            improvements: improvements,
            evidence: evidence
        )
    }

    private func improvements(for skill: Skill, stats: SkillUsageStats) -> [String] {
        var improvements: [String] = []

        if stats.successRate < 0.7 {
            improvements.append("优化命令模板，增加更稳的默认分支")
        }

        if stats.failCount >= 3 || skill.triggers.count <= 2 {
            improvements.append("补充触发词，覆盖更多自然语言表达")
        }

        if stats.totalUses >= 20 && stats.successRate >= 0.9 {
            improvements.append("提升优先级，让常用技能更容易命中")
        }

        improvements.append(contentsOf: stats.improvementSuggestions)

        var deduped: [String] = []
        for improvement in improvements {
            if !deduped.contains(improvement) {
                deduped.append(improvement)
            }
        }
        return deduped
    }

    private func reason(for skill: Skill, stats: SkillUsageStats) -> String {
        if !stats.improvementSuggestions.isEmpty {
            return "\(skill.name) 已积累用户或系统给出的改进建议"
        }
        if stats.successRate < 0.7 {
            return "\(skill.name) 最近成功率偏低，需要提升稳定性和匹配率"
        }
        return "\(skill.name) 使用频率高且表现稳定，适合提升优先级"
    }

    private func evidence(for skill: Skill, stats: SkillUsageStats) -> [String] {
        [
            "总使用次数: \(stats.totalUses)",
            "成功次数: \(stats.successCount)",
            "失败次数: \(stats.failCount)",
            String(format: "成功率: %.0f%%", stats.successRate * 100),
            "当前版本: v\(skill.version)",
        ]
    }

    private func saveProposalIfNeeded(_ proposal: SkillEvolutionProposal) -> Bool {
        var proposals = self.loadProposals()
        if proposals.contains(where: {
            $0.skillId == proposal.skillId &&
            $0.currentVersion == proposal.currentVersion &&
            $0.improvements == proposal.improvements
        }) {
            return false
        }

        proposals.append(proposal)
        self.persistProposals(proposals)
        return true
    }

    private func removeProposal(id: String) {
        var proposals = self.loadProposals()
        proposals.removeAll { $0.id == id }
        self.persistProposals(proposals)
    }

    private func loadProposals() -> [SkillEvolutionProposal] {
        guard let data = self.defaults.data(forKey: self.proposalsKey),
              let proposals = try? JSONDecoder().decode([SkillEvolutionProposal].self, from: data) else {
            return []
        }
        return proposals
    }

    private func persistProposals(_ proposals: [SkillEvolutionProposal]) {
        if let data = try? JSONEncoder().encode(proposals) {
            self.defaults.set(data, forKey: self.proposalsKey)
        }
    }
}
