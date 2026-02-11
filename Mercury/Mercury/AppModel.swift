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
    let taskCenter: TaskCenter
    private let syncService: SyncService
    private let jobRunner = JobRunner()
    private let taskQueue: TaskQueue

    private let lastSyncKey = "LastSyncAt"
    private let syncThreshold: TimeInterval = 15 * 60

    @Published private(set) var isReady: Bool = false
    @Published private(set) var feedCount: Int = 0
    @Published private(set) var entryCount: Int = 0
    @Published private(set) var totalUnreadCount: Int = 0
    @Published private(set) var lastSyncAt: Date?
    @Published private(set) var syncState: SyncState = .idle
    @Published private(set) var bootstrapState: BootstrapState = .idle
    @Published private(set) var backgroundDataVersion: Int = 0

    init() {
        do {
            database = try DatabaseManager()
        } catch {
            fatalError("Failed to initialize database: \(error)")
        }

        feedStore = FeedStore(db: database)
        entryStore = EntryStore(db: database)
        contentStore = ContentStore(db: database)
        taskQueue = TaskQueue(maxConcurrentTasks: 2)
        taskCenter = TaskCenter(queue: taskQueue)
        syncService = SyncService(db: database, jobRunner: jobRunner)
        lastSyncAt = loadLastSyncAt()
        isReady = true
    }

    @discardableResult
    func enqueueTask(
        kind: AppTaskKind,
        title: String,
        priority: AppTaskPriority = .utility,
        operation: @escaping (TaskProgressReporter) async throws -> Void
    ) async -> UUID {
        await taskCenter.enqueue(
            kind: kind,
            title: title,
            priority: priority,
            operation: operation
        )
    }

    func cancelTask(_ taskId: UUID) async {
        await taskCenter.cancel(taskId: taskId)
    }

    func reportUserError(title: String, message: String) {
        taskCenter.reportUserError(title: title, message: message)
    }

    func reportDebugIssue(title: String, detail: String, category: DebugIssueCategory = .general) {
        taskCenter.reportDebugIssue(title: title, detail: detail, category: category)
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
        let normalizedSiteURL = normalizedURLString(siteURL)
        let resolvedTitle = await resolveAutomaticFeedTitle(
            explicitTitle: title,
            feedURL: normalizedURL,
            siteURL: normalizedSiteURL
        )

        let feed = Feed(
            id: nil,
            title: normalizedTitle(resolvedTitle),
            feedURL: normalizedURL,
            siteURL: normalizedSiteURL,
            unreadCount: 0,
            lastFetchedAt: nil,
            createdAt: Date()
        )

        try await feedStore.upsert(feed)
        let resolvedFeedId = try await database.read { db in
            try Feed.filter(Column("feedURL") == normalizedURL).fetchOne(db)?.id
        }
        await feedStore.loadAll()
        await refreshCounts()

        if let feedId = resolvedFeedId {
            await enqueueFeedSync(
                feedIds: [feedId],
                title: "Sync New Feed",
                priority: .userInitiated
            )
        }
    }

    func updateFeed(_ feed: Feed, title: String?, feedURL: String, siteURL: String?) async throws {
        var updated = feed
        updated.title = normalizedTitle(title)
        updated.feedURL = try validateFeedURL(feedURL)
        updated.siteURL = normalizedURLString(siteURL)

        try await feedStore.upsert(updated)
        await feedStore.loadAll()
        await refreshCounts()

        if let feedId = updated.id {
            await enqueueFeedSync(
                feedIds: [feedId],
                title: "Sync Feed",
                priority: .utility
            )
        }
    }

    func deleteFeed(_ feed: Feed) async throws {
        try await feedStore.delete(feed)
        await feedStore.loadAll()
        await refreshCounts()
    }

    func importOPML(
        from url: URL,
        replaceExisting: Bool,
        forceSiteNameAsFeedTitle: Bool
    ) async throws {
        let importURL = url
        _ = await enqueueTask(
            kind: .importOPML,
            title: "Import OPML",
            priority: .userInitiated
        ) { [weak self] report in
            guard let self else { return }

            let importer = OPMLImporter()
            let feeds = try SecurityScopedBookmarkStore.access(importURL) {
                try importer.parse(url: importURL)
            }

            if feeds.isEmpty {
                await report(1, "No feeds found in OPML")
                return
            }

            await report(0.05, "Parsed \(feeds.count) feeds")

            if replaceExisting {
                _ = try await self.database.write { db in
                    try Feed.deleteAll(db)
                }
                await self.refreshAfterBackgroundMutation()
            }

            let batchSize = 24
            var processed = 0
            var insertedFeedIds: [Int64] = []
            for start in stride(from: 0, to: feeds.count, by: batchSize) {
                try Task.checkCancellation()
                let end = min(start + batchSize, feeds.count)
                let batch = Array(feeds[start..<end])
                let batchWithTitles = await self.resolveAutomaticTitles(
                    for: batch,
                    forceSiteNameAsFeedTitle: forceSiteNameAsFeedTitle
                )
                let inserted = try await self.upsertOPMLBatch(batchWithTitles)
                insertedFeedIds.append(contentsOf: inserted)
                processed += batch.count

                let progress = 0.1 + 0.5 * (Double(processed) / Double(feeds.count))
                await report(progress, "Imported \(processed)/\(feeds.count) feeds")
                await self.refreshAfterBackgroundMutation()
            }

            let syncTargetFeedIds: [Int64]
            if replaceExisting {
                syncTargetFeedIds = try await self.database.read { db in
                    try Feed.fetchAll(db).compactMap(\.id)
                }
            } else {
                syncTargetFeedIds = insertedFeedIds
            }

            if syncTargetFeedIds.isEmpty {
                await report(1, "Import completed")
                return
            }

            var synced = 0
            let syncTotal = syncTargetFeedIds.count
            for feedId in syncTargetFeedIds {
                try Task.checkCancellation()
                do {
                    try await self.syncService.syncFeed(withId: feedId)
                } catch {
                    // Keep processing the rest so import can complete progressively.
                }
                synced += 1
                let progress = 0.6 + 0.4 * (Double(synced) / Double(syncTotal))
                await report(progress, "Synced \(synced)/\(syncTotal) feeds")
                await self.refreshAfterBackgroundMutation()
            }

            await report(1, "Import completed")
        }
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
        if hasActiveTask(kind: .syncAllFeeds) || syncState == .syncing {
            return
        }

        _ = await enqueueTask(
            kind: .syncAllFeeds,
            title: "Sync Feeds",
            priority: .utility
        ) { [weak self] report in
            guard let self else { return }

            self.beginSyncState()
            do {
                let feedIds = try await self.database.read { db in
                    try Feed.fetchAll(db).compactMap(\.id)
                }

                if feedIds.isEmpty {
                    await report(1, "No feeds to sync")
                    self.finishSyncStateSuccess()
                    return
                }

                let total = feedIds.count
                for (index, feedId) in feedIds.enumerated() {
                    try Task.checkCancellation()
                    try await self.syncService.syncFeed(withId: feedId)

                    let completed = index + 1
                    let fraction = Double(completed) / Double(total)
                    await report(fraction, "Synced \(completed)/\(total) feeds")

                    if completed % 5 == 0 || completed == total {
                        await self.refreshAfterBackgroundMutation()
                    }
                }

                await report(1, "Sync completed")
                self.finishSyncStateSuccess()
                await self.refreshAfterBackgroundMutation()
            } catch {
                self.finishSyncStateFailure(error.localizedDescription)
                throw error
            }
        }
    }

    func autoSyncIfNeeded() async {
        guard shouldSyncNow() else { return }
        await syncAllFeeds()
    }

    func readerBuildResult(for entry: Entry, themeId: String) async -> ReaderBuildResult {
        guard let entryId = entry.id else {
            return ReaderBuildResult(html: nil, errorMessage: "Missing entry ID")
        }

        var lastEvents: [String] = []
        func appendEvent(_ event: String) {
            lastEvents.append(event)
            if lastEvents.count > 10 {
                lastEvents.removeFirst(lastEvents.count - 10)
            }
        }

        do {
            if let cached = try await contentStore.cachedHTML(for: entryId, themeId: themeId) {
                return ReaderBuildResult(html: cached.html, errorMessage: nil)
            }

            let content = try await contentStore.content(for: entryId)
            if let markdown = content?.markdown, markdown.isEmpty == false {
                let html = try ReaderHTMLRenderer.render(markdown: markdown, themeId: themeId)
                try await contentStore.upsertCache(entryId: entryId, themeId: themeId, html: html)
                return ReaderBuildResult(html: html, errorMessage: nil)
            }

            guard let urlString = entry.url, let url = URL(string: urlString) else {
                throw ReaderBuildError.invalidURL
            }

            let fetchedHTML = try await jobRunner.run(label: "fetchHTML", timeout: 12, onEvent: { event in
                Task { @MainActor in
                    appendEvent("[\(event.label)] \(event.message)")
                }
            }) { report in
                let (data, _) = try await URLSession.shared.data(from: url)
                if let html = String(data: data, encoding: .utf8) {
                    report("decoded")
                    return html
                }
                report("decoded")
                return String(decoding: data, as: UTF8.self)
            }

            let result = try await jobRunner.run(label: "readability", timeout: 12, onEvent: { event in
                Task { @MainActor in
                    appendEvent("[\(event.label)] \(event.message)")
                }
            }) { report in
                let readability = try Readability(html: fetchedHTML, baseURL: url)
                let result = try readability.parse()
                report("parsed")
                return result
            }

            let generatedMarkdown = try markdownFromReadability(result)
            if generatedMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ReaderBuildError.emptyContent
            }

            var updatedContent = content ?? Content(
                id: nil,
                entryId: entryId,
                html: nil,
                markdown: nil,
                displayMode: ContentDisplayMode.cleaned.rawValue,
                createdAt: Date()
            )
            updatedContent.html = fetchedHTML
            updatedContent.markdown = generatedMarkdown
            try await contentStore.upsert(updatedContent)

            let renderedHTML = try ReaderHTMLRenderer.render(markdown: generatedMarkdown, themeId: themeId)
            try await contentStore.upsertCache(entryId: entryId, themeId: themeId, html: renderedHTML)

            return ReaderBuildResult(html: renderedHTML, errorMessage: nil)
        } catch {
            let message: String
            switch error {
            case ReaderBuildError.timeout(let stage):
                message = "Timeout: \(stage)"
            case JobError.timeout(let label):
                message = "Timeout: \(label)"
            case ReaderBuildError.invalidURL:
                message = "Invalid URL"
            case ReaderBuildError.emptyContent:
                message = "Clean content is empty"
            default:
                message = error.localizedDescription
            }

            reportDebugIssue(
                title: "Reader Build Failure",
                detail: [
                    "Entry ID: \(entryId)",
                    "URL: \(entry.url ?? "(missing)")",
                    "Error: \(message)",
                    "Recent Events:",
                    lastEvents.isEmpty ? "(none)" : lastEvents.joined(separator: "\n")
                ].joined(separator: "\n"),
                category: .reader
            )
            return ReaderBuildResult(html: nil, errorMessage: message)
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

    private func resolveAutomaticFeedTitle(
        explicitTitle: String?,
        feedURL: String,
        siteURL: String?
    ) async -> String? {
        if let explicit = normalizedTitle(explicitTitle) {
            return explicit
        }

        if let siteURL, let siteName = await fetchSiteName(from: siteURL) {
            return normalizedTitle(siteName)
        }

        if let feedName = try? await syncService.fetchFeedTitle(from: feedURL) {
            return normalizedTitle(feedName)
        }

        return nil
    }

    private func resolveAutomaticTitles(
        for feeds: [OPMLFeed],
        forceSiteNameAsFeedTitle: Bool
    ) async -> [OPMLFeed] {
        var resolved: [OPMLFeed] = []
        resolved.reserveCapacity(feeds.count)

        for item in feeds {
            if forceSiteNameAsFeedTitle {
                let fetchedSiteName: String?
                if let siteURL = item.siteURL {
                    fetchedSiteName = await fetchSiteName(from: siteURL)
                } else {
                    fetchedSiteName = nil
                }
                let finalTitle = normalizedTitle(fetchedSiteName) ?? normalizedTitle(item.title)
                resolved.append(
                    OPMLFeed(
                        title: finalTitle,
                        feedURL: item.feedURL,
                        siteURL: item.siteURL
                    )
                )
                continue
            }

            if normalizedTitle(item.title) != nil {
                resolved.append(item)
                continue
            }

            let autoTitle = await resolveAutomaticFeedTitle(
                explicitTitle: item.title,
                feedURL: item.feedURL,
                siteURL: item.siteURL
            )

            resolved.append(
                OPMLFeed(
                    title: autoTitle,
                    feedURL: item.feedURL,
                    siteURL: item.siteURL
                )
            )
        }

        return resolved
    }

    private func fetchSiteName(from urlString: String) async -> String? {
        guard let url = URL(string: urlString) else { return nil }

        let candidateURLs: [URL]
        if url.scheme?.lowercased() == "http" {
            var secureComponents = URLComponents(url: url, resolvingAgainstBaseURL: false)
            secureComponents?.scheme = "https"
            if let secureURL = secureComponents?.url {
                candidateURLs = [secureURL, url]
            } else {
                candidateURLs = [url]
            }
        } else {
            candidateURLs = [url]
        }

        for candidateURL in candidateURLs {
            do {
                var request = URLRequest(url: candidateURL)
                request.timeoutInterval = 8
                let (data, _) = try await URLSession.shared.data(for: request)
                let html = String(decoding: data, as: UTF8.self)
                let document = try SwiftSoup.parse(html)

                if let ogName = try firstMetaContent(document: document, query: "meta[property=og:site_name]"),
                   ogName.isEmpty == false {
                    return ogName
                }

                if let appName = try firstMetaContent(document: document, query: "meta[name=application-name]"),
                   appName.isEmpty == false {
                    return appName
                }

                let title = try document.title().trimmingCharacters(in: .whitespacesAndNewlines)
                if title.isEmpty == false {
                    return title
                }
            } catch {
                continue
            }
        }

        return nil
    }

    private func firstMetaContent(document: Document, query: String) throws -> String? {
        guard let element = try document.select(query).first() else { return nil }
        let content = try element.attr("content").trimmingCharacters(in: .whitespacesAndNewlines)
        return content.isEmpty ? nil : content
    }

    private func validateFeedURL(_ urlString: String) throws -> String {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { throw FeedEditError.invalidURL }
        guard let url = URL(string: trimmed), url.scheme != nil else { throw FeedEditError.invalidURL }
        return trimmed
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
        if syncState == .syncing {
            return false
        }
        if hasActiveTask(kind: .syncAllFeeds) {
            return false
        }
        guard let lastSyncAt else { return true }
        return Date().timeIntervalSince(lastSyncAt) > syncThreshold
    }

    private func hasActiveTask(kind: AppTaskKind) -> Bool {
        taskCenter.tasks.contains { task in
            task.kind == kind && task.state.isTerminal == false
        }
    }

    private func beginSyncState() {
        syncState = .syncing
    }

    private func finishSyncStateSuccess() {
        let now = Date()
        lastSyncAt = now
        saveLastSyncAt(now)
        syncState = .idle
    }

    private func finishSyncStateFailure(_ message: String) {
        syncState = .failed(message)
    }

    private func loadLastSyncAt() -> Date? {
        UserDefaults.standard.object(forKey: lastSyncKey) as? Date
    }

    private func saveLastSyncAt(_ date: Date) {
        UserDefaults.standard.set(date, forKey: lastSyncKey)
    }

    private func upsertOPMLBatch(_ feeds: [OPMLFeed]) async throws -> [Int64] {
        try await database.write { db in
            var insertedFeedIds: [Int64] = []
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
            return insertedFeedIds
        }
    }

    private func refreshAfterBackgroundMutation() async {
        await feedStore.loadAll()
        await refreshCounts()
        backgroundDataVersion &+= 1
    }

    private func enqueueFeedSync(
        feedIds: [Int64],
        title: String,
        priority: AppTaskPriority
    ) async {
        guard feedIds.isEmpty == false else { return }

        _ = await enqueueTask(
            kind: .syncFeeds,
            title: title,
            priority: priority
        ) { [weak self] report in
            guard let self else { return }

            let total = feedIds.count
            for (index, feedId) in feedIds.enumerated() {
                try Task.checkCancellation()
                try await self.syncService.syncFeed(withId: feedId)

                let completed = index + 1
                let fraction = Double(completed) / Double(total)
                await report(fraction, "Synced \(completed)/\(total) feeds")
                await self.refreshAfterBackgroundMutation()
            }

            await report(1, "Sync completed")
        }
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
