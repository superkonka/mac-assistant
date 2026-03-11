import Foundation
import CryptoKit
import OpenClawChatUI
import OpenClawKit
import OpenClawProtocol

actor OpenClawGatewayClient {
    static let shared = OpenClawGatewayClient()
    private static let gatewayAgentID = "desktop"
    private static let assistantUpdateMinimumInterval: TimeInterval = 0.25
    private static let assistantUpdateMinimumDelta = 80

    private struct GatewayPushEnvelope {
        let ordinal: Int
        let push: GatewayPush
    }

    private let runtimeManager = OpenClawGatewayRuntimeManager.shared
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var channel: GatewayChannelActor?
    private var connectionGeneration = -1
    private var subscribers: [UUID: AsyncStream<GatewayPush>.Continuation] = [:]
    private var lastSnapshot: HelloOk?
    private var recentPushes: [GatewayPushEnvelope] = []
    private var nextPushOrdinal = 0

    func prepareGateway() async throws {
        _ = try await self.runtimeManager.ensureGatewayReadyWithDependencies()
        _ = try await self.ensureChannel()
    }

    func sendMessage(
        agent: Agent,
        sessionKey: String,
        sessionLabel: String? = nil,
        text: String,
        images: [String],
        onAssistantText: (@Sendable (String) async -> Void)? = nil
    ) async throws -> String {
        let state = try await self.runtimeManager.ensureGatewayReadyWithDependencies()
        guard let modelRef = state.modelRefsByAgentID[agent.id] else {
            throw NSError(
                domain: "OpenClawGatewayClient",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "\(agent.displayName) 还没有映射到 OpenClaw runtime。"]
            )
        }

        let resolvedSessionKey = Self.canonicalSessionKey(sessionKey)

        try await self.patchSession(
            key: resolvedSessionKey,
            modelRef: modelRef,
            label: sessionLabel
        )

        let attachments = try self.buildAttachments(from: images)
        let prompt = self.normalizedPrompt(text, hasImages: !attachments.isEmpty)
        let startCursor = self.nextPushOrdinal
        let requestStartedAtMs = Date().timeIntervalSince1970 * 1000
        let response = try await self.chatSend(
            sessionKey: resolvedSessionKey,
            message: prompt,
            attachments: attachments
        )

        var latestAssistantText = ""
        var lastAssistantUpdateAt: Date?
        var lastForwardedAssistantText = ""
        var lastForwardedAssistantTextAt = Date.distantPast
        var lastHistoryRecoveryAt = Date.distantPast
        var knownSessionID = await self.currentSessionID(for: resolvedSessionKey)
        var cursor = startCursor
        let deadline = Date().addingTimeInterval(180)

        LogDebug(
            "OpenClaw send start agent=\(agent.id) sessionKey=\(resolvedSessionKey) " +
            "chatRunID=\(response.runId) sessionID=\(knownSessionID ?? "unknown")"
        )

        while Date() < deadline {
            let batch = self.pushes(since: cursor)
            cursor = batch.nextCursor

            if batch.items.isEmpty {
                if Date().timeIntervalSince(lastHistoryRecoveryAt) >= 3 {
                    lastHistoryRecoveryAt = Date()
                    if let recovery = await self.recoverAssistantText(
                        sessionKey: resolvedSessionKey,
                        requestStartedAtMs: requestStartedAtMs,
                        latestAssistantText: latestAssistantText
                    ) {
                        knownSessionID = recovery.sessionID ?? knownSessionID
                        LogInfo(
                            "OpenClaw history recovery succeeded during idle wait " +
                            "agent=\(agent.id) sessionKey=\(resolvedSessionKey)"
                        )
                        return recovery.text
                    }
                }

                if let lastAssistantUpdateAt,
                   let currentAssistantText = self.normalizedNonEmptyText(latestAssistantText),
                   Date().timeIntervalSince(lastAssistantUpdateAt) >= 2 {
                    if let recovery = await self.recoverAssistantText(
                        sessionKey: resolvedSessionKey,
                        requestStartedAtMs: requestStartedAtMs,
                        latestAssistantText: latestAssistantText
                    ) {
                        knownSessionID = recovery.sessionID ?? knownSessionID
                        LogInfo(
                            "OpenClaw finalized from trailing assistant stream " +
                            "agent=\(agent.id) sessionKey=\(resolvedSessionKey)"
                        )
                        return recovery.text
                    }

                    LogInfo(
                        "OpenClaw returning buffered assistant text after quiet period " +
                        "agent=\(agent.id) sessionKey=\(resolvedSessionKey)"
                    )
                    return currentAssistantText
                }

                try await Task.sleep(nanoseconds: 300_000_000)
                continue
            }

            for envelope in batch.items {
                let push = envelope.push

                switch push {
                case let .event(event):
                    switch event.event {
                    case "agent":
                        guard let payload = try? self.decodePayload(event.payload, as: OpenClawAgentEventPayload.self),
                              self.matchesAgentRunID(
                                payload.runId,
                                chatRunID: response.runId,
                                sessionID: knownSessionID
                              ) else {
                            continue
                        }

                        if payload.stream == "assistant",
                           let text = payload.data["text"]?.value as? String,
                           let resolvedText = self.normalizedNonEmptyText(text) {
                            let now = Date()
                            latestAssistantText = resolvedText
                            lastAssistantUpdateAt = now
                            if let onAssistantText,
                               self.shouldForwardAssistantText(
                                resolvedText,
                                previous: lastForwardedAssistantText,
                                lastForwardedAt: lastForwardedAssistantTextAt,
                                now: now
                               ) {
                                lastForwardedAssistantText = resolvedText
                                lastForwardedAssistantTextAt = now
                                await onAssistantText(resolvedText)
                            }
                        }

                    case "chat":
                        guard let payload = try? self.decodePayload(event.payload, as: OpenClawChatEventPayload.self),
                              payload.runId == response.runId else {
                            continue
                        }
                        if let incomingSessionKey = payload.sessionKey,
                           !Self.matchesSessionKey(incoming: incomingSessionKey, current: resolvedSessionKey) {
                            continue
                        }

                        switch payload.state {
                        case "final":
                            let history = try await self.chatHistory(sessionKey: resolvedSessionKey)
                            knownSessionID = self.normalizedSessionID(history.sessionId) ?? knownSessionID
                            let finalText =
                                self.extractLatestAssistantText(
                                    from: history,
                                    newerThan: requestStartedAtMs
                                ) ??
                                self.normalizedNonEmptyText(latestAssistantText) ??
                                self.extractLatestAssistantText(from: history)
                            let resolvedFinalText = finalText ?? "服务已返回，但没有拿到可显示的内容。"
                            if let onAssistantText,
                               resolvedFinalText != lastForwardedAssistantText {
                                lastForwardedAssistantText = resolvedFinalText
                                lastForwardedAssistantTextAt = Date()
                                await onAssistantText(resolvedFinalText)
                            }
                            LogInfo(
                                "OpenClaw chat.final received agent=\(agent.id) " +
                                "sessionKey=\(resolvedSessionKey)"
                            )
                            return resolvedFinalText

                        case "error":
                            throw NSError(
                                domain: "OpenClawGatewayClient",
                                code: 3,
                                userInfo: [NSLocalizedDescriptionKey: payload.errorMessage ?? "OpenClaw 未能完成这次请求。"]
                            )

                        case "aborted":
                            throw NSError(
                                domain: "OpenClawGatewayClient",
                                code: 4,
                                userInfo: [NSLocalizedDescriptionKey: "这次 OpenClaw 会话被中止了。"]
                            )

                        default:
                            continue
                        }

                    default:
                        continue
                    }

                case .seqGap:
                    if let recovery = await self.recoverAssistantText(
                        sessionKey: resolvedSessionKey,
                        requestStartedAtMs: requestStartedAtMs,
                        latestAssistantText: latestAssistantText
                    ) {
                        knownSessionID = recovery.sessionID ?? knownSessionID
                        LogInfo(
                            "OpenClaw seqGap recovered from history/buffer " +
                            "agent=\(agent.id) sessionKey=\(resolvedSessionKey)"
                        )
                        return recovery.text
                    }

                case .snapshot:
                    continue
                }
            }
        }

        if let recovery = await self.recoverAssistantText(
            sessionKey: resolvedSessionKey,
            requestStartedAtMs: requestStartedAtMs,
            latestAssistantText: latestAssistantText
        ) {
            knownSessionID = recovery.sessionID ?? knownSessionID
            LogInfo(
                "OpenClaw recovered after deadline from history/buffer " +
                "agent=\(agent.id) sessionKey=\(resolvedSessionKey)"
            )
            return recovery.text
        }

        LogError(
            "OpenClaw stream ended without recoverable assistant output " +
            "agent=\(agent.id) sessionKey=\(resolvedSessionKey) " +
            "chatRunID=\(response.runId) sessionID=\(knownSessionID ?? "unknown")"
        )
        throw NSError(
            domain: "OpenClawGatewayClient",
            code: 5,
            userInfo: [NSLocalizedDescriptionKey: "OpenClaw 事件流意外结束。"]
        )
    }

    func skillsStatus() async throws -> OpenClawSkillsStatusReport {
        let data = try await self.request(method: "skills.status", params: [:], timeoutMs: 15000)
        return try self.decoder.decode(OpenClawSkillsStatusReport.self, from: data)
    }

    func recoverInterruptedTaskOutput(
        sessionKey: String,
        requestStartedAt: Date,
        latestAssistantText: String
    ) async -> OpenClawRecoveredOutput? {
        await self.recoverAssistantText(
            sessionKey: Self.canonicalSessionKey(sessionKey),
            requestStartedAtMs: requestStartedAt.timeIntervalSince1970 * 1000,
            latestAssistantText: latestAssistantText
        )
    }

    private func patchSession(
        key: String,
        modelRef: String,
        label: String? = nil
    ) async throws {
        var params: [String: AnyCodable] = [
            "key": AnyCodable(key),
            "model": AnyCodable(modelRef),
        ]
        if let label, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            params["label"] = AnyCodable(label)
        }
        _ = try await self.request(method: "sessions.patch", params: params, timeoutMs: 15000)
    }

    private func chatHistory(sessionKey: String) async throws -> OpenClawChatHistoryPayload {
        let data = try await self.request(
            method: "chat.history",
            params: ["sessionKey": AnyCodable(sessionKey)],
            timeoutMs: 15000
        )
        return try self.decoder.decode(OpenClawChatHistoryPayload.self, from: data)
    }

    private func chatSend(
        sessionKey: String,
        message: String,
        attachments: [OpenClawChatAttachmentPayload]
    ) async throws -> OpenClawChatSendResponse {
        let idempotencyKey = self.deterministicIdempotencyKey(
            sessionKey: sessionKey,
            message: message,
            attachments: attachments
        )
        var params: [String: AnyCodable] = [
            "sessionKey": AnyCodable(sessionKey),
            "message": AnyCodable(message),
            "thinking": AnyCodable("off"),
            "idempotencyKey": AnyCodable(idempotencyKey),
            "timeoutMs": AnyCodable(120000),
        ]

        if !attachments.isEmpty {
            params["attachments"] = AnyCodable(attachments.map { attachment in
                [
                    "type": attachment.type,
                    "mimeType": attachment.mimeType,
                    "fileName": attachment.fileName,
                    "content": attachment.content,
                ]
            })
        }

        let data = try await self.request(method: "chat.send", params: params, timeoutMs: 120000)
        return try self.decoder.decode(OpenClawChatSendResponse.self, from: data)
    }

    private func deterministicIdempotencyKey(
        sessionKey: String,
        message: String,
        attachments: [OpenClawChatAttachmentPayload]
    ) -> String {
        let attachmentFingerprint = attachments
            .map { "\($0.fileName)|\($0.mimeType)|\($0.content.prefix(64))" }
            .joined(separator: "||")
        let payload = "\(sessionKey)\n\(message)\n\(attachmentFingerprint)"
        let digest = SHA256.hash(data: Data(payload.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "macassistant-\(hex)"
    }

    private func buildAttachments(from imagePaths: [String]) throws -> [OpenClawChatAttachmentPayload] {
        try imagePaths.map { imagePath in
            let url = URL(fileURLWithPath: imagePath)
            let data = try Data(contentsOf: url)
            return OpenClawChatAttachmentPayload(
                type: "file",
                mimeType: self.mimeType(for: url),
                fileName: url.lastPathComponent,
                content: data.base64EncodedString()
            )
        }
    }

    private func normalizedPrompt(_ text: String, hasImages: Bool) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return hasImages ? "请分析这张图片。" : "你好"
    }

    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png":
            return "image/png"
        case "jpg", "jpeg":
            return "image/jpeg"
        case "gif":
            return "image/gif"
        case "webp":
            return "image/webp"
        case "bmp":
            return "image/bmp"
        case "tif", "tiff":
            return "image/tiff"
        default:
            return "application/octet-stream"
        }
    }

    private func extractLatestAssistantText(
        from history: OpenClawChatHistoryPayload,
        newerThan minimumTimestamp: Double? = nil
    ) -> String? {
        let messages = (history.messages ?? []).compactMap { payload in
            try? self.decodePayload(payload, as: OpenClawChatMessage.self)
        }

        for message in messages.reversed() where message.role.lowercased() == "assistant" {
            if let minimumTimestamp {
                guard let messageTimestamp = message.timestamp,
                      messageTimestamp >= minimumTimestamp else {
                    continue
                }
            }

            if let text = self.normalizedAssistantText(from: message) {
                return text
            }
        }

        return nil
    }

    private func normalizedAssistantText(from message: OpenClawChatMessage) -> String? {
        self.normalizedNonEmptyText(
            message.content
                .compactMap(\.text)
                .joined(separator: "\n")
        )
    }

    private func recoverAssistantText(
        sessionKey: String,
        requestStartedAtMs: Double,
        latestAssistantText: String
    ) async -> OpenClawRecoveredOutput? {
        if let history = try? await self.chatHistory(sessionKey: sessionKey) {
            let sessionID = self.normalizedSessionID(history.sessionId)
            if let recoveredText = self.extractLatestAssistantText(
                from: history,
                newerThan: requestStartedAtMs
            ) {
                return OpenClawRecoveredOutput(text: recoveredText, sessionID: sessionID, source: .history)
            }
            if let bufferedText = self.normalizedNonEmptyText(latestAssistantText) {
                return OpenClawRecoveredOutput(text: bufferedText, sessionID: sessionID, source: .buffer)
            }
            return nil
        }

        if let bufferedText = self.normalizedNonEmptyText(latestAssistantText) {
            return OpenClawRecoveredOutput(text: bufferedText, sessionID: nil, source: .buffer)
        }

        return nil
    }

    private func currentSessionID(for sessionKey: String) async -> String? {
        guard let history = try? await self.chatHistory(sessionKey: sessionKey) else {
            return nil
        }
        return self.normalizedSessionID(history.sessionId)
    }

    private func matchesAgentRunID(_ agentRunID: String, chatRunID: String, sessionID: String?) -> Bool {
        if agentRunID == chatRunID {
            return true
        }
        if let sessionID, agentRunID == sessionID {
            return true
        }
        return false
    }

    private func normalizedSessionID(_ value: String?) -> String? {
        self.normalizedNonEmptyText(value)
    }

    private func normalizedNonEmptyText(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func decodePayload<T: Decodable>(_ payload: AnyCodable?, as type: T.Type) throws -> T {
        guard let payload else {
            throw NSError(
                domain: "OpenClawGatewayClient",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "OpenClaw 返回了空 payload。"]
            )
        }
        let data = try self.encoder.encode(payload)
        return try self.decoder.decode(type, from: data)
    }

    private static func matchesSessionKey(incoming: String, current: String) -> Bool {
        Self.canonicalSessionKey(incoming) == Self.canonicalSessionKey(current)
    }

    private static func canonicalSessionKey(_ sessionKey: String) -> String {
        let trimmed = sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.lowercased() == "main" {
            return "agent:\(Self.gatewayAgentID):main"
        }
        if trimmed.lowercased().hasPrefix("agent:") {
            return trimmed.lowercased()
        }
        return "agent:\(Self.gatewayAgentID):\(trimmed.lowercased())"
    }

    private func shouldForwardAssistantText(
        _ text: String,
        previous: String,
        lastForwardedAt: Date,
        now: Date
    ) -> Bool {
        guard text != previous else {
            return false
        }

        if previous.isEmpty {
            return true
        }

        if now.timeIntervalSince(lastForwardedAt) >= Self.assistantUpdateMinimumInterval {
            return true
        }

        return abs(text.count - previous.count) >= Self.assistantUpdateMinimumDelta
    }

    private func request(
        method: String,
        params: [String: AnyCodable]?,
        timeoutMs: Double
    ) async throws -> Data {
        let channel = try await self.ensureChannel()

        do {
            return try await channel.request(method: method, params: params, timeoutMs: timeoutMs)
        } catch {
            await channel.shutdown()
            self.channel = nil
            self.connectionGeneration = -1

            _ = try await self.runtimeManager.forceRestart()
            let retriedChannel = try await self.ensureChannel()
            return try await retriedChannel.request(method: method, params: params, timeoutMs: timeoutMs)
        }
    }

    private func ensureChannel() async throws -> GatewayChannelActor {
        let state = try await self.runtimeManager.ensureGatewayReadyWithDependencies()
        if let channel, self.connectionGeneration == state.endpoint.generation {
            return channel
        }

        if let channel {
            await channel.shutdown()
        }

        let channel = GatewayChannelActor(
            url: state.endpoint.url,
            token: nil,
            password: nil,
            pushHandler: { [weak self] push in
                await self?.handle(push: push)
            }
        )
        self.channel = channel
        self.connectionGeneration = state.endpoint.generation
        return channel
    }

    private func subscribe(bufferingNewest: Int = 100) -> AsyncStream<GatewayPush> {
        let id = UUID()
        let snapshot = self.lastSnapshot
        let service = self

        return AsyncStream(bufferingPolicy: .bufferingNewest(bufferingNewest)) { continuation in
            if let snapshot {
                continuation.yield(.snapshot(snapshot))
            }

            self.subscribers[id] = continuation
            continuation.onTermination = { @Sendable _ in
                Task { await service.removeSubscriber(id) }
            }
        }
    }

    private func handle(push: GatewayPush) {
        if case let .snapshot(snapshot) = push {
            self.lastSnapshot = snapshot
        }

        self.recentPushes.append(GatewayPushEnvelope(ordinal: self.nextPushOrdinal, push: push))
        self.nextPushOrdinal += 1
        if self.recentPushes.count > 2000 {
            self.recentPushes.removeFirst(self.recentPushes.count - 2000)
        }

        for continuation in self.subscribers.values {
            continuation.yield(push)
        }
    }

    private func pushes(since ordinal: Int) -> (items: [GatewayPushEnvelope], nextCursor: Int) {
        let items = self.recentPushes.filter { $0.ordinal >= ordinal }
        return (items, self.nextPushOrdinal)
    }

    private func removeSubscriber(_ id: UUID) {
        self.subscribers[id] = nil
    }
}

struct OpenClawSkillsStatusReport: Codable {
    let workspaceDir: String
    let managedSkillsDir: String
    let skills: [OpenClawSkillStatus]
}

struct OpenClawRecoveredOutput {
    enum Source {
        case history
        case buffer
    }

    let text: String
    let sessionID: String?
    let source: Source
}

struct OpenClawSkillStatus: Codable {
    let name: String
    let description: String
    let eligible: Bool
    let disabled: Bool
    let missing: OpenClawSkillMissing
}

struct OpenClawSkillMissing: Codable {
    let bins: [String]
    let env: [String]
    let config: [String]
}
