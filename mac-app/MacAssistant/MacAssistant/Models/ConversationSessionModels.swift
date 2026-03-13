//
//  ConversationSessionModels.swift
//  MacAssistant
//

import Foundation

struct ConversationSessionTopology: Equatable {
    let conversationID: String
    let mainSessionKey: String
    let mainSessionLabel: String
    let shadowSessionKey: String
    let shadowSessionLabel: String

    func taskSessionKey(for taskSessionID: String) -> String {
        let suffix = Self.sanitizedComponent(taskSessionID)
            .replacingOccurrences(of: "task-", with: "")
        return "conversation:\(conversationID):task:\(suffix)"
    }

    private static func sanitizedComponent(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        let lowered = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = lowered.unicodeScalars.map { scalar -> String in
            allowed.contains(scalar) ? String(scalar) : "-"
        }
        .joined()
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return normalized.isEmpty ? "conversation" : normalized
    }
}

final class ConversationControlStore {
    static let shared = ConversationControlStore()

    private let defaults: UserDefaults
    private let storageKey = "macassistant.conversation.active_id.v1"
    private let queue = DispatchQueue(label: "macassistant.conversation.control")
    private var topology: ConversationSessionTopology

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let conversationID = defaults.string(forKey: storageKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedID = conversationID?.isEmpty == false
            ? conversationID!
            : Self.makeConversationID()
        let topology = Self.makeTopology(conversationID: resolvedID)

        self.topology = topology
        defaults.set(topology.conversationID, forKey: storageKey)
    }

    func currentTopology() -> ConversationSessionTopology {
        queue.sync { topology }
    }

    @discardableResult
    func resetConversation() -> ConversationSessionTopology {
        queue.sync {
            let nextTopology = Self.makeTopology(conversationID: Self.makeConversationID())
            topology = nextTopology
            defaults.set(nextTopology.conversationID, forKey: storageKey)
            return nextTopology
        }
    }

    private static func makeConversationID() -> String {
        UUID().uuidString.lowercased()
    }

    private static func makeTopology(conversationID: String) -> ConversationSessionTopology {
        let normalizedID = conversationID
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return ConversationSessionTopology(
            conversationID: normalizedID,
            mainSessionKey: "conversation:\(normalizedID):main",
            mainSessionLabel: "Main Conversation",
            shadowSessionKey: "conversation:\(normalizedID):shadow",
            shadowSessionLabel: "Shadow Supervisor"
        )
    }
}
