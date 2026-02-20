import Testing
@testable import Mercury

@Suite("Agent Entry Activation Decision")
struct AgentEntryActivationDecisionTests {
    @Test("Projects persisted state before any scheduling decision")
    func persistedStateTakesPriority() {
        let context = AgentEntryActivationContext(
            autoEnabled: true,
            displayedEntryId: 10,
            candidateEntryId: 10
        )
        let decision = AgentEntryActivation.decide(
            context: context,
            persistedState: .renderableAvailable
        )
        #expect(decision.isProjectPersisted)
    }

    @Test("Requests run only when persisted state is missing and auto is enabled")
    func requestsRunWhenMissingAndAutoEnabled() {
        let context = AgentEntryActivationContext(
            autoEnabled: true,
            displayedEntryId: 10,
            candidateEntryId: 10
        )
        let decision = AgentEntryActivation.decide(
            context: context,
            persistedState: .renderableMissing
        )
        #expect(decision.isRequestRun)
    }

    @Test("Skips scheduling when auto is disabled")
    func skipsWhenAutoDisabled() {
        let context = AgentEntryActivationContext(
            autoEnabled: false,
            displayedEntryId: 10,
            candidateEntryId: 10
        )
        let decision = AgentEntryActivation.decide(
            context: context,
            persistedState: .renderableMissing
        )
        #expect(decision.isSkip)
    }

    @Test("Shows fetch-failed retry on persisted state check failure")
    func showRetryWhenPersistedFetchFails() {
        let context = AgentEntryActivationContext(
            autoEnabled: true,
            displayedEntryId: 10,
            candidateEntryId: 10
        )
        let decision = AgentEntryActivation.decide(
            context: context,
            persistedState: .fetchFailed
        )
        #expect(decision.isShowFetchFailedRetry)
    }

    @Test("Skips when candidate is no longer selected")
    func skipsWhenCandidateIsStale() {
        let context = AgentEntryActivationContext(
            autoEnabled: true,
            displayedEntryId: 11,
            candidateEntryId: 10
        )
        #expect(
            AgentEntryActivation.decide(
                context: context,
                persistedState: .renderableAvailable
            ).isSkip
        )
        #expect(
            AgentEntryActivation.decide(
                context: context,
                persistedState: .renderableMissing
            ).isSkip
        )
    }
}

private extension AgentEntryActivationDecision {
    var isProjectPersisted: Bool {
        if case .projectPersisted = self {
            return true
        }
        return false
    }

    var isRequestRun: Bool {
        if case .requestRun = self {
            return true
        }
        return false
    }

    var isSkip: Bool {
        if case .skip = self {
            return true
        }
        return false
    }

    var isShowFetchFailedRetry: Bool {
        if case .showFetchFailedRetry = self {
            return true
        }
        return false
    }
}
