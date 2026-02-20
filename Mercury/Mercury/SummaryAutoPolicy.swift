import Foundation

struct SummaryControlSelection: Equatable {
    let targetLanguage: String
    let detailLevel: SummaryDetailLevel
}

struct SummaryRuntimeSlot: Equatable {
    let entryId: Int64
    let targetLanguage: String
    let detailLevel: SummaryDetailLevel
}

enum SummaryAutoPolicy {
    static func resolveControlSelection(
        selectedEntryId: Int64,
        runningSlot: SummaryRuntimeSlot?,
        latestPersistedSlot: SummaryRuntimeSlot?,
        defaults: SummaryControlSelection
    ) -> SummaryControlSelection {
        if let runningSlot, runningSlot.entryId == selectedEntryId {
            return SummaryControlSelection(
                targetLanguage: runningSlot.targetLanguage,
                detailLevel: runningSlot.detailLevel
            )
        }
        if let latestPersistedSlot {
            return SummaryControlSelection(
                targetLanguage: latestPersistedSlot.targetLanguage,
                detailLevel: latestPersistedSlot.detailLevel
            )
        }
        return defaults
    }

    static func shouldMarkCurrentEntryPersistedOnCompletion(
        completedEntryId: Int64,
        displayedEntryId: Int64?
    ) -> Bool {
        displayedEntryId == completedEntryId
    }

    static func shouldShowWaitingPlaceholder(
        summaryTextIsEmpty: Bool,
        hasPendingRequestForSelectedEntry: Bool
    ) -> Bool {
        guard summaryTextIsEmpty else { return false }
        return hasPendingRequestForSelectedEntry
    }

    static func shouldStartAutoRunNow(
        autoEnabled: Bool,
        isSummaryRunning: Bool,
        hasPersistedSummaryForCurrentEntry: Bool,
        selectedEntryId: Int64?
    ) -> Bool {
        guard autoEnabled else { return false }
        guard isSummaryRunning == false else { return false }
        guard hasPersistedSummaryForCurrentEntry == false else { return false }
        return selectedEntryId != nil
    }
}
