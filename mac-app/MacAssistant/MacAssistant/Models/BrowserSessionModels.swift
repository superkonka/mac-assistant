//
//  BrowserSessionModels.swift
//  MacAssistant
//

import Foundation

enum BrowserRuntimeKind: String, Equatable {
    case systemBrowser
    case playwright

    var displayName: String {
        switch self {
        case .systemBrowser:
            return "系统浏览器"
        case .playwright:
            return "Playwright"
        }
    }
}

enum BrowserSessionStatus: String, Equatable {
    case idle
    case navigating
    case waitingUser
    case executing
    case blockedByAuth
    case completed
    case failed
}

enum BrowserPageKind: String, Equatable {
    case login
    case dashboard
    case search
    case form
    case article
    case list
    case checkout
    case chat
    case unknown
}

enum BrowserAuthState: String, Equatable {
    case unknown
    case needsLogin
    case needsScan
    case ready
}

struct BrowserElementCandidate: Equatable {
    let label: String
    let role: String
}

struct BrowserPageSnapshot: Equatable {
    let title: String
    let url: String
    let textExcerpt: String
    let pageKind: BrowserPageKind
    let authState: BrowserAuthState
    let actionableElements: [BrowserElementCandidate]
    let screenshotPath: String?
    let capturedAt: Date
}

struct BrowserObservation: Equatable {
    let title: String
    let url: String
    let textExcerpt: String
    let pageKind: BrowserPageKind
    let authState: BrowserAuthState
    let actionableElements: [BrowserElementCandidate]
    let screenshotPath: String?
    let observedAt: Date

    init(snapshot: BrowserPageSnapshot) {
        self.title = snapshot.title
        self.url = snapshot.url
        self.textExcerpt = snapshot.textExcerpt
        self.pageKind = snapshot.pageKind
        self.authState = snapshot.authState
        self.actionableElements = snapshot.actionableElements
        self.screenshotPath = snapshot.screenshotPath
        self.observedAt = snapshot.capturedAt
    }

    var looksLikeChatSurface: Bool {
        let lowercasedURL = url.lowercased()
        let lowercasedTitle = title.lowercased()
        return pageKind == .chat ||
            lowercasedURL.contains("whatsapp") ||
            lowercasedURL.contains("telegram") ||
            lowercasedURL.contains("discord") ||
            lowercasedURL.contains("slack") ||
            lowercasedTitle.contains("whatsapp") ||
            lowercasedTitle.contains("telegram") ||
            lowercasedTitle.contains("discord") ||
            lowercasedTitle.contains("slack")
    }
}

struct BrowserObservationDelta: Equatable {
    let observedAt: Date
    let urlChanged: Bool
    let titleChanged: Bool
    let pageKindChanged: Bool
    let authStateChanged: Bool
    let actionableElementsChanged: Bool
    let textChanged: Bool
    let becameReady: Bool
    let becameBlockedByAuth: Bool

    var hasMeaningfulChange: Bool {
        urlChanged || titleChanged || pageKindChanged || authStateChanged || actionableElementsChanged || textChanged
    }

    static func make(previous: BrowserObservation?, current: BrowserObservation) -> BrowserObservationDelta? {
        guard let previous else { return nil }
        return BrowserObservationDelta(
            observedAt: current.observedAt,
            urlChanged: previous.url != current.url,
            titleChanged: previous.title != current.title,
            pageKindChanged: previous.pageKind != current.pageKind,
            authStateChanged: previous.authState != current.authState,
            actionableElementsChanged: previous.actionableElements != current.actionableElements,
            textChanged: previous.textExcerpt != current.textExcerpt,
            becameReady: previous.authState != .ready && current.authState == .ready,
            becameBlockedByAuth: previous.authState == .ready &&
                (current.authState == .needsLogin || current.authState == .needsScan)
        )
    }
}

struct BrowserPlannerState: Equatable {
    var pendingQuestion: String?
    var lastPlannerSummary: String?
    var suggestedNextSteps: [String]
    var lastUpdatedAt: Date

    init(
        pendingQuestion: String? = nil,
        lastPlannerSummary: String? = nil,
        suggestedNextSteps: [String] = [],
        lastUpdatedAt: Date = Date()
    ) {
        self.pendingQuestion = pendingQuestion
        self.lastPlannerSummary = lastPlannerSummary
        self.suggestedNextSteps = suggestedNextSteps
        self.lastUpdatedAt = lastUpdatedAt
    }
}

struct BrowserPendingAction: Equatable {
    let actionType: String
    let selector: String?
    let value: String?
    let buttonText: String?
    let summary: String
    let confirmationMessage: String
}

struct BrowserSessionAction: Equatable, Identifiable {
    let id: UUID
    let createdAt: Date
    let summary: String
    let succeeded: Bool

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        summary: String,
        succeeded: Bool
    ) {
        self.id = id
        self.createdAt = createdAt
        self.summary = summary
        self.succeeded = succeeded
    }
}

struct BrowserSession: Equatable, Identifiable {
    let id: String
    let runtimeKind: BrowserRuntimeKind
    let createdAt: Date
    var updatedAt: Date
    var currentURL: String
    var latestSnapshot: BrowserPageSnapshot?
    var previousObservation: BrowserObservation?
    var latestObservation: BrowserObservation?
    var latestDelta: BrowserObservationDelta?
    var plannerState: BrowserPlannerState
    var pendingAction: BrowserPendingAction?
    var lastUserGoal: String?
    var recentActions: [BrowserSessionAction]
    var status: BrowserSessionStatus

    init(
        id: String = "browser-\(UUID().uuidString.prefix(8))",
        runtimeKind: BrowserRuntimeKind = .systemBrowser,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        currentURL: String,
        latestSnapshot: BrowserPageSnapshot? = nil,
        previousObservation: BrowserObservation? = nil,
        latestObservation: BrowserObservation? = nil,
        latestDelta: BrowserObservationDelta? = nil,
        plannerState: BrowserPlannerState = BrowserPlannerState(),
        pendingAction: BrowserPendingAction? = nil,
        lastUserGoal: String? = nil,
        recentActions: [BrowserSessionAction] = [],
        status: BrowserSessionStatus = .idle
    ) {
        self.id = id
        self.runtimeKind = runtimeKind
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.currentURL = currentURL
        self.latestSnapshot = latestSnapshot
        self.previousObservation = previousObservation
        self.latestObservation = latestObservation
        self.latestDelta = latestDelta
        self.plannerState = plannerState
        self.pendingAction = pendingAction
        self.lastUserGoal = lastUserGoal
        self.recentActions = recentActions
        self.status = status
    }
}

enum BrowserConversationMetadataKeys {
    static let pendingSessionID = "pending_browser_session_id"
    static let promptKind = "browser_prompt_kind"
    static let pageKind = "browser_page_kind"
    static let pageURL = "browser_url"
    static let requiresConfirmation = "browser_requires_confirmation"
}
