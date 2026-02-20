import Foundation

enum SummaryAutoStartDecision: Equatable {
    case projectPersisted
    case requestRun
    case skip
    case showFetchFailedRetry
}

enum SummaryAutoStartPolicy {
    static func decide(
        autoEnabled: Bool,
        displayedEntryId: Int64?,
        candidateEntryId: Int64,
        checkResult: AgentPersistedStateCheckResult
    ) -> SummaryAutoStartDecision {
        let context = AgentEntryActivationContext(
            autoEnabled: autoEnabled,
            displayedEntryId: displayedEntryId,
            candidateEntryId: candidateEntryId
        )
        let decision = AgentEntryActivationPipeline.decide(
            context: context,
            persistedState: checkResult
        )

        switch decision {
        case .projectPersisted:
            return .projectPersisted
        case .requestRun:
            return .requestRun
        case .skip:
            return .skip
        case .showFetchFailedRetry:
            return .showFetchFailedRetry
        }
    }
}
