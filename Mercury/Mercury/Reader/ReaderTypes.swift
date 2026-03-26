//
//  ReaderTypes.swift
//  Mercury
//
//  Created by Neo on 2026/2/4.
//

import Foundation

struct ReaderBuildResult {
    let html: String?
    let errorMessage: String?
    let didUpgradeEntryURL: Bool

    init(html: String?, errorMessage: String?, didUpgradeEntryURL: Bool = false) {
        self.html = html
        self.errorMessage = errorMessage
        self.didUpgradeEntryURL = didUpgradeEntryURL
    }
}

enum ReaderBuildError: Error {
    case timeout(String)
    case invalidURL
    case emptyContent
}

// MARK: - Banner

struct ReaderBannerMessage {
    let text: String
    let severity: AgentMessageSeverity
    let action: BannerAction?
    let secondaryAction: BannerAction?

    struct BannerAction {
        let label: String
        let handler: () -> Void
    }

    init(
        text: String,
        severity: AgentMessageSeverity = .warning,
        action: BannerAction? = nil,
        secondaryAction: BannerAction? = nil
    ) {
        self.text = text
        self.severity = severity
        self.action = action
        self.secondaryAction = secondaryAction
    }
}

extension ReaderBannerMessage.BannerAction {
    /// Returns an action that opens the Debug Issues panel in debug builds,
    /// and `nil` in release builds so no button is rendered.
    @MainActor static var openDebugIssues: ReaderBannerMessage.BannerAction? {
        #if DEBUG
        return ReaderBannerMessage.BannerAction(
            label: AgentRuntimeProjection.actionLabel(
                for: .openDebugIssues,
                bundle: LanguageManager.shared.bundle
            )
        ) {
            NotificationCenter.default.post(name: .openDebugIssuesRequested, object: nil)
        }
        #else
        return nil
        #endif
    }
}
