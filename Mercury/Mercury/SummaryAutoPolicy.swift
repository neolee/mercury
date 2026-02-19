import Foundation

struct SummaryControlSelection: Equatable {
    let targetLanguage: String
    let detailLevel: AISummaryDetailLevel
}

struct SummaryRuntimeSlot: Equatable {
    let entryId: Int64
    let targetLanguage: String
    let detailLevel: AISummaryDetailLevel
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
        selectedEntryId: Int64?,
        runningEntryId: Int64?,
        summaryTextIsEmpty: Bool
    ) -> Bool {
        guard summaryTextIsEmpty else { return false }
        guard let selectedEntryId, let runningEntryId else { return false }
        return selectedEntryId != runningEntryId
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
