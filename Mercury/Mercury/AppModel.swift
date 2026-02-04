//
//  AppModel.swift
//  Mercury
//
//  Created by Neo on 2026/2/3.
//

import Combine
import Foundation
import GRDB
import Readability
import SwiftSoup

@MainActor
final class AppModel: ObservableObject {
    let database: DatabaseManager
    let feedStore: FeedStore
    let entryStore: EntryStore
    let contentStore: ContentStore
    private let syncService: SyncService

    private let lastSyncKey = "LastSyncAt"
    private let syncThreshold: TimeInterval = 15 * 60

    @Published private(set) var isReady: Bool = false
    @Published private(set) var feedCount: Int = 0
    @Published private(set) var entryCount: Int = 0
    @Published private(set) var totalUnreadCount: Int = 0
    @Published private(set) var lastSyncAt: Date?
    @Published private(set) var syncState: SyncState = .idle
    @Published private(set) var bootstrapState: BootstrapState = .idle

    init() {
        do {
            database = try DatabaseManager()
        } catch {
            fatalError("Failed to initialize database: \(error)")
        }

        feedStore = FeedStore(db: database)
        entryStore = EntryStore(db: database)
        contentStore = ContentStore(db: database)
        syncService = SyncService(db: database)
        lastSyncAt = loadLastSyncAt()
        isReady = true
    }

    func bootstrapIfNeeded() async {
        guard bootstrapState == .idle else { return }
        do {
            let currentFeedCount = try await database.read { db in
                try Feed.fetchCount(db)
            }

            if currentFeedCount == 0 {
                bootstrapState = .importing
                try await performSyncTask {
                    try await syncService.bootstrapIfNeeded(limit: 10)
                }
            } else {
                bootstrapState = .importing
                try await performSyncTask {
                    try await syncService.syncAllFeeds()
                }
            }

            await feedStore.loadAll()
            await refreshCounts()
            bootstrapState = .ready
        } catch {
            bootstrapState = .failed(error.localizedDescription)
        }
    }

    func markEntryRead(_ entry: Entry) async {
        guard let entryId = entry.id else { return }
        guard entry.isRead == false else { return }

        do {
            try await entryStore.markRead(entryId: entryId, isRead: true)
            _ = try await feedStore.updateUnreadCount(for: entry.feedId)
            totalUnreadCount = feedStore.totalUnreadCount
        } catch {
            return
        }
    }

    func refreshUnreadTotals() {
        totalUnreadCount = feedStore.totalUnreadCount
    }

    func refreshCounts() async {
        do {
            feedCount = try await database.read { db in
                try Feed.fetchCount(db)
            }
            entryCount = try await database.read { db in
                try Entry.fetchCount(db)
            }
        } catch {
            feedCount = feedStore.feeds.count
        }
        totalUnreadCount = feedStore.totalUnreadCount
    }

    func addFeed(title: String?, feedURL: String, siteURL: String?) async throws {
        let normalizedURL = try validateFeedURL(feedURL)
        let resolvedTitle: String?
        if let title, title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            resolvedTitle = title
        } else {
            resolvedTitle = try await fetchFeedTitle(for: normalizedURL)
        }

        let feed = Feed(
            id: nil,
            title: normalizedTitle(resolvedTitle),
            feedURL: normalizedURL,
            siteURL: normalizedURLString(siteURL),
            unreadCount: 0,
            lastFetchedAt: nil,
            createdAt: Date()
        )

