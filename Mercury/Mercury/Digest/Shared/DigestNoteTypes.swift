import Foundation

enum DigestNoteSaveState: Equatable {
    case idle
    case saving
    case saved
    case failed
}

struct DigestNoteEditorSnapshot: Equatable {
    let entryId: Int64
    let draftText: String
    let persistedText: String
    let hasPersistedRecord: Bool
}
