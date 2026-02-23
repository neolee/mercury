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
}

enum ReaderBuildError: Error {
    case timeout(String)
    case invalidURL
    case emptyContent
}

// MARK: - Banner

struct ReaderBannerMessage {
    let text: String
    let action: BannerAction?
    let secondaryAction: BannerAction?

    struct BannerAction {
        let label: String
        let handler: () -> Void
    }

    init(text: String, action: BannerAction? = nil, secondaryAction: BannerAction? = nil) {
        self.text = text
        self.action = action
        self.secondaryAction = secondaryAction
    }
}

extension ReaderBannerMessage.BannerAction {
    /// Returns an action that opens the Debug Issues panel in debug builds,
    /// and `nil` in release builds so no button is rendered.
    static var openDebugIssues: ReaderBannerMessage.BannerAction? {
        #if DEBUG
        return ReaderBannerMessage.BannerAction(label: "Open Debug View") {
            NotificationCenter.default.post(name: .openDebugIssuesRequested, object: nil)
        }
        #else
        return nil
        #endif
    }
}
