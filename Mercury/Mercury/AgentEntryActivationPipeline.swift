import Foundation

enum AgentPersistedStateCheckResult: Equatable, Sendable {
    case renderableAvailable
    case renderableMissing
    case fetchFailed
}

struct AgentEntryActivationContext: Equatable, Sendable {
    let autoEnabled: Bool
    let displayedEntryId: Int64?
    let candidateEntryId: Int64
}

enum AgentEntryActivationDecision: Equatable, Sendable {
    case projectPersisted
    case requestRun
    case skip
    case showFetchFailedRetry
}

enum AgentEntryActivationPipeline {
    static func decide(
        context: AgentEntryActivationContext,
        persistedState: AgentPersistedStateCheckResult
    ) -> AgentEntryActivationDecision {
        guard context.displayedEntryId == context.candidateEntryId else {
            return .skip
        }

        switch persistedState {
        case .renderableAvailable:
            return .projectPersisted
        case .fetchFailed:
            return .showFetchFailedRetry
        case .renderableMissing:
            return context.autoEnabled ? .requestRun : .skip
        }
    }
}
