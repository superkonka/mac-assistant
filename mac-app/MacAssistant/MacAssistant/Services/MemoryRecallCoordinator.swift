//
//  MemoryRecallCoordinator.swift
//  MacAssistant
//

import Foundation

struct ConversationRecallTurn: Sendable {
    let role: String
    let content: String
}

struct MemoryRecallPrelude: Sendable {
    let message: String
    let query: String
    let hitCount: Int
    let forcedReindex: Bool
}

actor MemoryRecallCoordinator {
    static let shared = MemoryRecallCoordinator()

    private struct SearchPayload: Decodable {
        let results: [SearchHit]
    }

    private struct SearchHit: Decodable {
        let score: Double
        let path: String
        let startLine: Int
        let endLine: Int
        let snippet: String
    }

    private struct StatusEntry: Decodable {
        let agentId: String
        let status: StatusPayload
        let scan: ScanPayload?
    }

    private struct StatusPayload: Decodable {
        let files: Int?
        let chunks: Int?
        let dirty: Bool?
        let sources: [String]?
    }

    private struct ScanPayload: Decodable {
        let totalFiles: Int?
    }

    private struct CommandResult: Sendable {
        let status: Int32
        let output: String
    }

    private let runtimeManager = OpenClawGatewayRuntimeManager.shared
    private let agentID = "desktop"
    private let minUsefulScore = 0.08
    private let maxPreludeHits = 4
    private let reindexCooldown: TimeInterval = 15

    private var lastIndexAttemptAt = Date.distantPast

    func recallPreludeIfNeeded(
        text: String,
        turns: [ConversationRecallTurn]
    ) async -> MemoryRecallPrelude? {
        let normalizedText = self.normalizedText(text)
        guard Self.isMemorySensitive(normalizedText) else {
            return nil
        }

        let query = self.searchQuery(for: normalizedText, turns: turns)

        do {
            var hits = try await self.search(query: query)
            var forcedReindex = false

            if hits.isEmpty, try await self.needsReindex() {
                forcedReindex = try await self.forceReindexIfAllowed(reason: "prelude:\(normalizedText)")
                if forcedReindex {
                    hits = try await self.search(query: query)
                }
            }

            let usefulHits = self.usefulHits(from: hits)
            guard !usefulHits.isEmpty else {
                LogInfo(
                    "Memory recall found no useful match " +
                    "queryLength=\(query.count) forcedReindex=\(forcedReindex)"
                )
                return nil
            }

            LogInfo(
                "Memory recall prepared prelude " +
                "queryLength=\(query.count) hits=\(usefulHits.count) forcedReindex=\(forcedReindex)"
            )

            return MemoryRecallPrelude(
                message: self.composePreludeMessage(from: usefulHits),
                query: query,
                hitCount: usefulHits.count,
                forcedReindex: forcedReindex
            )
        } catch {
            LogWarning(
                "Memory recall failed before main conversation " +
                "queryLength=\(query.count) error=\(error.localizedDescription)"
            )
            return nil
        }
    }

    func noteTranscriptMutation(reason: String) async {
        do {
            guard try await self.needsReindex() else {
                return
            }
            _ = try await self.forceReindexIfAllowed(reason: reason)
        } catch {
            LogWarning(
                "Memory transcript refresh skipped " +
                "reason=\(reason) error=\(error.localizedDescription)"
            )
        }
    }

    nonisolated static func isMemorySensitive(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !normalized.isEmpty else {
            return false
        }

        let directSignals = [
            "记得", "还记得", "记忆", "回忆", "聊过", "说过", "上次", "之前", "刚才", "刚刚",
            "前面", "接着", "接上", "继续刚才", "我叫什么", "我的名字", "我是谁", "偏好", "习惯",
            "待办", "todo", "open loop", "上一步", "刚刚那个", "remember", "recall", "earlier",
            "previous", "before", "we discussed", "you said", "my name", "preference", "todo",
            "what did we", "what did i"
        ]

        if directSignals.contains(where: { normalized.contains($0) }) {
            return true
        }

        let followUpSignals = ["那个", "那次", "那件事", "上面", "前面那个", "刚那条", "that one", "that", "it"]
        let followUpQuestionSignals = ["多少", "哪个", "什么", "where", "what", "which", "how much"]
        return followUpSignals.contains(where: { normalized.contains($0) }) &&
            followUpQuestionSignals.contains(where: { normalized.contains($0) })
    }

    private func searchQuery(for text: String, turns: [ConversationRecallTurn]) -> String {
        let baseQuery = String(text.prefix(320))
        var parts = [baseQuery]

        let needsExpansion = text.count <= 48 || ["刚才", "刚刚", "前面", "上面", "那个", "that", "it"]
            .contains(where: { text.lowercased().contains($0) })

        guard needsExpansion else {
            return baseQuery
        }

        let recentTurns = turns
            .reversed()
            .filter { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .filter { !$0.role.lowercased().contains("system") }
            .prefix(4)
            .map { String(self.normalizedText($0.content).prefix(180)) }
            .filter { !$0.isEmpty && $0 != baseQuery }
            .reversed()

        parts.append(contentsOf: recentTurns.map { "上下文: \($0)" })
        return parts.joined(separator: "\n")
    }

    private func composePreludeMessage(from hits: [SearchHit]) -> String {
        let lines = hits.enumerated().map { index, hit in
            "\(index + 1). \(self.cleanSnippet(hit.snippet))"
        }

        return """
        [Internal Recall Context]
        供下一轮回答参考的持久记忆命中如下。仅在与当前问题直接相关时使用；不要提及检索过程、路径、文件名或内部上下文。
        \(lines.joined(separator: "\n"))
        """
    }

    private func usefulHits(from hits: [SearchHit]) -> [SearchHit] {
        let filtered = hits.filter { $0.score >= self.minUsefulScore }
        let source = filtered.isEmpty ? Array(hits.prefix(2)) : filtered

        var seen = Set<String>()
        var result: [SearchHit] = []

        for hit in source {
            let snippet = self.cleanSnippet(hit.snippet)
            guard !snippet.isEmpty else { continue }
            let dedupeKey = "\(hit.path)#\(hit.startLine)#\(snippet)"
            guard seen.insert(dedupeKey).inserted else { continue }
            result.append(hit)
            if result.count >= self.maxPreludeHits {
                break
            }
        }

        return result
    }

    private func cleanSnippet(_ snippet: String) -> String {
        let collapsed = snippet
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > 220 else {
            return collapsed
        }
        return String(collapsed.prefix(220)) + "..."
    }

    private func normalizedText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func search(query: String) async throws -> [SearchHit] {
        let output = try await self.runOpenClaw(arguments: [
            "--profile", try await self.profileName(),
            "memory", "search",
            "--json",
            "--agent", self.agentID,
            "--max-results", "6",
            "--query", query,
        ])

        guard output.status == 0 else {
            throw NSError(
                domain: "MemoryRecallCoordinator",
                code: Int(output.status),
                userInfo: [NSLocalizedDescriptionKey: output.output]
            )
        }

        let data = Data(output.output.utf8)
        return try JSONDecoder().decode(SearchPayload.self, from: data).results
    }

    private func loadStatus() async throws -> [StatusEntry] {
        let output = try await self.runOpenClaw(arguments: [
            "--profile", try await self.profileName(),
            "memory", "status",
            "--json",
            "--agent", self.agentID,
        ])

        guard output.status == 0 else {
            throw NSError(
                domain: "MemoryRecallCoordinator",
                code: Int(output.status),
                userInfo: [NSLocalizedDescriptionKey: output.output]
            )
        }

        let data = Data(output.output.utf8)
        if let entries = try? JSONDecoder().decode([StatusEntry].self, from: data) {
            return entries
        }
        return [try JSONDecoder().decode(StatusEntry.self, from: data)]
    }

    private func needsReindex() async throws -> Bool {
        guard let entry = try await self.loadStatus().first(where: { $0.agentId == self.agentID }) else {
            return false
        }

        let files = entry.status.files ?? 0
        let chunks = entry.status.chunks ?? 0
        let totalFiles = entry.scan?.totalFiles ?? 0
        return entry.status.dirty == true || (totalFiles > 0 && (files == 0 || chunks == 0))
    }

    private func forceReindexIfAllowed(reason: String) async throws -> Bool {
        let now = Date()
        guard now.timeIntervalSince(self.lastIndexAttemptAt) >= self.reindexCooldown else {
            return false
        }

        self.lastIndexAttemptAt = now
        let output = try await self.runOpenClaw(arguments: [
            "--profile", try await self.profileName(),
            "memory", "index",
            "--agent", self.agentID,
            "--force",
        ])

        if output.status != 0 {
            throw NSError(
                domain: "MemoryRecallCoordinator",
                code: Int(output.status),
                userInfo: [NSLocalizedDescriptionKey: output.output]
            )
        }

        LogInfo("Memory index refresh completed reason=\(reason)")
        return true
    }

    private func runOpenClaw(arguments: [String]) async throws -> CommandResult {
        _ = try await self.runtimeManager.ensureGatewayReadyWithDependencies()
        let executablePath = await self.runtimeManager.currentExecutablePath()
        let environment = await self.runtimeManager.currentProcessEnvironment()

        return try await Task.detached(priority: .utility) {
            let process = Process()
            let pipe = Pipe()

            if let executablePath,
               executablePath.hasSuffix("/openclaw"),
               FileManager.default.isExecutableFile(atPath: executablePath) {
                process.executableURL = URL(fileURLWithPath: executablePath)
                process.arguments = arguments
            } else {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = ["openclaw"] + arguments
            }

            process.environment = environment
            process.standardOutput = pipe
            process.standardError = pipe

            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return CommandResult(status: process.terminationStatus, output: output)
        }.value
    }

    private func profileName() async throws -> String {
        let profile = await self.runtimeManager.currentProfileName()
        guard !profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(
                domain: "MemoryRecallCoordinator",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "OpenClaw profile is unavailable."]
            )
        }
        return profile
    }
}
