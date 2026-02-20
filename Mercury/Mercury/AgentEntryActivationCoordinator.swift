import Foundation

enum AgentEntryActivationCoordinator {
    static func run(
        context: AgentEntryActivationContext,
        checkPersistedState: () async -> AgentPersistedStateCheckResult,
        onProjectPersisted: () async -> Void,
        onRequestRun: () async -> Void,
        onSkip: () async -> Void,
        onShowFetchFailedRetry: () async -> Void
    ) async {
        let persistedState = await checkPersistedState()
        let decision = AgentEntryActivationPipeline.decide(
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
