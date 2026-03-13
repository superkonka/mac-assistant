//
//  ClawRuntimeAdapter.swift
//  MacAssistant
//

import Foundation

protocol ClawRuntimeAdapter: Actor {
    func sendMessage(
        agent: Agent,
        sessionKey: String,
        sessionLabel: String?,
        requestID: String,
        text: String,
        images: [String],
        onAssistantText: (@Sendable (String) async -> Void)?
    ) async throws -> String

    func skillsStatus() async throws -> OpenClawSkillsStatusReport

    func recoverInterruptedTaskOutput(
        sessionKey: String,
        requestStartedAt: Date,
        latestAssistantText: String
    ) async -> OpenClawRecoveredOutput?

    func injectAssistantMessage(
        sessionKey: String,
        message: String,
        label: String?
    ) async throws
}

actor OpenClawRuntimeAdapter: ClawRuntimeAdapter {
    static let shared = OpenClawRuntimeAdapter()

    private let gatewayClient: OpenClawGatewayClient

    init(gatewayClient: OpenClawGatewayClient = .shared) {
        self.gatewayClient = gatewayClient
    }

    func sendMessage(
        agent: Agent,
        sessionKey: String,
        sessionLabel: String?,
        requestID: String,
        text: String,
        images: [String],
        onAssistantText: (@Sendable (String) async -> Void)?
    ) async throws -> String {
        try await gatewayClient.sendMessage(
            agent: agent,
            sessionKey: sessionKey,
            sessionLabel: sessionLabel,
            requestID: requestID,
            text: text,
            images: images,
            onAssistantText: onAssistantText
        )
    }

    func skillsStatus() async throws -> OpenClawSkillsStatusReport {
        try await gatewayClient.skillsStatus()
    }

    func recoverInterruptedTaskOutput(
        sessionKey: String,
        requestStartedAt: Date,
        latestAssistantText: String
    ) async -> OpenClawRecoveredOutput? {
        await gatewayClient.recoverInterruptedTaskOutput(
            sessionKey: sessionKey,
            requestStartedAt: requestStartedAt,
            latestAssistantText: latestAssistantText
        )
    }

    func injectAssistantMessage(
        sessionKey: String,
        message: String,
        label: String? = nil
    ) async throws {
        try await gatewayClient.injectAssistantMessage(
            sessionKey: sessionKey,
            message: message,
            label: label
        )
    }
}
