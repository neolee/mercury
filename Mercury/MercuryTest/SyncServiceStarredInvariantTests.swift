import Foundation
import FeedKit
import GRDB
import Testing
import XMLKit
@testable import Mercury

@Suite("SyncService Starred Invariant")
@MainActor
struct SyncServiceStarredInvariantTests {
    @Test("Conflict-ignored sync insert preserves existing isStarred")
    @MainActor
    func conflictIgnoredInsertKeepsExistingStarState() async throws {
        try await InMemoryDatabaseFixture.withFixture { fixture in
            let manager = fixture.database

            let (feedId, existingEntryId) = try await manager.write { db in
                var feed = Feed(
                    id: nil,
                    title: "Invariant Feed",
                    feedURL: "https://example.com/invariant-feed",
                    siteURL: "https://example.com",
                    lastFetchedAt: nil,
                    createdAt: Date()
                )
                try feed.insert(db)
                guard let feedId = feed.id else {
                    throw TestError.missingFeedID
                }

                var existingEntry = Entry(
                    id: nil,
                    feedId: feedId,
                    guid: "guid-001",
                    url: "https://example.com/article/1",
                    title: "Existing Starred Entry",
                    author: nil,
                    publishedAt: Date(),
                    summary: "existing",
                    isRead: false,
                    isStarred: true,
                    createdAt: Date()
                )
                try existingEntry.insert(db)
                guard let entryId = existingEntry.id else {
                    throw TestError.missingEntryID
                }

                return (feedId, entryId)
            }

            try await manager.write { db in
                var incomingEntry = Entry(
                    id: nil,
                    feedId: feedId,
                    guid: "guid-001",
                    url: "https://example.com/article/1",
                    title: "Incoming Sync Entry",
                    author: nil,
                    publishedAt: Date().addingTimeInterval(60),
                    summary: "incoming",
                    isRead: false,
                    isStarred: false,
                    createdAt: Date().addingTimeInterval(60)
                )
                try incomingEntry.insert(db, onConflict: .ignore)
            }

            let snapshot = try await manager.read { db in
                let count = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM entry WHERE feedId = ?",
                    arguments: [feedId]
                ) ?? 0
                let row = try Row.fetchOne(
                    db,
                    sql: "SELECT id, title, isStarred FROM entry WHERE feedId = ? AND guid = ? LIMIT 1",
                    arguments: [feedId, "guid-001"]
                )
                return (count, row)
            }

            #expect(snapshot.0 == 1)
            #expect((snapshot.1?["id"] as Int64?) == existingEntryId)
            #expect((snapshot.1?["title"] as String?) == "Existing Starred Entry")
            #expect((snapshot.1?["isStarred"] as Bool?) == true)
        }
    }

    @Test("Atom sync prefers alternate HTML link over replies and edit links")
    func atomSyncPrefersAlternateHTMLLink() async throws {
        try await InMemoryDatabaseFixture.withFixture { fixture in
            let manager = fixture.database
            let syncService = SyncService(
                db: manager,
                feedLoadUseCase: FeedLoadUseCase(jobRunner: JobRunner()),
                feedEntryMapper: FeedEntryMapper()
            )

            let feed = try await makeFeed(
                manager: manager,
                title: "Atom Feed",
                feedURL: "https://example.com/feed",
                siteURL: "https://example.com"
            )

            let atomEntry = AtomFeedEntry(
                title: "Article Title",
                links: [
                    atomLink(href: "https://example.com/feeds/123/comments/default", rel: "replies", type: "application/atom+xml"),
                    atomLink(href: "https://example.com/2026/03/article.html#comment-form", rel: "replies", type: "text/html"),
                    atomLink(href: "https://www.blogger.com/feeds/posts/default/123", rel: "edit", type: "application/atom+xml"),
                    atomLink(href: "https://www.blogger.com/feeds/posts/default/123", rel: "self", type: "application/atom+xml"),
                    atomLink(href: "https://example.com/2026/03/article.html", rel: "alternate", type: "text/html")
                ],
                updated: Date(),
                id: "guid-atom-001"
            )

            try await syncService.syncParsedFeed(
                .atom(AtomFeed(entries: [atomEntry])),
                into: feed
            )

            let storedEntry = try await manager.read { db in
                try Entry
                    .filter(Column("feedId") == feed.id!)
                    .filter(Column("guid") == "guid-atom-001")
                    .fetchOne(db)
            }

            #expect(storedEntry?.url == "https://example.com/2026/03/article.html")
        }
    }

    @Test("Feed parser repair updates wrong stored URL, clears reader caches, and preserves user state")
    func feedParserRepairUpdatesWrongStoredURLAndClearsReaderCaches() async throws {
        try await InMemoryDatabaseFixture.withFixture { fixture in
            let manager = fixture.database
            let repairUseCase = FeedParserRepairUseCase(database: manager)
            let recorder = FeedParserRepairEventRecorder()

            let feed = try await makeFeed(
                manager: manager,
                title: "Repair Feed",
                feedURL: "https://example.com/feed",
                siteURL: "https://example.com"
            )

            let entryId = try await manager.write { db in
                var existingEntry = Entry(
                    id: nil,
                    feedId: feed.id!,
                    guid: "guid-repair-001",
                    url: "https://example.com/feeds/123/comments/default",
                    title: "Stored Wrong URL",
                    author: nil,
                    publishedAt: Date(),
                    summary: nil,
                    isRead: true,
                    isStarred: true,
                    createdAt: Date()
                )
                try existingEntry.insert(db)

                let insertedEntryId = try #require(existingEntry.id)

                var content = Content(
                    id: nil,
                    entryId: insertedEntryId,
                    html: "<feed />",
                    cleanedHtml: "<p>old</p>",
                    readabilityTitle: "Old",
                    readabilityByline: nil,
                    readabilityVersion: ReaderPipelineVersion.readability,
                    markdown: "old",
                    markdownVersion: ReaderPipelineVersion.markdown,
                    displayMode: ContentDisplayMode.cleaned.rawValue,
                    createdAt: Date()
                )
                try content.insert(db)

                var cache = ContentHTMLCache(
                    entryId: insertedEntryId,
                    themeId: "default",
                    html: "<html>old</html>",
                    readerRenderVersion: ReaderPipelineVersion.readerRender,
                    updatedAt: Date()
                )
                try cache.insert(db)

                return insertedEntryId
            }

            let atomEntry = AtomFeedEntry(
                title: "Stored Wrong URL",
                links: [
                    atomLink(href: "https://example.com/feeds/123/comments/default", rel: "replies", type: "application/atom+xml"),
                    atomLink(href: "https://example.com/2026/03/article.html", rel: "alternate", type: "text/html")
                ],
                updated: Date(),
                id: "guid-repair-001"
            )

            try await repairUseCase.verifyAndRepairIfNeeded(
                feed: feed,
                parsedFeed: .atom(AtomFeed(entries: [atomEntry])),
                onEvent: { event in
                    await recorder.record(event)
                }
            )

            let snapshot = try await manager.read { db in
                let entry = try Entry.filter(Column("id") == entryId).fetchOne(db)
                let content = try Content.filter(Column("entryId") == entryId).fetchOne(db)
                let cacheCount = try ContentHTMLCache
                    .filter(Column("entryId") == entryId)
                    .fetchCount(db)
                let repairedFeed = try Feed.filter(Column("id") == feed.id!).fetchOne(db)
                return (entry, content, cacheCount, repairedFeed)
            }

            #expect(snapshot.0?.url == "https://example.com/2026/03/article.html")
            #expect(snapshot.0?.isRead == true)
            #expect(snapshot.0?.isStarred == true)
            #expect(snapshot.1 == nil)
            #expect(snapshot.2 == 0)
            #expect(snapshot.3?.feedParserVersion == FeedParserVersion.current)

            let events = await recorder.snapshot()
            #expect(events.count == 2)
            guard events.count == 2 else { return }

            switch events[0] {
            case .started(let payload):
                #expect(payload.repairCount == 1)
                #expect(payload.samples.first?.oldURL == "https://example.com/feeds/123/comments/default")
                #expect(payload.samples.first?.newURL == "https://example.com/2026/03/article.html")
            default:
                Issue.record("Expected repair started event first")
            }

            switch events[1] {
            case .completed(let payload):
                #expect(payload.repairCount == 1)
                #expect(payload.contentRowsDeleted == 1)
                #expect(payload.cacheRowsDeleted == 1)
            default:
                Issue.record("Expected repair completed event second")
            }
        }
    }

    @Test("Feed parser repair skips conflicting target URL and still marks the feed current")
    func feedParserRepairSkipsRepairOnURLConflict() async throws {
        try await InMemoryDatabaseFixture.withFixture { fixture in
            let manager = fixture.database
            let repairUseCase = FeedParserRepairUseCase(database: manager)
            let recorder = FeedParserRepairEventRecorder()

            let feed = try await makeFeed(
                manager: manager,
                title: "Conflict Feed",
                feedURL: "https://example.com/feed",
                siteURL: "https://example.com"
            )

            let entryIds = try await manager.write { db in
                var repairTarget = Entry(
                    id: nil,
                    feedId: feed.id!,
                    guid: "guid-conflict-001",
                    url: "https://example.com/feeds/123/comments/default",
                    title: "Wrong URL",
                    author: nil,
                    publishedAt: Date(),
                    summary: nil,
                    isRead: false,
                    isStarred: false,
                    createdAt: Date()
                )
                try repairTarget.insert(db)

                var conflictingEntry = Entry(
                    id: nil,
                    feedId: feed.id!,
                    guid: "guid-conflict-002",
                    url: "https://example.com/2026/03/article.html",
                    title: "Existing Correct URL",
                    author: nil,
                    publishedAt: Date(),
                    summary: nil,
                    isRead: false,
                    isStarred: false,
                    createdAt: Date()
                )
                try conflictingEntry.insert(db)

                return (try #require(repairTarget.id), try #require(conflictingEntry.id))
            }

            let atomEntry = AtomFeedEntry(
                title: "Wrong URL",
                links: [
                    atomLink(href: "https://example.com/feeds/123/comments/default", rel: "replies", type: "application/atom+xml"),
                    atomLink(href: "https://example.com/2026/03/article.html", rel: "alternate", type: "text/html")
                ],
                updated: Date(),
                id: "guid-conflict-001"
            )

            try await repairUseCase.verifyAndRepairIfNeeded(
                feed: feed,
                parsedFeed: .atom(AtomFeed(entries: [atomEntry])),
                onEvent: { event in
                    await recorder.record(event)
                }
            )

            let snapshot = try await manager.read { db in
                let entries = try Entry
                    .filter([entryIds.0, entryIds.1].contains(Column("id")))
                    .order(Column("id"))
                    .fetchAll(db)
                let repairedFeed = try Feed.filter(Column("id") == feed.id!).fetchOne(db)
                return (entries, repairedFeed)
            }

            #expect(snapshot.0.count == 2)
            #expect(snapshot.0.first(where: { $0.id == entryIds.0 })?.url == "https://example.com/feeds/123/comments/default")
            #expect(snapshot.0.first(where: { $0.id == entryIds.1 })?.url == "https://example.com/2026/03/article.html")
            #expect(snapshot.1?.feedParserVersion == FeedParserVersion.current)

            let events = await recorder.snapshot()
            #expect(events.count == 3)
            guard events.count == 3 else { return }

            switch events[0] {
            case .started(let payload):
                #expect(payload.repairCount == 1)
            default:
                Issue.record("Expected repair started event first")
            }

            switch events[1] {
            case .skipped(let payload):
                #expect(payload.skippedCount == 1)
                #expect(payload.skippedSamples.first?.reason == "url-conflict-with-another-entry")
            default:
                Issue.record("Expected repair skipped event second")
            }

            switch events[2] {
            case .completed(let payload):
                #expect(payload.repairCount == 0)
                #expect(payload.skippedCount == 1)
            default:
                Issue.record("Expected repair completed event third")
            }
        }
    }

    @Test("Feed parser repair marks parser version current when no URL differences are found")
    func feedParserRepairMarksParserVersionCurrentWhenNoDifferencesAreFound() async throws {
        try await InMemoryDatabaseFixture.withFixture { fixture in
            let manager = fixture.database
            let repairUseCase = FeedParserRepairUseCase(database: manager)

            let feed = try await makeFeed(
                manager: manager,
                title: "Already Correct Feed",
                feedURL: "https://example.com/feed",
                siteURL: "https://example.com"
            )

            let atomEntry = AtomFeedEntry(
                title: "Already Correct",
                links: [
                    atomLink(href: "https://example.com/2026/03/article.html", rel: "alternate", type: "text/html"),
                    atomLink(href: "https://example.com/2026/03/article.html", rel: "self", type: "text/html")
                ],
                updated: Date(),
                id: "guid-clean-001"
            )

            try await repairUseCase.verifyAndRepairIfNeeded(
                feed: feed,
                parsedFeed: .atom(AtomFeed(entries: [atomEntry]))
            )

            let repairedFeed = try await manager.read { db in
                try Feed.filter(Column("id") == feed.id!).fetchOne(db)
            }

            #expect(repairedFeed?.feedParserVersion == FeedParserVersion.current)
        }
    }

    private enum TestError: Error {
        case missingFeedID
        case missingEntryID
    }

    private func makeFeed(
        manager: DatabaseManager,
        title: String,
        feedURL: String,
        siteURL: String
    ) async throws -> Mercury.Feed {
        try await manager.write { db in
            var feed = Mercury.Feed(
                id: nil,
                title: title,
                feedURL: feedURL,
                siteURL: siteURL,
                lastFetchedAt: nil,
                createdAt: Date()
            )
            try feed.insert(db)
            return feed
        }
    }

    private func atomLink(href: String, rel: String?, type: String?) -> AtomFeedLink {
        AtomFeedLink(attributes: AtomFeedLinkAttributes(
            href: href,
            rel: rel,
            type: type
        ))
    }
}

private actor FeedParserRepairEventRecorder {
    private var events: [FeedParserRepairEvent] = []

    func record(_ event: FeedParserRepairEvent) {
        events.append(event)
    }

    func snapshot() -> [FeedParserRepairEvent] {
        events
    }
}
