//
//  SecurityScopedBookmarkStore.swift
//  Mercury
//
//  Created by Neo on 2026/2/4.
//

import Foundation

nonisolated enum SecurityScopedBookmarkResolutionResult {
    case missing
    case resolved(url: URL, wasStale: Bool)
    case failed(String)
}

nonisolated enum SecurityScopedBookmarkAccessError: LocalizedError {
    case accessDenied(String)

    nonisolated var errorDescription: String? {
        switch self {
        case let .accessDenied(path):
            return "Security-scoped resource access was denied: \(path)"
        }
    }
}

nonisolated enum SecurityScopedBookmarkStore {
    private static let lastOPMLDirectoryKey = "LastOPMLDirectoryBookmark"

    nonisolated static func saveDirectory(_ url: URL) {
        saveDirectory(url, key: lastOPMLDirectoryKey)
    }

    nonisolated static func saveDirectory(_ url: URL, key: String) {
        do {
            let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(data, forKey: key)
        } catch {
            return
        }
    }

    nonisolated static func resolveDirectory() -> URL? {
        resolveDirectory(key: lastOPMLDirectoryKey)
    }

    nonisolated static func resolveDirectory(key: String) -> URL? {
        switch resolveDirectoryStatus(key: key) {
        case .missing, .failed:
            return nil
        case let .resolved(url, _):
            return url
        }
    }

    nonisolated static func resolveDirectoryStatus(key: String) -> SecurityScopedBookmarkResolutionResult {
        guard let data = UserDefaults.standard.data(forKey: key) else { return .missing }
        var isStale = false
        do {
            let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &isStale)
            if isStale {
                saveDirectory(url, key: key)
            }
            return .resolved(url: url, wasStale: isStale)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    nonisolated static func clearDirectory(key: String) {
        UserDefaults.standard.removeObject(forKey: key)
    }

    nonisolated static func access<T>(_ url: URL, _ work: () throws -> T) throws -> T {
        let didAccess = url.startAccessingSecurityScopedResource()
        guard didAccess else {
            throw SecurityScopedBookmarkAccessError.accessDenied(url.path)
        }
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try work()
    }
}
