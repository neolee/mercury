import FeedKit
import Foundation
import Testing
@testable import Mercury

@Suite("Feed RDF Support")
@MainActor
struct FeedRDFSupportTests {
    @Test("Maps RDF items and channel title")
    func mapsRDFItemsAndTitle() throws {
        let publishedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let item = RSSFeedItem(
            title: "RDF Item",
            link: "http://example.com/rdf-item",
            description: "RDF summary",
            author: "RDF Author",
            pubDate: publishedAt
        )
        let feed = Feed.rdf(
            RDFFeed(
                channel: RDFFeedChannel(title: "RDF Feed"),
                items: [item]
            )
        )

        let entries = FeedEntryMapper().makeEntries(
            from: feed,
            feedId: 42,
            baseURLString: "https://example.com"
        )
        let entry = try #require(entries.first)

        #expect(entries.count == 1)
        #expect(entry.feedId == 42)
        #expect(entry.guid == "http://example.com/rdf-item")
        #expect(entry.url == "https://example.com/rdf-item")
        #expect(entry.title == "RDF Item")
        #expect(entry.author == "RDF Author")
        #expect(entry.summary == "RDF summary")
        #expect(entry.publishedAt == publishedAt)
        #expect(FeedLoadUseCase.feedTitle(from: feed) == "RDF Feed")
    }

    @Test("RDF feed without channel or items produces no entries and no title")
    func emptyRDFFeedProducesNoEntriesOrTitle() {
        let feed = Feed.rdf(RDFFeed(channel: nil, items: nil))

        #expect(
            FeedEntryMapper().makeEntries(
                from: feed,
                feedId: 7,
                baseURLString: nil
            ).isEmpty
        )
        #expect(FeedLoadUseCase.feedTitle(from: feed) == nil)
    }
}