        try await feedStore.upsert(feed)
        let resolvedFeedId = try await database.read { db in
            try Feed.filter(Column("feedURL") == normalizedURL).fetchOne(db)?.id
        }
        if let feedId = resolvedFeedId {
            try await performSyncTask {
                try await syncService.syncFeed(withId: feedId)
            }
        }
        await feedStore.loadAll()
        await refreshCounts()
    }

    func updateFeed(_ feed: Feed, title: String?, feedURL: String, siteURL: String?) async throws {
        var updated = feed
        updated.title = normalizedTitle(title)
        updated.feedURL = try validateFeedURL(feedURL)
        updated.siteURL = normalizedURLString(siteURL)

        try await feedStore.upsert(updated)
        if let feedId = updated.id {
            try await performSyncTask {
                try await syncService.syncFeed(withId: feedId)
            }
        }
        await feedStore.loadAll()
        await refreshCounts()
    }

    func deleteFeed(_ feed: Feed) async throws {
        try await feedStore.delete(feed)
        await feedStore.loadAll()
        await refreshCounts()
    }

    func importOPML(from url: URL, replaceExisting: Bool) async throws {
        let importer = OPMLImporter()
        let feeds = try SecurityScopedBookmarkStore.access(url) {
            try importer.parse(url: url)
        }

        var insertedFeedIds: [Int64] = []

        try await database.write { db in
            if replaceExisting {
                try Feed.deleteAll(db)
            }

            for item in feeds {
                if var existing = try Feed.filter(Column("feedURL") == item.feedURL).fetchOne(db) {
                    if let title = item.title { existing.title = title }
                    if let siteURL = item.siteURL { existing.siteURL = siteURL }
                    try existing.update(db)
                } else {
                    var feed = Feed(
                        id: nil,
                        title: item.title,
                        feedURL: item.feedURL,
                        siteURL: item.siteURL,
                        unreadCount: 0,
                        lastFetchedAt: nil,
                        createdAt: Date()
                    )
                    try feed.insert(db)
                    if let feedId = feed.id {
                        insertedFeedIds.append(feedId)
                    }
                }
            }
        }

        if replaceExisting {
            try await performSyncTask {
                try await syncService.syncAllFeeds()
            }
        } else if insertedFeedIds.isEmpty == false {
            try await performSyncTask {
                try await syncService.syncFeeds(withIds: insertedFeedIds)
            }
        }
        await feedStore.loadAll()
        await refreshCounts()
    }

    func exportOPML(to url: URL) async throws {
        let feeds = try await database.read { db in
            try Feed.order(Column("title").collating(.localizedCaseInsensitiveCompare)).fetchAll(db)
        }

        let exporter = OPMLExporter()
        let opml = exporter.export(feeds: feeds, title: "Mercury Subscriptions")

        try SecurityScopedBookmarkStore.access(url) {
            try opml.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func fetchFeedTitle(for urlString: String) async throws -> String? {
        let normalizedURL = try validateFeedURL(urlString)
        return try await syncService.fetchFeedTitle(from: normalizedURL)
    }

    func syncAllFeeds() async {
        do {
            try await performSyncTask {
                try await syncService.syncAllFeeds()
            }
            await feedStore.loadAll()
            await refreshCounts()
        } catch {
            syncState = .failed(error.localizedDescription)
        }
    }

    func autoSyncIfNeeded() async {
        guard shouldSyncNow() else { return }
        await syncAllFeeds()
    }

    func readerHTML(for entry: Entry, themeId: String) async -> String? {
        guard let entryId = entry.id else { return nil }

        do {
            if let cached = try await contentStore.cachedHTML(for: entryId, themeId: themeId) {
                return cached.html
            }
        } catch {
            return nil
        }

        do {
            let content = try await contentStore.content(for: entryId)
            if let markdown = content?.markdown, markdown.isEmpty == false {
                let html = try ReaderHTMLRenderer.render(markdown: markdown, themeId: themeId)
                try await contentStore.upsertCache(entryId: entryId, themeId: themeId, html: html)
                return html
            }

            guard let urlString = entry.url, let url = URL(string: urlString) else { return nil }
            let rawHTML = try await fetchHTML(from: url)
            let readability = Readability()
            let result = try await readability.parse(html: rawHTML, options: nil, baseURL: url)

            let markdown = try markdownFromReadability(result)
            var updatedContent = content ?? Content(
                id: nil,
                entryId: entryId,
                html: nil,
                markdown: nil,
                displayMode: ContentDisplayMode.cleaned.rawValue,
                createdAt: Date()
            )
            updatedContent.html = rawHTML
            updatedContent.markdown = markdown
            try await contentStore.upsert(updatedContent)

            let renderedHTML = try ReaderHTMLRenderer.render(markdown: markdown, themeId: themeId)
            try await contentStore.upsertCache(entryId: entryId, themeId: themeId, html: renderedHTML)
            return renderedHTML
        } catch {
            return nil
        }
    }

    private func normalizedTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalizedURLString(_ urlString: String?) -> String? {
        guard let urlString else { return nil }
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func validateFeedURL(_ urlString: String) throws -> String {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { throw FeedEditError.invalidURL }
        guard let url = URL(string: trimmed), url.scheme != nil else { throw FeedEditError.invalidURL }
        return trimmed
    }

    private func fetchHTML(from url: URL) async throws -> String {
        let (data, _) = try await URLSession.shared.data(from: url)
        if let html = String(data: data, encoding: .utf8) {
            return html
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func markdownFromReadability(_ result: ReadabilityResult) throws -> String {
        var parts: [String] = []

        let title = result.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty == false {
            parts.append("# \(title)")
        }

        if let byline = result.byline?.trimmingCharacters(in: .whitespacesAndNewlines), byline.isEmpty == false {
            parts.append("_\(byline)_")
        }

        let bodyMarkdown = try markdownFromHTML(result.content)
        if bodyMarkdown.isEmpty == false {
            parts.append(bodyMarkdown)
        } else {
            let fallback = result.textContent
                .replacingOccurrences(of: "\n", with: "\n\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if fallback.isEmpty == false {
                parts.append(fallback)
            }
        }

        return parts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func markdownFromHTML(_ html: String) throws -> String {
        let document = try SwiftSoup.parse(html)
        let root = document.body() ?? document
        return try renderMarkdown(from: root)
            .replacingOccurrences(of: "\n\n\n+", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func renderMarkdown(from node: Node) throws -> String {
        if let textNode = node as? TextNode {
            return textNode.text().replacingOccurrences(of: "\n", with: " ")
        }

        guard let element = node as? Element else {
            return ""
        }

        let tag = element.tagName().lowercased()
        switch tag {
        case "h1", "h2", "h3", "h4", "h5", "h6":
            let level = Int(tag.dropFirst()) ?? 1
            let text = try element.text().trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(String(repeating: "#", count: level)) \(text)\n\n"
        case "p":
            let text = try renderChildrenMarkdown(from: element)
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\(text)\n\n"
        case "br":
            return "\n"
        case "ul":
            return try element.children().map { child in
                guard child.tagName().lowercased() == "li" else { return "" }
                let text = try renderChildrenMarkdown(from: child).trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? "" : "- \(text)"
            }.joined(separator: "\n") + "\n\n"
        case "ol":
            var index = 1
            let lines = try element.children().compactMap { child -> String? in
                guard child.tagName().lowercased() == "li" else { return nil }
                let text = try renderChildrenMarkdown(from: child).trimmingCharacters(in: .whitespacesAndNewlines)
                defer { index += 1 }
                return text.isEmpty ? nil : "\(index). \(text)"
            }
            return lines.joined(separator: "\n") + "\n\n"
        case "blockquote":
            let text = try renderChildrenMarkdown(from: element)
            let quoted = text
                .split(separator: "\n")
                .map { "> \($0)" }
                .joined(separator: "\n")
            return quoted + "\n\n"
        case "pre":
            let text = try element.text()
            return "```\n\(text)\n```\n\n"
        case "code":
            let text = try element.text()
            return "`\(text)`"
        case "img":
            let alt = (try? element.attr("alt")) ?? ""
            let src = (try? element.attr("src")) ?? ""
            guard src.isEmpty == false else { return "" }
            return "![\(alt)](\(src))\n\n"
        case "a":
            let text = try element.text().trimmingCharacters(in: .whitespacesAndNewlines)
            let href = (try? element.attr("href")) ?? ""
            guard href.isEmpty == false else { return text }
            return "[\(text.isEmpty ? href : text)](\(href))"
        default:
            return try renderChildrenMarkdown(from: element)
        }
    }

    private func renderChildrenMarkdown(from element: Element) throws -> String {
        let children = element.getChildNodes()
        let rendered = try children.map { try renderMarkdown(from: $0) }.joined()
        return rendered.replacingOccurrences(of: "  ", with: " ")
    }

    private func performSyncTask(_ work: () async throws -> Void) async throws {
        syncState = .syncing
        do {
            try await work()
            let now = Date()
            lastSyncAt = now
            saveLastSyncAt(now)
            syncState = .idle
        } catch {
            syncState = .failed(error.localizedDescription)
            throw error
        }
    }

    private func shouldSyncNow() -> Bool {
        if case .syncing = syncState {
            return false
        }
        guard let lastSyncAt else { return true }
        return Date().timeIntervalSince(lastSyncAt) > syncThreshold
    }

    private func loadLastSyncAt() -> Date? {
        UserDefaults.standard.object(forKey: lastSyncKey) as? Date
    }

    private func saveLastSyncAt(_ date: Date) {
        UserDefaults.standard.set(date, forKey: lastSyncKey)
    }
}

enum FeedEditError: LocalizedError {
    case invalidURL

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Please enter a valid feed URL."
        }
    }
}

enum BootstrapState: Equatable {
    case idle
    case importing
    case ready
    case failed(String)
}

enum SyncState: Equatable {
    case idle
    case syncing
    case failed(String)
}