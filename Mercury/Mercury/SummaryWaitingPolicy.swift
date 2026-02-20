import Foundation

enum SummaryWaitingTrigger: Equatable {
    case manual
    case auto
}

struct SummaryWaitingDecision: Equatable {
    let shouldKeepCurrent: Bool
    let ownersToCancel: [AgentRunOwner]
}

enum SummaryWaitingPolicy {
    static func decide(
        queuedOwner: AgentRunOwner,
        queuedTrigger: SummaryWaitingTrigger,
        displayedEntryId: Int64?,
        existingWaiting: [AgentRunOwner: SummaryWaitingTrigger]
    ) -> SummaryWaitingDecision {
        // Stale request: user already left this entry before queue placement settled.
        guard displayedEntryId == queuedOwner.entryId else {
            return SummaryWaitingDecision(
                shouldKeepCurrent: false,
                ownersToCancel: [queuedOwner]
            )
        }

        let otherOwners = existingWaiting.keys.filter { $0 != queuedOwner }
        switch queuedTrigger {
        case .manual:
            // Manual always replaces previous waiting intents.
            return SummaryWaitingDecision(
                shouldKeepCurrent: true,
                ownersToCancel: Array(otherOwners)
            )
        case .auto:
            // Keep existing manual waiting; do not enqueue auto behind it.
            let hasOtherManual = existingWaiting.contains { owner, trigger in
                owner != queuedOwner && trigger == .manual
            }
            if hasOtherManual {
                return SummaryWaitingDecision(
                    shouldKeepCurrent: false,
                    ownersToCancel: [queuedOwner]
                )
            }
            // Auto keeps latest-only among auto waits.
            return SummaryWaitingDecision(
                shouldKeepCurrent: true,
                ownersToCancel: Array(otherOwners)
            )
        }
    }
}
