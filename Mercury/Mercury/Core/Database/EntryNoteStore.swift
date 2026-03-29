import Foundation
import GRDB

enum EntryNoteStoreError: LocalizedError {
    case markdownTextRequired

    var errorDescription: String? {
        switch self {
        case .markdownTextRequired:
            return "Entry note markdown text is required."
        }
    }
}

@MainActor
final class EntryNoteStore {
    private let db: DatabaseManager

    init(db: DatabaseManager) {
        self.db = db
    }

    func load(entryId: Int64) async throws -> EntryNote? {
        try await db.read { db in
            try EntryNote
                .filter(Column("entryId") == entryId)
                .fetchOne(db)
        }
    }

    @discardableResult
    func upsert(entryId: Int64, markdownText: String) async throws -> EntryNote {
        guard markdownText.isEmpty == false else {
            throw EntryNoteStoreError.markdownTextRequired
        }

        let now = Date()

        return try await db.write { db in
            if var existing = try EntryNote
                .filter(Column("entryId") == entryId)
                .fetchOne(db) {
                existing.markdownText = markdownText
                existing.updatedAt = now
                try existing.update(db)
                return existing
            }

            var note = EntryNote(
                entryId: entryId,
                markdownText: markdownText,
                createdAt: now,
                updatedAt: now
            )
            try note.insert(db)
            return note
        }
    }

    @discardableResult
    func delete(entryId: Int64) async throws -> Bool {
        try await db.write { db in
            if let note = try EntryNote
                .filter(Column("entryId") == entryId)
                .fetchOne(db) {
                try note.delete(db)
                return true
            }
            return false
        }
    }
}
