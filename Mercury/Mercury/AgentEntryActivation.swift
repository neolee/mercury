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

enum AgentEntryActivation {
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

    static func run(
        context: AgentEntryActivationContext,
        checkPersistedState: () async -> AgentPersistedStateCheckResult,
        onProjectPersisted: () async -> Void,
        onRequestRun: () async -> Void,
        onSkip: () async -> Void,
        onShowFetchFailedRetry: () async -> Void
    ) async {
        let persistedState = await checkPersistedState()
        let decision = decide(
            context: context,
            persistedState: persistedState
        )

        switch decision {
        case .projectPersisted:
            await onProjectPersisted()
        case .requestRun:
            await onRequestRun()
        case .skip:
            await onSkip()
        case .showFetchFailedRetry:
            await onShowFetchFailedRetry()
        }
    }
}
