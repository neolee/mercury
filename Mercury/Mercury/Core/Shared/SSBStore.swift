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
        do {
            let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(data, forKey: lastOPMLDirectoryKey)
        } catch {
            return
        }
    }

    static func resolveDirectory() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: lastOPMLDirectoryKey) else { return nil }
        var isStale = false
        do {
            let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &isStale)
            if isStale {
                saveDirectory(url)
            }
            return url
        } catch {
            return nil
        }
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
