import Testing
@testable import Mercury

@Suite("Entry Loading Routing")
struct EntryLoadingRoutingTests {
    @Test("Selection-based query construction routes .all/.starred/.feed")
    func selectionRoutingBuildsExpectedQuery() {
        let view = ContentView()

        let allQuery = view.makeEntryListQuery(
            selection: .all,
            unreadOnly: true,
            keepEntryId: nil,
            searchText: "swift",
            searchScope: .allFeeds
        )
        #expect(allQuery.feedId == nil)
        #expect(allQuery.starredOnly == false)
        #expect(allQuery.unreadOnly == true)

        let starredQuery = view.makeEntryListQuery(
            selection: .starred,
            unreadOnly: false,
            keepEntryId: nil,
            searchText: nil,
            searchScope: .currentFeed
        )
        #expect(starredQuery.feedId == nil)
        #expect(starredQuery.starredOnly == true)

        let feedScopedQuery = view.makeEntryListQuery(
            selection: .feed(42),
            unreadOnly: false,
            keepEntryId: 100,
            searchText: "feed",
            searchScope: .currentFeed
        )
        #expect(feedScopedQuery.feedId == 42)
        #expect(feedScopedQuery.starredOnly == false)
        #expect(feedScopedQuery.keepEntryId == 100)

        let feedAllFeedsQuery = view.makeEntryListQuery(
            selection: .feed(42),
            unreadOnly: false,
            keepEntryId: nil,
            searchText: nil,
            searchScope: .allFeeds
        )
        #expect(feedAllFeedsQuery.feedId == nil)
        #expect(feedAllFeedsQuery.starredOnly == false)
    }
}
