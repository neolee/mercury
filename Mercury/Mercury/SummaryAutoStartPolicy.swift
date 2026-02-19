import Foundation

enum SummaryAutoStartCheckResult: Equatable {
    case ready
    case hasPersistedSummary
    case fetchFailed
}

enum SummaryAutoStartDecision: Equatable {
    case start
    case skip
    case showFetchFailedRetry
}

enum SummaryAutoStartPolicy {
    static func decide(
        autoEnabled: Bool,
        isSummaryRunning: Bool,
        displayedEntryId: Int64?,
        candidateEntryId: Int64,
        checkResult: SummaryAutoStartCheckResult
    ) -> SummaryAutoStartDecision {
        guard autoEnabled else { return .skip }
        guard isSummaryRunning == false else { return .skip }
        guard displayedEntryId == candidateEntryId else { return .skip }

        switch checkResult {
        case .ready:
            return .start
        case .hasPersistedSummary:
            return .skip
        case .fetchFailed:
            return .showFetchFailedRetry
        }
    }
}
