import Testing
@testable import Mercury

@Suite("Content View Multiple Digest Selection")
@MainActor
struct ContentViewMultipleDigestSelectionTests {
    @Test("Ordered multiple digest selection follows entry list order instead of click order")
    func orderedSelectionFollowsEntryListOrder() {
        let view = ContentView()

        let ordered = view.orderedMultipleDigestSelection(
            entryIDs: [11, 22, 33, 44],
            selectedEntryIDs: [44, 22]
        )

        #expect(ordered == [22, 44])
    }
}
