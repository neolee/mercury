import Testing
@testable import Mercury

@Suite("Entry Delete Selection Handoff")
struct EntryDeleteSelectionHandoffTests {
    @Test("Deleting selected middle row hands off to next row and skips auto mark-read")
    func handoffSelectsNextRowFirst() {
        let view = ContentView()

        let fallback = view.makeDeleteSelectionFallbackEntryId(
            entryIDs: [11, 22, 33],
            deletingEntryId: 22,
            selectedEntryId: 22
        )

        #expect(fallback == 33)
        #expect(MarkReadPolicy.selectionOutcome(newId: 33, autoSelectedId: fallback) == .skipAutoMarkRead)
    }

    @Test("Deleting selected last row hands off to previous row")
    func handoffFallsBackToPreviousRow() {
        let view = ContentView()

        let fallback = view.makeDeleteSelectionFallbackEntryId(
            entryIDs: [11, 22, 33],
            deletingEntryId: 33,
            selectedEntryId: 33
        )

        #expect(fallback == 22)
    }

    @Test("Deleting only selected row clears selection")
    func handoffClearsSelectionWhenListBecomesEmpty() {
        let view = ContentView()

        let fallback = view.makeDeleteSelectionFallbackEntryId(
            entryIDs: [11],
            deletingEntryId: 11,
            selectedEntryId: 11
        )

        #expect(fallback == nil)
    }

    @Test("Delete handoff does not apply when deleting a non-selected row")
    func handoffIgnoredForNonSelectedRow() {
        let view = ContentView()

        let shouldApply = view.shouldApplyDeleteSelectionHandoff(
            selectedEntryId: 11,
            deletingEntryId: 22
        )
        let fallback = view.makeDeleteSelectionFallbackEntryId(
            entryIDs: [11, 22, 33],
            deletingEntryId: 22,
            selectedEntryId: 11
        )

        #expect(shouldApply == false)
        #expect(fallback == nil)
    }
}
