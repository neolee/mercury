import Testing
@testable import Mercury

@Suite("Entry Note Persistence")
struct EntryNotePersistenceTests {
    @Test("Auto flush upserts changed non-empty draft")
    func autoFlushUpsertsChangedDraft() {
        let decision = EntryNotePersistencePolicy.decision(
            for: EntryNotePersistenceSnapshot(
                draftText: "New note",
                persistedText: "Old note",
                hasPersistedRecord: true
            ),
            trigger: .autoFlush
        )

        #expect(decision == .upsert(markdownText: "New note"))
    }

    @Test("Auto flush does not delete cleared persisted note")
    func autoFlushDoesNotDeleteClearedNote() {
        let decision = EntryNotePersistencePolicy.decision(
            for: EntryNotePersistenceSnapshot(
                draftText: "   ",
                persistedText: "Stored note",
                hasPersistedRecord: true
            ),
            trigger: .autoFlush
        )

        #expect(decision == .noChange)
    }

    @Test("Panel close deletes cleared persisted note")
    func panelCloseDeletesClearedPersistedNote() {
        let decision = EntryNotePersistencePolicy.decision(
            for: EntryNotePersistenceSnapshot(
                draftText: "\n",
                persistedText: "Stored note",
                hasPersistedRecord: true
            ),
            trigger: .panelClose
        )

        #expect(decision == .delete)
    }

    @Test("Entry switch does not rewrite unchanged stored note")
    func entrySwitchKeepsUnchangedStoredNote() {
        let decision = EntryNotePersistencePolicy.decision(
            for: EntryNotePersistenceSnapshot(
                draftText: "Stored note",
                persistedText: "Stored note",
                hasPersistedRecord: true
            ),
            trigger: .entrySwitch
        )

        #expect(decision == .noChange)
    }
}
