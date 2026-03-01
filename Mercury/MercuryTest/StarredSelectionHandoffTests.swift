import Testing
@testable import Mercury

@Suite("Starred Selection Handoff")
struct StarredSelectionHandoffTests {
    @Test("When un-starring selected middle row, handoff selects next row")
    func handoffSelectsNextRowFirst() {
        let view = ContentView()

        let fallback = view.makeStarredSelectionFallbackEntryId(
            entryIDs: [11, 22, 33],
            removingEntryId: 22,
            selectedEntryId: 22
        )

        #expect(fallback == 33)
        #expect(MarkReadPolicy.selectionOutcome(newId: 33, autoSelectedId: fallback) == .skipAutoMarkRead)
    }

    @Test("When un-starring selected last row, handoff selects previous row")
    func handoffFallsBackToPreviousRow() {
        let view = ContentView()

        let fallback = view.makeStarredSelectionFallbackEntryId(
            entryIDs: [11, 22, 33],
            removingEntryId: 33,
            selectedEntryId: 33
        )

        #expect(fallback == 22)
    }

    @Test("When un-starring only selected row, handoff clears selection")
    func handoffClearsSelectionWhenListBecomesEmpty() {
        let view = ContentView()

        let fallback = view.makeStarredSelectionFallbackEntryId(
            entryIDs: [11],
            removingEntryId: 11,
            selectedEntryId: 11
        )

        #expect(fallback == nil)
    }

    @Test("Handoff does not apply when target row is not selected")
    func handoffIgnoredForNonSelectedRow() {
        let view = ContentView()

        let fallback = view.makeStarredSelectionFallbackEntryId(
            entryIDs: [11, 22, 33],
            removingEntryId: 22,
            selectedEntryId: 11
        )

        #expect(fallback == nil)
    }
}
