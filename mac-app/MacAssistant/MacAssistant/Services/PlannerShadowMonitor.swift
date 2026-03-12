//
//  PlannerShadowMonitor.swift
//  MacAssistant
//

import Foundation

struct PlannerShadowLogEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let createdAt: Date
    let requestPreview: String
    let primaryPlannerID: String
    let shadowPlannerID: String
    let primaryDecision: String
    let shadowDecision: String
    let primaryReason: String
    let shadowReason: String
    let matched: Bool

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        requestPreview: String,
        primaryPlannerID: String,
        shadowPlannerID: String,
        primaryDecision: String,
        shadowDecision: String,
        primaryReason: String,
        shadowReason: String,
        matched: Bool
    ) {
        self.id = id
        self.createdAt = createdAt
        self.requestPreview = requestPreview
        self.primaryPlannerID = primaryPlannerID
        self.shadowPlannerID = shadowPlannerID
        self.primaryDecision = primaryDecision
        self.shadowDecision = shadowDecision
        self.primaryReason = primaryReason
        self.shadowReason = shadowReason
        self.matched = matched
    }
}

@MainActor
final class PlannerShadowMonitor: ObservableObject {
    static let shared = PlannerShadowMonitor()

    @Published private(set) var entries: [PlannerShadowLogEntry] = []

    private let userDefaults = UserDefaults.standard
    private let storageKey = "macassistant.planner_shadow.entries.v1"
    private let maxEntries = 40

    private init() {
        load()
    }

    func record(primary: RequestPlan, shadow: RequestPlan) {
        let entry = PlannerShadowLogEntry(
            requestPreview: preview(for: primary.envelope.originalText),
            primaryPlannerID: primary.plannerID,
            shadowPlannerID: shadow.plannerID,
            primaryDecision: primary.summary,
            shadowDecision: shadow.summary,
            primaryReason: primary.reason,
            shadowReason: shadow.reason,
            matched: primary.comparisonSignature == shadow.comparisonSignature
        )

        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        persist()
    }

    func clear() {
        entries = []
        userDefaults.removeObject(forKey: storageKey)
    }

    private func preview(for text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 120 {
            return trimmed
        }
        return "\(trimmed.prefix(120))..."
    }

    private func load() {
        guard let data = userDefaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([PlannerShadowLogEntry].self, from: data) else {
            entries = []
            return
        }
        entries = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else {
            return
        }
        userDefaults.set(data, forKey: storageKey)
    }
}
