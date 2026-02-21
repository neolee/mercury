import Foundation

nonisolated struct SummaryControlSelection: Equatable {
    let targetLanguage: String
    let detailLevel: SummaryDetailLevel
}

nonisolated struct SummaryRuntimeSlot: Equatable {
    let entryId: Int64
    let targetLanguage: String
    let detailLevel: SummaryDetailLevel
}

nonisolated enum SummaryWaitingTrigger: Equatable {
    case manual
    case auto
}

nonisolated struct SummaryWaitingDecision: Equatable {
    let shouldKeepCurrent: Bool
    let ownersToCancel: [AgentRunOwner]
}

nonisolated struct SummaryWaitingCleanupDecision: Equatable {
    let ownersToAbandon: [AgentRunOwner]
}

nonisolated enum SummaryPolicy {
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

    static func decideWaiting(
        queuedOwner: AgentRunOwner,
        queuedTrigger: SummaryWaitingTrigger,
        displayedEntryId: Int64?,
        existingWaiting: [AgentRunOwner: SummaryWaitingTrigger]
    ) -> SummaryWaitingDecision {
        guard displayedEntryId == queuedOwner.entryId else {
            return SummaryWaitingDecision(
                shouldKeepCurrent: false,
                ownersToCancel: [queuedOwner]
            )
        }

        let otherOwners = existingWaiting.keys.filter { $0 != queuedOwner }
        switch queuedTrigger {
        case .manual:
            return SummaryWaitingDecision(
                shouldKeepCurrent: true,
                ownersToCancel: Array(otherOwners)
            )
        case .auto:
            let hasOtherManual = existingWaiting.contains { owner, trigger in
                owner != queuedOwner && trigger == .manual
            }
            if hasOtherManual {
                return SummaryWaitingDecision(
                    shouldKeepCurrent: false,
                    ownersToCancel: [queuedOwner]
                )
            }
            return SummaryWaitingDecision(
                shouldKeepCurrent: true,
                ownersToCancel: Array(otherOwners)
            )
        }
    }

    static func decideWaitingCleanupOnEntrySwitch(
        previousEntryId: Int64,
        nextSelectedEntryId: Int64?,
        existingWaiting: [AgentRunOwner: SummaryWaitingTrigger]
    ) -> SummaryWaitingCleanupDecision {
        guard previousEntryId != nextSelectedEntryId else {
            return SummaryWaitingCleanupDecision(ownersToAbandon: [])
        }

        let ownersToAbandon = existingWaiting.keys.filter { owner in
            owner.taskKind == .summary && owner.entryId == previousEntryId
        }
        return SummaryWaitingCleanupDecision(ownersToAbandon: ownersToAbandon)
    }
}
