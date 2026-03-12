import Foundation

actor ResultCollector {
    static let shared = ResultCollector()

    struct SubtaskResult: Sendable {
        let title: String
        let content: String
    }

    private struct ParallelGroupState {
        let originalRequest: String
        var mainCompleted: Bool
        var subtaskResults: [SubtaskResult]
        var emittedSummary: Bool
    }

    private var groups: [String: ParallelGroupState] = [:]

    func startParallelGroup(originalRequest: String) -> String {
        let groupID = "parallel-\(UUID().uuidString.lowercased())"
        groups[groupID] = ParallelGroupState(
            originalRequest: originalRequest,
            mainCompleted: false,
            subtaskResults: [],
            emittedSummary: false
        )
        return groupID
    }

    func recordMainConversationCompleted(groupID: String) -> String? {
        guard var state = groups[groupID] else { return nil }
        state.mainCompleted = true
        let summary = buildSummaryIfReady(for: &state)
        groups[groupID] = state
        return summary
    }

    func recordSubtaskResult(groupID: String, title: String, content: String) -> String? {
        guard var state = groups[groupID] else { return nil }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        state.subtaskResults.append(SubtaskResult(title: title, content: trimmed))
        let summary = buildSummaryIfReady(for: &state)
        groups[groupID] = state
        return summary
    }

    private func buildSummaryIfReady(for state: inout ParallelGroupState) -> String? {
        guard state.mainCompleted,
              !state.subtaskResults.isEmpty,
              !state.emittedSummary else {
            return nil
        }

        state.emittedSummary = true
        let lines = state.subtaskResults.map { result in
            "• \(result.title)：\(compact(result.content))"
        }

        return """
        我补充完成了一轮并行研究，下面这些结果可以继续作为参考：

        \(lines.joined(separator: "\n"))
        """
    }

    private func compact(_ text: String) -> String {
        let flattened = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if flattened.count <= 220 {
            return flattened
        }

        return String(flattened.prefix(220)) + "..."
    }
}
