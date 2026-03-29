//
//  SecurityScopedBookmarkStore.swift
//  Mercury
//
//  Created by Neo on 2026/2/4.
//

import Foundation

enum SecurityScopedBookmarkStore {
    private static let lastOPMLDirectoryKey = "LastOPMLDirectoryBookmark"

    static func saveDirectory(_ url: URL) {
        saveDirectory(url, key: lastOPMLDirectoryKey)
    }

    static func saveDirectory(_ url: URL, key: String) {
        do {
            let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(data, forKey: key)
        } catch {
            return
        }
    }

    static func resolveDirectory() -> URL? {
        resolveDirectory(key: lastOPMLDirectoryKey)
    }

    static func resolveDirectory(key: String) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var isStale = false
        do {
            let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &isStale)
            if isStale {
                saveDirectory(url, key: key)
            }
            return url
        } catch {
            return nil
        }
    }

    static func clearDirectory(key: String) {
        UserDefaults.standard.removeObject(forKey: key)
    }

    static func access<T>(_ url: URL, _ work: () throws -> T) rethrows -> T {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try work()
    }
}
