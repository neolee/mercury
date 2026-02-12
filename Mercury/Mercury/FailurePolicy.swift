//
//  FailurePolicy.swift
//  Mercury
//

import Foundation

enum FailurePolicy {
    enum FeedSyncCategory: String {
        case unsupportedFormat
        case tlsFailure
        case atsPolicy
        case other
    }

    private static let unsupportedFormatPhrases: [String] = [
        "feed format is not recognized or supported",
        "format is not recognized",
        "not recognized or supported"
    ]

    private static let atsPhrases: [String] = [
        "app transport security policy requires the use of a secure connection"
    ]

    private static let tlsPhrases: [String] = [
        "tls error",
        "secure connection to fail",
        "tls",
        "secure connection"
    ]

    static func classifyFeedSyncError(_ error: Error) -> FeedSyncCategory {
        let nsError = error as NSError
        return classifyFeedSync(
            message: nsError.localizedDescription,
            domain: nsError.domain,
            code: nsError.code
        )
    }

    static func isPermanentUnsupportedFeedError(_ error: Error) -> Bool {
        classifyFeedSyncError(error) == .unsupportedFormat
    }

    static func shouldSurfaceFailureToUser(kind: AppTaskKind, message: String) -> Bool {
        switch kind {
        case .bootstrap, .syncAllFeeds, .syncFeeds:
            return false
        case .importOPML:
            return shouldSurfaceImportFailureToUser(message)
        case .exportOPML, .readerBuild, .custom:
            return true
        }
    }

    private static func shouldSurfaceImportFailureToUser(_ message: String) -> Bool {
        classifyFeedSync(message: message, domain: nil, code: nil) == .other
    }

    private static func classifyFeedSync(message: String, domain: String?, code: Int?) -> FeedSyncCategory {
        let normalized = message.lowercased()

        if unsupportedFormatPhrases.contains(where: { normalized.contains($0) }) {
            return .unsupportedFormat
        }

        if domain == NSURLErrorDomain, code == -1022 {
            return .atsPolicy
        }
        if atsPhrases.contains(where: { normalized.contains($0) }) {
            return .atsPolicy
        }

        if (domain == NSURLErrorDomain && code == -1200) ||
            tlsPhrases.contains(where: { normalized.contains($0) }) {
            return .tlsFailure
        }

        return .other
    }
}
