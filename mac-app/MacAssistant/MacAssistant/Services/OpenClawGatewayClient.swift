import Foundation
import CryptoKit
import OpenClawChatUI
import OpenClawKit
import OpenClawProtocol

/// Gateway 上下文注入结果
struct GatewayContextInjectionResult {
    let isSuccess: Bool
    let tokenCount: Int
    let injectionType: String
}

/// Gateway 执行上下文准备结果
struct PreparedExecutionContext {
    let systemPrompt: String?
    let userMessage: String
    let injectionResult: GatewayContextInjectionResult
}

actor OpenClawGatewayClient {
    static let shared = OpenClawGatewayClient()
    private static let gatewayAgentID = "desktop"
    private static let assistantUpdateMinimumInterval: TimeInterval = 0.25
    private static let assistantUpdateMinimumDelta = 80
    private static let sessionLabelMaxLength = 64

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

    nonisolated static func uniqueSessionLabel(base: String, uniqueSource: String) -> String {
        let trimmedBase = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBase.isEmpty else {
            return Self.sessionLabelSuffix(from: uniqueSource)
        }

        let suffix = Self.sessionLabelSuffix(from: uniqueSource)
        let separator = " #"
        let maxBaseLength = max(1, Self.sessionLabelMaxLength - separator.count - suffix.count)
        let normalizedBase = String(trimmedBase.prefix(maxBaseLength))
        return "\(normalizedBase)\(separator)\(suffix)"
    }

    func sendMessage(
        agent: Agent,
        sessionKey: String,
        sessionLabel: String? = nil,
        requestID: String,
        text: String,
        images: [String],
        systemPrompt: String? = nil,  // Phase 4: Accept system prompt
        contextBudget: Int = 2000,     // Phase 4: Token budget for memory
        onAssistantText: (@Sendable (String) async -> Void)? = nil
    ) async throws -> String {
        // MARK: - Memory System Hook (Phase 1: L0 Storage)
        let memoryStartTime = Date()
        let planId = Self.derivePlanId(from: sessionKey)
        
        // Phase 4: Prepare memory context injection
        var preparedPrompt = text
        var preparedSystemPrompt = systemPrompt
        var injectionResult: GatewayContextInjectionResult?
        
        if MemoryFeatureFlags.enableNewRetrieval {
            do {
                let injection = try await prepareMemoryContext(
                    planId: planId,
                    agent: agent,
                    userMessage: text,
                    systemPrompt: systemPrompt,
                    contextBudget: contextBudget
                )
                preparedPrompt = injection.userMessage
                preparedSystemPrompt = injection.systemPrompt
                injectionResult = injection.injectionResult
                
                if injection.injectionResult.isSuccess {
                    LogInfo("[OpenClaw] Injected \(injection.injectionResult.tokenCount) tokens of memory context")
                }
            } catch {
                LogWarning("[OpenClaw] Memory context injection failed: \(error)")
            }
        }
        
        let state = try await self.runtimeManager.ensureGatewayReadyWithDependencies()
        guard let modelRef = state.modelRefsByAgentID[agent.id] else {
            throw NSError(
                domain: "OpenClawGatewayClient",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "\(agent.displayName) 还没有映射到 OpenClaw runtime。"]
            )
        }

        let resolvedSessionKey = Self.canonicalSessionKey(sessionKey)

        let patchedSession = try await self.patchSession(
            key: resolvedSessionKey,
            modelRef: modelRef,
            label: sessionLabel
        )

        let attachments = try self.buildAttachments(from: images)
        
        // Phase 4: 整合系统提示词到用户消息（OpenClaw 协议不支持原生 systemPrompt）
        let finalPromptText: String
        if let sysPrompt = preparedSystemPrompt, !sysPrompt.isEmpty {
            finalPromptText = "【系统提示】\n\(sysPrompt)\n\n【用户请求】\n\(preparedPrompt)"
        } else {
            finalPromptText = preparedPrompt
        }
        
        let prompt = self.normalizedPrompt(finalPromptText, hasImages: !attachments.isEmpty)
        let startCursor = self.nextPushOrdinal
        let requestStartedAtMs = Date().timeIntervalSince1970 * 1000
        let allowRelaxedHistoryRecovery = agent.provider != .ollama
        let response = try await self.chatSend(
            sessionKey: resolvedSessionKey,
            message: prompt,
            attachments: attachments,
            requestID: requestID
        )

        var latestAssistantText = ""
        var lastAssistantUpdateAt: Date?
        var lastForwardedAssistantText = ""
        var lastForwardedAssistantTextAt = Date.distantPast
        var lastHistoryRecoveryAt = Date.distantPast
        var knownSessionID = patchedSession.sessionID
        if knownSessionID == nil {
            knownSessionID = await self.currentSessionID(for: resolvedSessionKey)
        }
        var cursor = startCursor
        let deadline = Date().addingTimeInterval(180)

        LogDebug(
            "OpenClaw send start agent=\(agent.id) sessionKey=\(resolvedSessionKey) " +
            "chatRunID=\(response.runId) sessionID=\(knownSessionID ?? "unknown") " +
            "requestID=\(requestID)"
        )

        while Date() < deadline {
            let batch = self.pushes(since: cursor)
            cursor = batch.nextCursor

            if batch.items.isEmpty {
                let now = Date()
                let requestAge = (now.timeIntervalSince1970 * 1000 - requestStartedAtMs) / 1000
                let assistantQuietInterval = lastAssistantUpdateAt.map { now.timeIntervalSince($0) } ?? .infinity
                let shouldAllowRelaxedIdleRecovery = allowRelaxedHistoryRecovery &&
                    (assistantQuietInterval >= 2 || requestAge >= 5)

                if now.timeIntervalSince(lastHistoryRecoveryAt) >= 3 {
                    lastHistoryRecoveryAt = now
                    if let recovery = await self.recoverAssistantText(
                        sessionKey: resolvedSessionKey,
                        requestStartedAtMs: requestStartedAtMs,
                        latestAssistantText: latestAssistantText,
                        requireCompletedHistory: !shouldAllowRelaxedIdleRecovery
                    ) {
                        knownSessionID = recovery.sessionID ?? knownSessionID
                        LogInfo(
                            "OpenClaw history recovery succeeded during idle wait " +
                            "agent=\(agent.id) sessionKey=\(resolvedSessionKey) " +
                            "requireCompletedHistory=\(!shouldAllowRelaxedIdleRecovery)"
                        )
                        return await self.finalizeAssistantResponse(
                            sessionKey: resolvedSessionKey,
                            sessionID: knownSessionID,
                            prompt: prompt,
                            assistantText: recovery.text,
                            requestStartedAtMs: requestStartedAtMs,
                            agent: agent,
                            durationMs: Int(Date().timeIntervalSince1970 * 1000 - requestStartedAtMs)
                        )
                    }
                }

                if let lastAssistantUpdateAt,
                   let currentAssistantText = self.normalizedNonEmptyText(latestAssistantText),
                   now.timeIntervalSince(lastAssistantUpdateAt) >= 2 {
                    if let recovery = await self.recoverAssistantText(
                        sessionKey: resolvedSessionKey,
                        requestStartedAtMs: requestStartedAtMs,
                        latestAssistantText: latestAssistantText,
                        requireCompletedHistory: !allowRelaxedHistoryRecovery
                    ) {
                        knownSessionID = recovery.sessionID ?? knownSessionID
                        LogInfo(
                            "OpenClaw finalized from trailing assistant stream " +
                            "agent=\(agent.id) sessionKey=\(resolvedSessionKey) " +
                            "requireCompletedHistory=\(!allowRelaxedHistoryRecovery)"
                        )
                        return await self.finalizeAssistantResponse(
                            sessionKey: resolvedSessionKey,
                            sessionID: knownSessionID,
                            prompt: prompt,
                            assistantText: recovery.text,
                            requestStartedAtMs: requestStartedAtMs,
                            agent: agent,
                            durationMs: Int(Date().timeIntervalSince1970 * 1000 - requestStartedAtMs)
                        )
                    }

                    LogInfo(
                        "OpenClaw returning buffered assistant text after quiet period " +
                        "agent=\(agent.id) sessionKey=\(resolvedSessionKey)"
                    )
                    return await self.finalizeAssistantResponse(
                        sessionKey: resolvedSessionKey,
                        sessionID: knownSessionID,
                        prompt: prompt,
                        assistantText: currentAssistantText,
                        requestStartedAtMs: requestStartedAtMs,
                        agent: agent,
                        durationMs: Int(Date().timeIntervalSince1970 * 1000 - requestStartedAtMs)
                    )
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
                            let payloadText = self.extractAssistantText(from: payload.message)
                            let history = payloadText == nil
                                ? (try? await self.chatHistory(sessionKey: resolvedSessionKey))
                                : nil
                            knownSessionID = self.normalizedSessionID(history?.sessionId) ?? knownSessionID
                            let historyText = history.flatMap {
                                self.extractLatestAssistantText(
                                    from: $0,
                                    newerThan: requestStartedAtMs
                                ) ?? self.extractLatestAssistantText(from: $0)
                            }
                            let bufferedText = self.normalizedNonEmptyText(latestAssistantText)
                            let finalText = payloadText ?? historyText ?? bufferedText
                            let resolvedFinalText = finalText ?? "服务已返回，但没有拿到可显示的内容。"
                            if let onAssistantText,
                               resolvedFinalText != lastForwardedAssistantText {
                                lastForwardedAssistantText = resolvedFinalText
                                lastForwardedAssistantTextAt = Date()
                                await onAssistantText(resolvedFinalText)
                            }
                            let finalSource: String
                            if payloadText != nil {
                                finalSource = "payload"
                            } else if historyText != nil {
                                finalSource = "history"
                            } else if bufferedText != nil {
                                finalSource = "buffer"
                            } else {
                                finalSource = "fallback"
                            }
                            LogInfo(
                                "OpenClaw chat.final received agent=\(agent.id) " +
                                "sessionKey=\(resolvedSessionKey) source=\(finalSource)"
                            )
                            return await self.finalizeAssistantResponse(
                                sessionKey: resolvedSessionKey,
                                sessionID: knownSessionID,
                                prompt: prompt,
                                assistantText: resolvedFinalText,
                                requestStartedAtMs: requestStartedAtMs,
                                agent: agent,
                                durationMs: Int(Date().timeIntervalSince1970 * 1000 - requestStartedAtMs)
                            )

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
            return await self.finalizeAssistantResponse(
                sessionKey: resolvedSessionKey,
                sessionID: knownSessionID,
                prompt: prompt,
                assistantText: recovery.text,
                requestStartedAtMs: requestStartedAtMs,
                agent: agent,
                durationMs: Int(Date().timeIntervalSince1970 * 1000 - requestStartedAtMs)
            )
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

    func injectAssistantMessage(
        sessionKey: String,
        message: String,
        label: String? = nil
    ) async throws {
        let normalizedMessage = self.normalizedPrompt(message, hasImages: false)
        try await self.chatInject(
            sessionKey: Self.canonicalSessionKey(sessionKey),
            message: normalizedMessage,
            label: label
        )
        Task {
            await MemoryRecallCoordinator.shared.noteTranscriptMutation(reason: "chat.inject")
        }
    }

    private func patchSession(
        key: String,
        modelRef: String,
        label: String? = nil
    ) async throws -> OpenClawPatchedSession {
        var params: [String: AnyCodable] = [
            "key": AnyCodable(key),
            "model": AnyCodable(modelRef),
        ]
        let normalizedLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedLabel, !normalizedLabel.isEmpty {
            params["label"] = AnyCodable(normalizedLabel)
        }

        do {
            let data = try await self.request(method: "sessions.patch", params: params, timeoutMs: 15000)
            return try self.decodePatchedSession(from: data)
        } catch let error as GatewayResponseError {
            guard error.code == "INVALID_REQUEST",
                  error.message.localizedCaseInsensitiveContains("label already in use"),
                  let normalizedLabel,
                  !normalizedLabel.isEmpty else {
                throw error
            }

            let fallbackLabel = Self.uniqueSessionLabel(base: normalizedLabel, uniqueSource: key)
            guard fallbackLabel != normalizedLabel else {
                throw error
            }

            LogWarning(
                "OpenClaw session label collision, retrying with unique label " +
                "sessionKey=\(key) originalLabel=\(normalizedLabel) fallbackLabel=\(fallbackLabel)"
            )
            params["label"] = AnyCodable(fallbackLabel)
            let data = try await self.request(method: "sessions.patch", params: params, timeoutMs: 15000)
            return try self.decodePatchedSession(from: data)
        }
    }

    private func decodePatchedSession(from data: Data) throws -> OpenClawPatchedSession {
        let payload = try self.decoder.decode(OpenClawSessionPatchResponse.self, from: data)
        return OpenClawPatchedSession(sessionID: self.normalizedSessionID(payload.entry?.sessionId))
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
        attachments: [OpenClawChatAttachmentPayload],
        requestID: String
    ) async throws -> OpenClawChatSendResponse {
        let idempotencyKey = self.deterministicIdempotencyKey(
            requestID: requestID,
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

    private func chatInject(
        sessionKey: String,
        message: String,
        label: String?
    ) async throws {
        var params: [String: AnyCodable] = [
            "sessionKey": AnyCodable(sessionKey),
            "message": AnyCodable(message),
        ]

        let normalizedLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedLabel, !normalizedLabel.isEmpty {
            params["label"] = AnyCodable(normalizedLabel)
        }

        _ = try await self.request(method: "chat.inject", params: params, timeoutMs: 15000)
    }

    private func deterministicIdempotencyKey(
        requestID: String,
        sessionKey: String,
        message: String,
        attachments: [OpenClawChatAttachmentPayload]
    ) -> String {
        let attachmentFingerprint = attachments
            .map { "\($0.fileName)|\($0.mimeType)|\($0.content.prefix(64))" }
            .joined(separator: "||")
        let normalizedRequestID = requestID.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = "\(normalizedRequestID)\n\(sessionKey)\n\(message)\n\(attachmentFingerprint)"
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
        guard let message = self.latestAssistantMessage(from: history, newerThan: minimumTimestamp) else {
            return nil
        }
        return self.normalizedAssistantText(from: message)
    }

    private func latestAssistantMessage(
        from history: OpenClawChatHistoryPayload,
        newerThan minimumTimestamp: Double? = nil
    ) -> OpenClawChatMessage? {
        self.latestChatMessage(
            role: "assistant",
            from: history,
            newerThan: minimumTimestamp,
            requireTextContent: true
        )
    }

    private func latestUserMessage(
        from history: OpenClawChatHistoryPayload,
        newerThan minimumTimestamp: Double? = nil
    ) -> OpenClawChatMessage? {
        self.latestChatMessage(
            role: "user",
            from: history,
            newerThan: minimumTimestamp,
            requireTextContent: false
        )
    }

    private func latestChatMessage(
        role: String,
        from history: OpenClawChatHistoryPayload,
        newerThan minimumTimestamp: Double? = nil,
        requireTextContent: Bool
    ) -> OpenClawChatMessage? {
        let messages = (history.messages ?? []).compactMap { payload in
            try? self.decodePayload(payload, as: OpenClawChatMessage.self)
        }

        for message in messages.reversed() where message.role.lowercased() == role {
            if let minimumTimestamp {
                guard let messageTimestamp = message.timestamp,
                      messageTimestamp >= minimumTimestamp else {
                    continue
                }
            }

            if !requireTextContent || self.normalizedAssistantText(from: message) != nil {
                return message
            }
        }

        return nil
    }

    private func isCompletedAssistantMessage(_ message: OpenClawChatMessage) -> Bool {
        guard let stopReason = self.normalizedNonEmptyText(message.stopReason) else {
            return false
        }
        return !stopReason.isEmpty
    }

    private func normalizedAssistantText(from message: OpenClawChatMessage) -> String? {
        self.normalizedNonEmptyText(
            message.content
                .compactMap(\.text)
                .joined(separator: "\n")
        )
    }

    private func extractAssistantText(from payload: AnyCodable?) -> String? {
        guard let payload else {
            return nil
        }

        if let message = try? self.decodePayload(payload, as: OpenClawChatMessage.self),
           let text = self.normalizedAssistantText(from: message) {
            return text
        }

        return self.extractAssistantText(fromValue: payload.value)
    }

    private func extractAssistantText(fromValue value: Any) -> String? {
        switch value {
        case let text as String:
            return self.normalizedNonEmptyText(text)

        case let dict as [String: AnyCodable]:
            if let text = dict["text"]?.value as? String,
               let normalized = self.normalizedNonEmptyText(text) {
                return normalized
            }

            if let message = dict["message"],
               let nested = self.extractAssistantText(from: message) {
                return nested
            }

            if let content = dict["content"],
               let nested = self.extractAssistantText(from: content) {
                return nested
            }

            return nil

        case let array as [AnyCodable]:
            let combined = array.compactMap { self.extractAssistantText(from: $0) }
                .joined(separator: "\n")
            return self.normalizedNonEmptyText(combined)

        default:
            return nil
        }
    }

    private func recoverAssistantText(
        sessionKey: String,
        requestStartedAtMs: Double,
        latestAssistantText: String,
        requireCompletedHistory: Bool = false
    ) async -> OpenClawRecoveredOutput? {
        if let history = try? await self.chatHistory(sessionKey: sessionKey) {
            let sessionID = self.normalizedSessionID(history.sessionId)
            if let latestMessage = self.latestAssistantMessage(
                from: history,
                newerThan: requestStartedAtMs
            ),
               let recoveredText = self.normalizedAssistantText(from: latestMessage),
               !requireCompletedHistory || self.isCompletedAssistantMessage(latestMessage) {
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

    private func finalizeAssistantResponse(
        sessionKey: String,
        sessionID: String?,
        prompt: String,
        assistantText: String,
        requestStartedAtMs: Double,
        agent: Agent? = nil,  // For memory system
        durationMs: Int? = nil  // For memory system
    ) async -> String {
        await self.ensureTranscriptContainsTurn(
            sessionKey: sessionKey,
            sessionID: sessionID,
            prompt: prompt,
            assistantText: assistantText,
            requestStartedAtMs: requestStartedAtMs
        )
        
        // MARK: - L0 Memory Storage (Phase 1) - 暂时禁用
        // 当 MemoryFeatureFlags.enableL0Storage = true 时启用
        
        Task {
            await MemoryRecallCoordinator.shared.noteTranscriptMutation(reason: "chat.finalize")
        }
        return assistantText
    }
    
    // MARK: - Phase 4: Memory Context Injection
    
    private func prepareMemoryContext(
        planId: String,
        agent: Agent,
        userMessage: String,
        systemPrompt: String?,
        contextBudget: Int
    ) async throws -> PreparedExecutionContext {
        // Phase 4: 集成 ConversationMemoryManager 进行记忆上下文注入
        let memoryManager = ConversationMemoryManager.shared
        
        let (enhancedText, enhancedSystemPrompt) = await memoryManager.prepareContextualPrompt(
            userMessage: userMessage,
            sessionID: planId,
            systemPrompt: systemPrompt
        )
        
        // 判断是否实际注入了上下文
        let hasContextInjected = enhancedText != userMessage || enhancedSystemPrompt != systemPrompt
        let injectionType = hasContextInjected ? "conversation_memory" : "none"
        let tokenCount = hasContextInjected ? estimateTokens(enhancedText) - estimateTokens(userMessage) : 0
        
        if hasContextInjected {
            LogInfo("[Memory] 注入上下文: \(tokenCount) tokens, session=\(planId)")
        }
        
        return PreparedExecutionContext(
            systemPrompt: enhancedSystemPrompt ?? systemPrompt,
            userMessage: enhancedText,
            injectionResult: GatewayContextInjectionResult(
                isSuccess: hasContextInjected,
                tokenCount: max(0, tokenCount),
                injectionType: injectionType
            )
        )
    }
    
    /// 估算 token 数（简化实现：每4个字符1个token）
    private func estimateTokens(_ text: String) -> Int {
        return text.count / 4
    }
    
    private static func derivePlanId(from sessionKey: String) -> String {
        // Extract plan ID from session key (e.g., "plan-xxx/task-yyy" -> "plan-xxx")
        sessionKey.components(separatedBy: "/").first ?? sessionKey
    }

    private func ensureTranscriptContainsTurn(
        sessionKey: String,
        sessionID: String?,
        prompt: String,
        assistantText: String,
        requestStartedAtMs: Double
    ) async {
        guard let normalizedPrompt = self.normalizedNonEmptyText(prompt),
              let normalizedAssistant = self.normalizedNonEmptyText(assistantText) else {
            return
        }

        let historyBeforeRepair = try? await self.chatHistory(sessionKey: sessionKey)
        if let historyBeforeRepair,
           self.latestAssistantMessage(from: historyBeforeRepair, newerThan: requestStartedAtMs) != nil {
            return
        }

        var injectedAssistant = false
        do {
            try await self.chatInject(
                sessionKey: sessionKey,
                message: normalizedAssistant,
                label: "Gateway Recovery"
            )
            injectedAssistant = true
        } catch {
            LogWarning(
                "OpenClaw transcript assistant inject failed " +
                "sessionKey=\(sessionKey) error=\(error.localizedDescription)"
            )
        }

        let historyAfterInject = try? await self.chatHistory(sessionKey: sessionKey)
        let assistantPresent = injectedAssistant || historyAfterInject
            .flatMap { self.latestAssistantMessage(from: $0, newerThan: requestStartedAtMs) } != nil
        let userPresent = historyAfterInject
            .flatMap { self.latestUserMessage(from: $0, newerThan: requestStartedAtMs) } != nil

        if assistantPresent && userPresent {
            return
        }

        var resolvedSessionID = self.normalizedSessionID(sessionID)
        if resolvedSessionID == nil {
            resolvedSessionID = self.normalizedSessionID(historyAfterInject?.sessionId)
        }
        if resolvedSessionID == nil {
            resolvedSessionID = await self.currentSessionID(for: sessionKey)
        }
        guard let resolvedSessionID else {
            return
        }

        do {
            try await self.backfillTranscriptTurn(
                sessionKey: sessionKey,
                sessionID: resolvedSessionID,
                prompt: normalizedPrompt,
                assistantText: normalizedAssistant,
                requestStartedAtMs: requestStartedAtMs,
                includeUser: !userPresent,
                includeAssistant: !assistantPresent
            )
            LogWarning(
                "OpenClaw transcript repaired after incomplete history " +
                "sessionKey=\(sessionKey) sessionID=\(resolvedSessionID) " +
                "missingUser=\(!userPresent) missingAssistant=\(!assistantPresent)"
            )
            Task {
                await MemoryRecallCoordinator.shared.noteTranscriptMutation(reason: "chat.repair")
            }
        } catch {
            LogWarning(
                "OpenClaw transcript repair failed " +
                "sessionKey=\(sessionKey) sessionID=\(resolvedSessionID) " +
                "error=\(error.localizedDescription)"
            )
        }
    }

    private func backfillTranscriptTurn(
        sessionKey: String,
        sessionID: String,
        prompt: String,
        assistantText: String,
        requestStartedAtMs: Double,
        includeUser: Bool,
        includeAssistant: Bool
    ) async throws {
        guard includeUser || includeAssistant else {
            return
        }

        let transcriptURL = try await self.transcriptURL(for: sessionKey, sessionID: sessionID)
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: transcriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if !fileManager.fileExists(atPath: transcriptURL.path) {
            let created = fileManager.createFile(
                atPath: transcriptURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
            guard created else {
                throw NSError(
                    domain: "OpenClawGatewayClient",
                    code: 7,
                    userInfo: [NSLocalizedDescriptionKey: "无法创建 OpenClaw transcript 文件。"]
                )
            }

            let header = await self.sessionHeaderRecord(
                sessionID: sessionID,
                timestampMs: requestStartedAtMs
            )
            try self.appendTranscriptLine(header, to: transcriptURL)
        }

        var parentID = try self.lastTranscriptRecordID(at: transcriptURL)
        var userRecordID: String?

        if includeUser {
            let appendedUserRecordID = Self.transcriptRecordID()
            try self.appendTranscriptLine(
                self.transcriptMessageRecord(
                    recordID: appendedUserRecordID,
                    parentID: parentID,
                    role: "user",
                    text: prompt,
                    timestampMs: requestStartedAtMs
                ),
                to: transcriptURL
            )
            userRecordID = appendedUserRecordID
            parentID = appendedUserRecordID
        }

        if includeAssistant {
            try self.appendTranscriptLine(
                self.transcriptMessageRecord(
                    recordID: Self.transcriptRecordID(),
                    parentID: userRecordID ?? parentID,
                    role: "assistant",
                    text: assistantText,
                    timestampMs: requestStartedAtMs,
                    isGatewayBackfill: true
                ),
                to: transcriptURL
            )
        }
    }

    private func transcriptURL(for sessionKey: String, sessionID: String) async throws -> URL {
        let canonicalSessionKey = Self.canonicalSessionKey(sessionKey)
        let components = canonicalSessionKey.split(separator: ":")
        let agentID = components.count >= 2 ? String(components[1]) : Self.gatewayAgentID
        let profileDirectory = await self.runtimeManager.profileDirectory()
        return profileDirectory
            .appendingPathComponent("agents", isDirectory: true)
            .appendingPathComponent(agentID, isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("\(sessionID).jsonl", isDirectory: false)
    }

    private func sessionHeaderRecord(sessionID: String, timestampMs: Double) async -> [String: Any] {
        let workspaceDirectory = await self.runtimeManager.workspaceDirectory()
        return [
            "type": "session",
            "version": 3,
            "id": sessionID,
            "timestamp": Self.isoTimestamp(fromMilliseconds: timestampMs),
            "cwd": workspaceDirectory.path,
        ]
    }

    private func transcriptMessageRecord(
        recordID: String,
        parentID: String?,
        role: String,
        text: String,
        timestampMs: Double,
        isGatewayBackfill: Bool = false
    ) -> [String: Any] {
        var message: [String: Any] = [
            "role": role,
            "content": [["type": "text", "text": text]],
            "timestamp": Int64(timestampMs.rounded()),
        ]

        if isGatewayBackfill {
            message["api"] = "openai-responses"
            message["provider"] = "openclaw"
            message["model"] = "gateway-backfill"
            message["stopReason"] = "stop"
            message["usage"] = [
                "input": 0,
                "output": 0,
                "cacheRead": 0,
                "cacheWrite": 0,
                "totalTokens": 0,
                "cost": [
                    "input": 0,
                    "output": 0,
                    "cacheRead": 0,
                    "cacheWrite": 0,
                    "total": 0,
                ],
            ]
        }

        var record: [String: Any] = [
            "type": "message",
            "id": recordID,
            "timestamp": Self.isoTimestamp(fromMilliseconds: timestampMs),
            "message": message,
        ]
        if let parentID {
            record["parentId"] = parentID
        }
        return record
    }

    private func appendTranscriptLine(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        handle.write(data)
        handle.write(Data([0x0A]))
    }

    private func lastTranscriptRecordID(at url: URL) throws -> String? {
        let raw = try String(contentsOf: url, encoding: .utf8)
        for line in raw.split(whereSeparator: \.isNewline).reversed() {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let recordID = object["id"] as? String,
                  !recordID.isEmpty else {
                continue
            }
            return recordID
        }
        return nil
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
        } catch let error as GatewayResponseError {
            guard !self.shouldSkipGatewayRestart(for: error) else {
                LogWarning(
                    "OpenClaw request failed without runtime restart " +
                    "method=\(method) code=\(error.code) message=\(error.message)"
                )
                throw error
            }
            return try await self.restartGatewayAndRetry(
                after: channel,
                method: method,
                params: params,
                timeoutMs: timeoutMs
            )
        } catch {
            return try await self.restartGatewayAndRetry(
                after: channel,
                method: method,
                params: params,
                timeoutMs: timeoutMs
            )
        }
    }

    private func restartGatewayAndRetry(
        after channel: GatewayChannelActor,
        method: String,
        params: [String: AnyCodable]?,
        timeoutMs: Double
    ) async throws -> Data {
        await channel.shutdown()
        self.channel = nil
        self.connectionGeneration = -1

        _ = try await self.runtimeManager.forceRestart()
        let retriedChannel = try await self.ensureChannel()
        return try await retriedChannel.request(method: method, params: params, timeoutMs: timeoutMs)
    }

    private func shouldSkipGatewayRestart(for error: GatewayResponseError) -> Bool {
        error.code == "INVALID_REQUEST"
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

    nonisolated private static func sessionLabelSuffix(from uniqueSource: String) -> String {
        let alphanumerics = uniqueSource.uppercased().filter { $0.isLetter || $0.isNumber }
        let suffix = String(alphanumerics.suffix(12))
        return suffix.isEmpty ? "SESSION" : suffix
    }

    nonisolated private static func transcriptRecordID() -> String {
        String(
            UUID().uuidString
                .replacingOccurrences(of: "-", with: "")
                .lowercased()
                .prefix(8)
        )
    }

    nonisolated private static func isoTimestamp(fromMilliseconds milliseconds: Double) -> String {
        ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: milliseconds / 1000))
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

struct OpenClawPatchedSession {
    let sessionID: String?
}

struct OpenClawSessionPatchResponse: Codable {
    let entry: OpenClawSessionPatchEntry?
}

struct OpenClawSessionPatchEntry: Codable {
    let sessionId: String?
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
