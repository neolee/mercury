import Foundation

extension AppModel {
    func loadEntryNote(entryId: Int64) async throws -> EntryNote? {
        try await entryNoteStore.load(entryId: entryId)
    }

    @discardableResult
    func upsertEntryNote(entryId: Int64, markdownText: String) async throws -> EntryNote {
        try await entryNoteStore.upsert(entryId: entryId, markdownText: markdownText)
    }

    @discardableResult
    func deleteEntryNote(entryId: Int64) async throws -> Bool {
        try await entryNoteStore.delete(entryId: entryId)
    }
}
