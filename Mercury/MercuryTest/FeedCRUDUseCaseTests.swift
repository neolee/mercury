import Foundation
import FeedKit
import GRDB
import Testing
import XMLKit
@testable import Mercury

@Suite("Feed CRUD Use Case")
struct FeedCRUDUseCaseTests {
    @Test("Adding a verified feed persists entries and fetch timestamp in one save flow")
    func addVerifiedFeedPersistsEntriesImmediately() async throws {
        try await InMemoryDatabaseFixture.withFixture { fixture in
            let database = fixture.database
            let useCase = FeedCRUDUseCase(
                database: database,
                feedLoadUseCase: FeedLoadUseCase(jobRunner: JobRunner()),
                feedEntryMapper: FeedEntryMapper(),
                validator: FeedInputValidator(database: database)
            )

            let verifiedFeed = FeedLoadUseCase.VerifiedFeed(
                feedURL: "https://example.com/feed",
                parsedFeed: .atom(
                    AtomFeed(
                        entries: [
                            AtomFeedEntry(
                                title: "Mercury ships validated add-feed flow",
                                links: [
                                    Self.atomLink(
                                        href: "https://example.com/articles/validated-add-feed",
                                        rel: "alternate",
                                        type: "text/html"
                                    )
                                ],
                                updated: Date(),
                                id: "entry-001"
                            )
                        ]
                    )
                ),
                title: "Example Feed"
            )

            let persistedFeed = try await useCase.addFeed(
                title: nil,
                feedURL: verifiedFeed.feedURL,
                siteURL: "https://example.com",
                verifiedFeed: verifiedFeed
            )

            let snapshot = try await database.read { db in
                let storedFeed = try Feed.filter(Column("id") == persistedFeed.id!).fetchOne(db)
                let storedEntries = try Entry
                    .filter(Column("feedId") == persistedFeed.id!)
                    .fetchAll(db)
                return (storedFeed, storedEntries)
            }

            #expect(snapshot.0?.title == "Example Feed")
            #expect(snapshot.0?.lastFetchedAt != nil)
            #expect(snapshot.1.count == 1)
            #expect(snapshot.1.first?.guid == "entry-001")
            #expect(snapshot.1.first?.url == "https://example.com/articles/validated-add-feed")
        }
    }

    @Test("Editing metadata without changing the feed URL preserves lastFetchedAt")
    func updateFeedMetadataPreservesFetchTimestamp() async throws {
        try await InMemoryDatabaseFixture.withFixture { fixture in
            let database = fixture.database
            let useCase = FeedCRUDUseCase(
                database: database,
                feedLoadUseCase: FeedLoadUseCase(jobRunner: JobRunner()),
                feedEntryMapper: FeedEntryMapper(),
                validator: FeedInputValidator(database: database)
            )

            let fetchedAt = Date().addingTimeInterval(-600)
            let feed = try await database.write { db in
                var feed = Feed(
                    id: nil,
                    title: "Old Title",
                    feedURL: "https://example.com/feed",
                    siteURL: "https://example.com",
                    lastFetchedAt: fetchedAt,
                    createdAt: Date()
                )
                try feed.insert(db)
                return feed
            }

            let updatedFeed = try await useCase.updateFeed(
                feed,
                title: "New Title",
                feedURL: feed.feedURL,
                siteURL: feed.siteURL
            )

            #expect(updatedFeed.title == "New Title")
            #expect(updatedFeed.lastFetchedAt == fetchedAt)
        }
    }

    private static func atomLink(href: String, rel: String, type: String) -> AtomFeedLink {
        AtomFeedLink(attributes: AtomFeedLinkAttributes(
            href: href,
            rel: rel,
            type: type
        ))
    }
}
