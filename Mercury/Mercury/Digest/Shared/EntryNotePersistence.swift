import Foundation

nonisolated enum EntryNotePersistenceTrigger: Equatable, Sendable {
    case autoFlush
    case panelClose
    case entrySwitch
    case appBackground
    case shareOrExportConsumption

    var deletesEmptyPersistedNote: Bool {
        switch self {
        case .panelClose, .entrySwitch:
            return true
        case .autoFlush, .appBackground, .shareOrExportConsumption:
            return false
        }
    }
}

nonisolated enum EntryNotePersistenceDecision: Equatable, Sendable {
    case noChange
    case upsert(markdownText: String)
    case delete
}

nonisolated struct EntryNotePersistenceSnapshot: Equatable, Sendable {
    var draftText: String
    var persistedText: String
    var hasPersistedRecord: Bool
}

enum EntryNotePersistencePolicy {
    static func decision(
        for snapshot: EntryNotePersistenceSnapshot,
        trigger: EntryNotePersistenceTrigger
    ) -> EntryNotePersistenceDecision {
        let normalizedDraft = snapshot.draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPersisted = snapshot.persistedText.trimmingCharacters(in: .whitespacesAndNewlines)

        if normalizedDraft.isEmpty {
            if trigger.deletesEmptyPersistedNote && snapshot.hasPersistedRecord {
                return .delete
            }
            return .noChange
        }

        if snapshot.hasPersistedRecord && snapshot.draftText == snapshot.persistedText {
            return .noChange
        }

        if snapshot.hasPersistedRecord == false && normalizedPersisted.isEmpty == false && snapshot.draftText == snapshot.persistedText {
            return .noChange
        }

        return .upsert(markdownText: snapshot.draftText)
    }
}
