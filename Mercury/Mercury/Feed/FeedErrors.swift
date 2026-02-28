//
//  FeedErrors.swift
//  Mercury
//

import Foundation

enum SyncError: Error {
    case missingOPML([String])
}

extension SyncError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .missingOPML(let paths):
            let list = paths.joined(separator: "\n")
            return "OPML not found. Tried:\n\(list)"
        }
    }
}
