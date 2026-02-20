import Testing
@testable import Mercury

@Suite("Agent Entry Activation Pipeline")
struct AgentEntryActivationPipelineTests {
    @Test("Projects persisted state before any scheduling decision")
    func persistedStateTakesPriority() {
        let context = AgentEntryActivationContext(
            autoEnabled: true,
            displayedEntryId: 10,
            candidateEntryId: 10
        )
        let decision = AgentEntryActivationPipeline.decide(
            context: context,
            persistedState: .renderableAvailable
        )
        #expect(decision == .projectPersisted)
    }

    @Test("Requests run only when persisted state is missing and auto is enabled")
    func requestsRunWhenMissingAndAutoEnabled() {
        let context = AgentEntryActivationContext(
            autoEnabled: true,
            displayedEntryId: 10,
            candidateEntryId: 10
        )
        let decision = AgentEntryActivationPipeline.decide(
            context: context,
            persistedState: .renderableMissing
        )
        #expect(decision == .requestRun)
    }

    @Test("Skips scheduling when auto is disabled")
    func skipsWhenAutoDisabled() {
        let context = AgentEntryActivationContext(
            autoEnabled: false,
            displayedEntryId: 10,
            candidateEntryId: 10
        )
        let decision = AgentEntryActivationPipeline.decide(
            context: context,
            persistedState: .renderableMissing
        )
        #expect(decision == .skip)
    }

    @Test("Shows fetch-failed retry on persisted state check failure")
    func showRetryWhenPersistedFetchFails() {
        let context = AgentEntryActivationContext(
            autoEnabled: true,
            displayedEntryId: 10,
            candidateEntryId: 10
        )
        let decision = AgentEntryActivationPipeline.decide(
            context: context,
            persistedState: .fetchFailed
        )
        #expect(decision == .showFetchFailedRetry)
    }

    @Test("Skips when candidate is no longer selected")
    func skipsWhenCandidateIsStale() {
        let context = AgentEntryActivationContext(
            autoEnabled: true,
            displayedEntryId: 11,
            candidateEntryId: 10
        )
        #expect(
            AgentEntryActivationPipeline.decide(
                context: context,
                persistedState: .renderableAvailable
            ) == .skip
        )
        #expect(
            AgentEntryActivationPipeline.decide(
                context: context,
                persistedState: .renderableMissing
            ) == .skip
        )
    }
}
