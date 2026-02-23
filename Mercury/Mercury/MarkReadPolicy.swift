//
//  MarkReadPolicy.swift
//  Mercury
//

/// Pure decision logic for the per-entry manual and auto mark-read feature.
///
/// All methods are stateless value-type functions with no side effects.
/// `ContentView` and its extensions delegate every decision to these methods
/// so the logic can be unit-tested without any view infrastructure.
enum MarkReadPolicy {

    // MARK: - Selection change outcome

    /// Outcome returned when the user's entry selection changes to a non-nil entry.
    enum SelectionOutcome: Equatable, Sendable {
        /// The selection was an explicit user action — schedule the 3-second
        /// auto mark-read debounce and clear the auto-selection guard.
        case scheduleAutoMarkRead
        /// The selection was made automatically (e.g. `loadEntries(selectFirst: true)`);
        /// do not schedule auto mark-read and keep the guard in place.
        case skipAutoMarkRead

        // Explicit nonisolated implementation so the conformance witness is not
        // inferred as @MainActor from the surrounding app module context.
        nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case (.scheduleAutoMarkRead, .scheduleAutoMarkRead): return true
            case (.skipAutoMarkRead, .skipAutoMarkRead): return true
            default: return false
            }
        }
    }

    /// Determines what should happen when `selectedEntryId` changes to `newId`.
    ///
    /// Returns `.scheduleAutoMarkRead` unless `newId` exactly matches
    /// `autoSelectedId`, which means the selection was driven by a list reload
    /// rather than a direct user tap.
    static func selectionOutcome(newId: Int64, autoSelectedId: Int64?) -> SelectionOutcome {
        newId == autoSelectedId ? .skipAutoMarkRead : .scheduleAutoMarkRead
    }

    // MARK: - Auto mark-read execution guard

    /// Returns `true` when the deferred 3-second auto mark-read task should
    /// proceed to write the read state.
    ///
    /// All three conditions must hold simultaneously:
    /// 1. The user is still viewing the same entry (`currentSelectedEntryId`).
    /// 2. The user did not manually mark the entry unread during the delay
    ///    (`suppressedEntryId`).
    /// 3. The entry is still unread (`isAlreadyRead == false`).
    static func shouldExecuteAutoMarkRead(
        targetEntryId: Int64,
        currentSelectedEntryId: Int64?,
        suppressedEntryId: Int64?,
        isAlreadyRead: Bool
    ) -> Bool {
        guard currentSelectedEntryId == targetEntryId else { return false }
        guard suppressedEntryId != targetEntryId else { return false }
        guard isAlreadyRead == false else { return false }
        return true
    }

    // MARK: - Menu item availability

    /// Returns `true` when the "Mark Read" action should be enabled.
    /// Requires a selected entry that is currently unread.
    static func canMarkRead(selectedEntry: EntryListItem?) -> Bool {
        guard let entry = selectedEntry else { return false }
        return entry.isRead == false
    }

    /// Returns `true` when the "Mark Unread" action should be enabled.
    /// Requires a selected entry that is currently read.
    static func canMarkUnread(selectedEntry: EntryListItem?) -> Bool {
        guard let entry = selectedEntry else { return false }
        return entry.isRead == true
    }
}
