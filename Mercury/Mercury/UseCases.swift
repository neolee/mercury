//
//  UseCases.swift
//  Mercury
//

import Foundation
import GRDB
import Readability

struct UnreadCountUseCase {
    let database: DatabaseManager

    @discardableResult
    func recalculate(forFeedId feedId: Int64) async throws -> Int {
        let count = try await database.read { db in
            try Entry
                .filter(Column("feedId") == feedId)
                .filter(Column("isRead") == false)
                .fetchCount(db)
        }

        try await database.write { db in
            try db.execute(
                sql: "UPDATE feed SET unreadCount = ? WHERE id = ?",
                arguments: [count, feedId]
            )
        }

        return count
    }

    func recalculateAll() async throws {
        try await database.write { db in
            let feedIds = try Feed.fetchAll(db).compactMap(\.id)
            if feedIds.isEmpty {
                return
            }

            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT feedId, COUNT(*) AS c
                FROM entry
                WHERE isRead = 0
                GROUP BY feedId
                """
            )

            var countsByFeedId: [Int64: Int] = [:]
            countsByFeedId.reserveCapacity(rows.count)
            for row in rows {
                let id: Int64 = row["feedId"]
                let count: Int = row["c"]
                countsByFeedId[id] = count
            }

            for feedId in feedIds {
                let count = countsByFeedId[feedId] ?? 0
                try db.execute(
                    sql: "UPDATE feed SET unreadCount = ? WHERE id = ?",
                    arguments: [count, feedId]
                )
            }
        }
    }
}

struct FeedCRUDUseCase {
    let database: DatabaseManager
    let syncService: SyncService
    let validator: FeedInputValidator

    func addFeed(title: String?, feedURL: String, siteURL: String?) async throws -> Int64? {
        let normalizedURL = try validator.validateFeedURL(feedURL)
        if try await validator.feedExists(withURL: normalizedURL) {
            throw FeedEditError.duplicateFeed
        }

        let normalizedSiteURL = validator.normalizedURLString(siteURL)
        let resolvedTitle = await FeedTitleResolver.resolveAutomaticFeedTitle(
            explicitTitle: title,
            feedURL: normalizedURL,
            siteURL: normalizedSiteURL,
            fetchFeedTitle: { [syncService] url in
                try await syncService.fetchFeedTitle(from: url)
            }
        )

        do {
            return try await database.write { db in
                var feed = Feed(
                    id: nil,
                    title: validator.normalizedTitle(resolvedTitle),
                    feedURL: normalizedURL,
                    siteURL: normalizedSiteURL,
                    unreadCount: 0,
                    lastFetchedAt: nil,
                    createdAt: Date()
                )
                try feed.insert(db)
                return feed.id
            }
        } catch {
            if FeedInputValidator.isDuplicateFeedURLError(error) {
                throw FeedEditError.duplicateFeed
            }
            throw error
        }
    }

    func updateFeed(_ feed: Feed, title: String?, feedURL: String, siteURL: String?) async throws -> Int64? {
        var updated = feed
        updated.title = validator.normalizedTitle(title)
        updated.feedURL = try validator.validateFeedURL(feedURL)
        updated.siteURL = validator.normalizedURLString(siteURL)

        if try await validator.feedExists(withURL: updated.feedURL, excludingFeedId: updated.id) {
            throw FeedEditError.duplicateFeed
        }

        do {
            try await database.write { db in
                var mutable = updated
                try mutable.save(db)
            }
            return updated.id
        } catch {
            if FeedInputValidator.isDuplicateFeedURLError(error) {
                throw FeedEditError.duplicateFeed
            }
            throw error
        }
    }

    func deleteFeed(_ feed: Feed) async throws {
        try await database.write { db in
            _ = try feed.delete(db)
        }
    }

    func fetchFeedTitle(for urlString: String) async throws -> String? {
        let normalizedURL = try validator.validateFeedURL(urlString)
        return try await syncService.fetchFeedTitle(from: normalizedURL)
    }
}

struct ReaderBuildUseCaseOutput {
    let result: ReaderBuildResult
    let debugDetail: String?
}

struct ReaderBuildUseCase {
    let contentStore: ContentStore
    let jobRunner: JobRunner

    @MainActor
    func run(for entry: Entry, theme: EffectiveReaderTheme) async -> ReaderBuildUseCaseOutput {
        guard let entryId = entry.id else {
            return ReaderBuildUseCaseOutput(
                result: ReaderBuildResult(html: nil, errorMessage: "Missing entry ID"),
                debugDetail: nil
            )
        }

        let cacheThemeID = theme.cacheThemeID
        let cacheThemeKey = "\(theme.presetID.rawValue).\(theme.variant.rawValue)#\(theme.overrideHash)"

        var lastEvents: [String] = []
        func appendEvent(_ event: String) {
            lastEvents.append(event)
            if lastEvents.count > 10 {
                lastEvents.removeFirst(lastEvents.count - 10)
            }
        }

        #if DEBUG
        _ = theme.debugAssertCacheIdentity()
        appendEvent("[theme] cacheKey=\(cacheThemeKey)")
        #endif

        do {
            if let cached = try await contentStore.cachedHTML(for: entryId, themeId: cacheThemeID) {
                #if DEBUG
                appendEvent("[cache] hit")
                #endif
                return ReaderBuildUseCaseOutput(
                    result: ReaderBuildResult(html: cached.html, errorMessage: nil),
                    debugDetail: nil
                )
            }

            #if DEBUG
            appendEvent("[cache] miss")
            #endif

            let content = try await contentStore.content(for: entryId)
            if let markdown = content?.markdown, markdown.isEmpty == false {
                let html = try ReaderHTMLRenderer.render(markdown: markdown, theme: theme)
                try await contentStore.upsertCache(entryId: entryId, themeId: cacheThemeID, html: html)
                #if DEBUG
                appendEvent("[cache] wrote-from-markdown")
                #endif
                return ReaderBuildUseCaseOutput(
                    result: ReaderBuildResult(html: html, errorMessage: nil),
                    debugDetail: nil
                )
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

            let generatedMarkdown = try MarkdownConverter.markdownFromReadability(result)
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

            let renderedHTML = try ReaderHTMLRenderer.render(markdown: generatedMarkdown, theme: theme)
            try await contentStore.upsertCache(entryId: entryId, themeId: cacheThemeID, html: renderedHTML)
            #if DEBUG
            appendEvent("[cache] wrote-from-readability")
            #endif

            return ReaderBuildUseCaseOutput(
                result: ReaderBuildResult(html: renderedHTML, errorMessage: nil),
                debugDetail: nil
            )
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

            let debugDetail = [
                "Entry ID: \(entryId)",
                "URL: \(entry.url ?? "(missing)")",
                "Error: \(message)",
                "Recent Events:",
                lastEvents.isEmpty ? "(none)" : lastEvents.joined(separator: "\n")
            ].joined(separator: "\n")

            return ReaderBuildUseCaseOutput(
                result: ReaderBuildResult(html: nil, errorMessage: message),
                debugDetail: debugDetail
            )
        }
    }
}

struct FeedSyncUseCase {
    let database: DatabaseManager
    let syncService: SyncService

    func loadAllFeedIDs() async throws -> [Int64] {
        try await database.read { db in
            try Feed.fetchAll(db).compactMap(\.id)
        }
    }

    func sync(
        feedIds: [Int64],
        report: TaskProgressReporter,
        maxConcurrentFeeds: Int = 6,
        progressStart: Double,
        progressSpan: Double,
        refreshStride: Int,
        continueOnError: Bool = false,
        onError: (@Sendable (_ feedId: Int64, _ error: Error) async -> Void)? = nil,
        onRefresh: @escaping () async -> Void
    ) async throws {
        guard feedIds.isEmpty == false else {
            await report(progressStart + progressSpan, "No feeds to sync")
            return
        }

        let total = feedIds.count
        let concurrency = min(max(maxConcurrentFeeds, 2), 10)
        let stride = max(refreshStride, 1)
        struct FeedSyncOutcome {
            let feedId: Int64
            let error: Error?
        }

        var failureCount = 0
        var completed = 0
        var nextIndex = 0

        try await withThrowingTaskGroup(of: FeedSyncOutcome.self) { group in
            let initialCount = min(concurrency, total)
            for _ in 0..<initialCount {
                let feedId = feedIds[nextIndex]
                nextIndex += 1
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        try await syncService.syncFeed(withId: feedId)
                        return FeedSyncOutcome(feedId: feedId, error: nil)
                    } catch {
                        return FeedSyncOutcome(feedId: feedId, error: error)
                    }
                }
            }

            while let outcome = try await group.next() {
                try Task.checkCancellation()
                completed += 1

                if let error = outcome.error {
                    if let onError {
                        await onError(outcome.feedId, error)
                    }
                    if error is CancellationError {
                        group.cancelAll()
                        throw CancellationError()
                    }

                    failureCount += 1
                    if continueOnError == false {
                        group.cancelAll()
                        throw error
                    }
                }

                let progress = progressStart + (progressSpan * Double(completed) / Double(total))
                if failureCount > 0 {
                    await report(progress, "Processed \(completed)/\(total) feeds (\(failureCount) failed)")
                } else {
                    await report(progress, "Synced \(completed)/\(total) feeds")
                }

                if completed % stride == 0 || completed == total {
                    await onRefresh()
                }

                if nextIndex < total {
                    let feedId = feedIds[nextIndex]
                    nextIndex += 1
                    group.addTask {
                        do {
                            try Task.checkCancellation()
                            try await syncService.syncFeed(withId: feedId)
                            return FeedSyncOutcome(feedId: feedId, error: nil)
                        } catch {
                            return FeedSyncOutcome(feedId: feedId, error: error)
                        }
                    }
                }
            }
        }
    }
}

struct ImportOPMLUseCase {
    let database: DatabaseManager
    let syncService: SyncService
    let feedSyncUseCase: FeedSyncUseCase

    func run(
        from url: URL,
        replaceExisting: Bool,
        forceSiteNameAsFeedTitle: Bool,
        report: TaskProgressReporter,
        maxConcurrentFeeds: Int = 6,
        onMutation: @escaping () async -> Void,
        onSyncError: (@Sendable (_ feedId: Int64, _ error: Error) async -> Void)? = nil,
        onSkippedInsecureFeed: (@Sendable (_ feedURL: String) async -> Void)? = nil
    ) async throws {
        let importer = OPMLImporter()
        let rawFeeds = try SecurityScopedBookmarkStore.access(url) {
            try importer.parse(url: url)
        }

        let (feeds, skippedInsecure) = splitSecureFeeds(rawFeeds)
        if skippedInsecure > 0 {
            await report(0.03, "Skipped \(skippedInsecure) insecure feeds (HTTP)")
            if let onSkippedInsecureFeed {
                for item in rawFeeds {
                    if isSecureFeedURL(item.feedURL) == false {
                        await onSkippedInsecureFeed(item.feedURL)
                    }
                }
            }
        }

        if feeds.isEmpty {
            await report(1, "No feeds found in OPML")
            return
        }

        await report(0.05, "Parsed \(feeds.count) feeds")

        if replaceExisting {
            _ = try await database.write { db in
                try Feed.deleteAll(db)
            }
            await onMutation()
        }

        let batchSize = 24
        var processed = 0
        var insertedFeedIds: [Int64] = []

        for start in stride(from: 0, to: feeds.count, by: batchSize) {
            try Task.checkCancellation()
            let end = min(start + batchSize, feeds.count)
            let batch = Array(feeds[start..<end])
            let batchWithTitles = await FeedTitleResolver.resolveAutomaticTitles(
                for: batch,
                forceSiteNameAsFeedTitle: forceSiteNameAsFeedTitle,
                fetchFeedTitle: { url in
                    try await syncService.fetchFeedTitle(from: url)
                }
            )
            let inserted = try await upsertOPMLBatch(batchWithTitles)
            insertedFeedIds.append(contentsOf: inserted)
            processed += batch.count

            let progress = 0.1 + 0.5 * (Double(processed) / Double(feeds.count))
            await report(progress, "Imported \(processed)/\(feeds.count) feeds")
            await onMutation()
        }

        let syncTargetFeedIds: [Int64]
        if replaceExisting {
            syncTargetFeedIds = try await feedSyncUseCase.loadAllFeedIDs()
        } else {
            syncTargetFeedIds = insertedFeedIds
        }

        if syncTargetFeedIds.isEmpty {
            await report(1, "Import completed")
            return
        }

        try await feedSyncUseCase.sync(
            feedIds: syncTargetFeedIds,
            report: report,
            maxConcurrentFeeds: maxConcurrentFeeds,
            progressStart: 0.6,
            progressSpan: 0.4,
            refreshStride: 1,
            continueOnError: true,
            onError: onSyncError,
            onRefresh: onMutation
        )

        await report(1, "Import completed")
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

    private func splitSecureFeeds(_ feeds: [OPMLFeed]) -> (secure: [OPMLFeed], insecureCount: Int) {
        var secure: [OPMLFeed] = []
        secure.reserveCapacity(feeds.count)
        var insecureCount = 0
        for item in feeds {
            if isSecureFeedURL(item.feedURL) {
                secure.append(item)
            } else {
                insecureCount += 1
            }
        }
        return (secure, insecureCount)
    }

    private func isSecureFeedURL(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "https"
    }
}

struct ExportOPMLUseCase {
    let database: DatabaseManager

    func run(to url: URL, report: TaskProgressReporter) async throws {
        await report(0.1, "Loading feeds")
        let feeds = try await database.read { db in
            try Feed
                .order(Column("title").collating(.localizedCaseInsensitiveCompare))
                .fetchAll(db)
        }

        await report(0.55, "Generating OPML")
        let exporter = OPMLExporter()
        let opml = exporter.export(feeds: feeds, title: "Mercury Subscriptions")

        await report(0.85, "Writing file")
        try SecurityScopedBookmarkStore.access(url) {
            try opml.write(to: url, atomically: true, encoding: .utf8)
        }
        await report(1, "Export completed")
    }
}

struct BootstrapUseCase {
    let database: DatabaseManager
    let feedSyncUseCase: FeedSyncUseCase

    func run(
        report: TaskProgressReporter,
        maxConcurrentFeeds: Int = 6,
        onMutation: @escaping () async -> Void,
        onSyncError: (@Sendable (_ feedId: Int64, _ error: Error) async -> Void)? = nil,
        onSkippedInsecureFeed: (@Sendable (_ feedURL: String) async -> Void)? = nil
    ) async throws {
        await report(0.05, "Checking local feeds")
        let currentFeedCount = try await database.read { db in
            try Feed.fetchCount(db)
        }

        if currentFeedCount == 0 {
            await report(0.12, "Importing starter feeds")
            let imported = try await importStarterFeeds(limit: 10, report: report, onSkippedInsecureFeed: onSkippedInsecureFeed)
            await onMutation()

            let feedIds: [Int64]
            if imported.isEmpty {
                feedIds = try await feedSyncUseCase.loadAllFeedIDs()
            } else {
                feedIds = imported
            }

            if feedIds.isEmpty {
                await report(1, "Bootstrap completed")
                return
            }

            try await feedSyncUseCase.sync(
                feedIds: feedIds,
                report: report,
                maxConcurrentFeeds: maxConcurrentFeeds,
                progressStart: 0.35,
                progressSpan: 0.65,
                refreshStride: 3,
                continueOnError: true,
                onError: onSyncError,
                onRefresh: onMutation
            )

            await report(1, "Bootstrap completed")
            return
        }

        let feedIds = try await feedSyncUseCase.loadAllFeedIDs()
        try await feedSyncUseCase.sync(
            feedIds: feedIds,
            report: report,
            maxConcurrentFeeds: maxConcurrentFeeds,
            progressStart: 0.15,
            progressSpan: 0.8,
            refreshStride: 5,
            continueOnError: true,
            onError: onSyncError,
            onRefresh: onMutation
        )
    }

    private func importStarterFeeds(
        limit: Int,
        report: TaskProgressReporter,
        onSkippedInsecureFeed: (@Sendable (_ feedURL: String) async -> Void)?
    ) async throws -> [Int64] {
        guard let url = starterOPMLURL() else {
            await report(0.3, "Starter OPML not found")
            return []
        }

        let importer = OPMLImporter()
        let rawFeeds = try importer.parse(url: url, limit: limit)
        let (feeds, skippedInsecure) = splitSecureFeeds(rawFeeds)
        if skippedInsecure > 0 {
            await report(0.18, "Skipped \(skippedInsecure) insecure feeds (HTTP)")
            if let onSkippedInsecureFeed {
                for item in rawFeeds {
                    if isSecureFeedURL(item.feedURL) == false {
                        await onSkippedInsecureFeed(item.feedURL)
                    }
                }
            }
        }
        if feeds.isEmpty {
            await report(0.3, "No starter feeds")
            return []
        }

        await report(0.2, "Parsed \(feeds.count) starter feeds")

        return try await database.write { db in
            var insertedFeedIds: [Int64] = []
            insertedFeedIds.reserveCapacity(feeds.count)

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
                    if let id = feed.id {
                        insertedFeedIds.append(id)
                    }
                }
            }

            return insertedFeedIds
        }
    }

    private func splitSecureFeeds(_ feeds: [OPMLFeed]) -> (secure: [OPMLFeed], insecureCount: Int) {
        var secure: [OPMLFeed] = []
        secure.reserveCapacity(feeds.count)
        var insecureCount = 0
        for item in feeds {
            if isSecureFeedURL(item.feedURL) {
                secure.append(item)
            } else {
                insecureCount += 1
            }
        }
        return (secure, insecureCount)
    }

    private func isSecureFeedURL(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "https"
    }

    private func starterOPMLURL() -> URL? {
        let candidates = starterOPMLCandidateURLs()
        return candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
    }

    private func starterOPMLCandidateURLs() -> [URL] {
        var candidates: [URL] = []

        if let bundled = Bundle.main.url(forResource: "hn-popular", withExtension: "opml") {
            candidates.append(bundled)
        }

        if let resourceURL = Bundle.main.resourceURL?.appendingPathComponent("hn-popular.opml") {
            candidates.append(resourceURL)
        }

        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        candidates.append(cwd.appendingPathComponent("Mercury/Resources/hn-popular.opml"))
        candidates.append(cwd.appendingPathComponent("Resources/hn-popular.opml"))

        return candidates
    }
}
