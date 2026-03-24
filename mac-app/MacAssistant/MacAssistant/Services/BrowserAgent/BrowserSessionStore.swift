//
//  BrowserSessionStore.swift
//  MacAssistant
//

import Foundation
import Combine

@MainActor
final class BrowserSessionStore: ObservableObject {
    static let shared = BrowserSessionStore()

    @Published private(set) var sessions: [BrowserSession] = []
    @Published private(set) var activeSessionID: String?

    private init() {}

    var activeSession: BrowserSession? {
        guard let activeSessionID else { return nil }
        return sessions.first { $0.id == activeSessionID }
    }

    @discardableResult
    func createSession(
        currentURL: String,
        runtimeKind: BrowserRuntimeKind = .systemBrowser
    ) -> BrowserSession {
        let session = BrowserSession(
            runtimeKind: runtimeKind,
            currentURL: currentURL,
            status: .idle
        )
        sessions.append(session)
        activeSessionID = session.id
        return session
    }

    func activateSession(_ sessionID: String) {
        guard sessions.contains(where: { $0.id == sessionID }) else { return }
        activeSessionID = sessionID
    }

    func session(id: String) -> BrowserSession? {
        sessions.first { $0.id == id }
    }

    func updateSession(_ sessionID: String, mutate: (inout BrowserSession) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        mutate(&sessions[index])
        refreshPlannerState(for: &sessions[index])
        sessions[index].updatedAt = Date()
    }

    func setSnapshot(_ snapshot: BrowserPageSnapshot, for sessionID: String) {
        updateSession(sessionID) { session in
            let newObservation = BrowserObservation(snapshot: snapshot)
            session.currentURL = snapshot.url
            session.latestSnapshot = snapshot
            session.previousObservation = session.latestObservation
            session.latestObservation = newObservation
            session.latestDelta = BrowserObservationDelta.make(
                previous: session.previousObservation,
                current: newObservation
            )
        }
    }

    func setScreenshotPath(_ screenshotPath: String, for sessionID: String) {
        updateSession(sessionID) { session in
            guard let snapshot = session.latestSnapshot else { return }
            let previousObservation = session.latestObservation
            let updatedSnapshot = BrowserPageSnapshot(
                title: snapshot.title,
                url: snapshot.url,
                textExcerpt: snapshot.textExcerpt,
                pageKind: snapshot.pageKind,
                authState: snapshot.authState,
                actionableElements: snapshot.actionableElements,
                screenshotPath: screenshotPath,
                capturedAt: Date()
            )
            session.latestSnapshot = updatedSnapshot
            session.previousObservation = previousObservation
            session.latestObservation = BrowserObservation(snapshot: updatedSnapshot)
            session.latestDelta = BrowserObservationDelta.make(
                previous: previousObservation,
                current: session.latestObservation!
            )
        }
    }

    func setStatus(_ status: BrowserSessionStatus, for sessionID: String) {
        updateSession(sessionID) { session in
            session.status = status
        }
    }

    func setPendingAction(_ action: BrowserPendingAction?, for sessionID: String) {
        updateSession(sessionID) { session in
            session.pendingAction = action
        }
    }

    func setLastUserGoal(_ goal: String?, for sessionID: String) {
        updateSession(sessionID) { session in
            session.lastUserGoal = goal
        }
    }

    func appendAction(summary: String, succeeded: Bool, for sessionID: String) {
        updateSession(sessionID) { session in
            session.recentActions.insert(
                BrowserSessionAction(summary: summary, succeeded: succeeded),
                at: 0
            )
            if session.recentActions.count > 20 {
                session.recentActions = Array(session.recentActions.prefix(20))
            }
        }
    }

    func clearPendingState(for sessionID: String) {
        updateSession(sessionID) { session in
            session.pendingAction = nil
            if session.status == .blockedByAuth || session.status == .waitingUser {
                session.status = .idle
            }
        }
    }

    func setPlannerState(
        for sessionID: String,
        mutate: (inout BrowserPlannerState) -> Void
    ) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        mutate(&sessions[index].plannerState)
        sessions[index].plannerState.lastUpdatedAt = Date()
        sessions[index].updatedAt = Date()
    }

    private func refreshPlannerState(for session: inout BrowserSession) {
        let observation = session.latestObservation
        let delta = session.latestDelta
        session.plannerState = BrowserPlannerState(
            pendingQuestion: session.pendingAction?.confirmationMessage,
            lastPlannerSummary: makePlannerSummary(for: session, observation: observation, delta: delta),
            suggestedNextSteps: suggestedNextSteps(for: session, observation: observation),
            lastUpdatedAt: Date()
        )
    }

    private func makePlannerSummary(
        for session: BrowserSession,
        observation: BrowserObservation?,
        delta: BrowserObservationDelta?
    ) -> String? {
        guard let observation else {
            return session.lastUserGoal.map { "当前网页目标：\($0)" }
        }

        if delta?.becameReady == true {
            return "页面刚从登录/阻塞态切换为可继续操作。"
        }
        if delta?.becameBlockedByAuth == true {
            return "页面重新进入登录或扫码阻塞态，需要先完成授权。"
        }

        switch observation.pageKind {
        case .chat:
            return observation.authState == .ready
                ? "当前是可操作的聊天页面，可以继续读取未读、搜索联系人或发送消息。"
                : "当前是聊天页面，但仍需先完成登录或扫码。"
        case .login:
            return "当前是登录页面，适合先完成账号输入、扫码或授权。"
        case .form:
            return "当前是表单页面，下一步通常是填写字段或点击提交。"
        default:
            return "当前页面已识别为 \(observation.pageKind.rawValue)，可以继续观察页面或执行下一步操作。"
        }
    }

    private func suggestedNextSteps(
        for session: BrowserSession,
        observation: BrowserObservation?
    ) -> [String] {
        if session.pendingAction != nil {
            return ["确认执行", "取消", "看看当前页面"]
        }

        guard let observation else {
            return ["看看当前页面", "告诉我下一步要做什么"]
        }

        if observation.authState == .needsLogin || observation.authState == .needsScan {
            return ["完成登录后告诉我“继续”", "看看当前页面", "取消当前挂起"]
        }

        if observation.looksLikeChatSurface {
            return ["读取未读消息", "搜索联系人 张三", "发送消息给 张三 你好"]
        }

        switch observation.pageKind {
        case .form, .login:
            return ["看看当前页面", "输入账号 foo@example.com", "点击登录"]
        default:
            return ["看看当前页面", "识别页面变化", "告诉我下一步要做什么"]
        }
    }
}
