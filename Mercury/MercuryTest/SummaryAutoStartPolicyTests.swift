import Testing
@testable import Mercury

@Suite("Summary Auto Start Policy")
struct SummaryAutoStartPolicyTests {
    @Test("Starts only when current entry matches and check is ready")
    func startsWhenReady() {
        let decision = SummaryAutoStartPolicy.decide(
            autoEnabled: true,
            displayedEntryId: 10,
            candidateEntryId: 10,
            checkResult: .renderableMissing
        )
        #expect(decision == .requestRun)
    }

    @Test("Skips when check reports persisted summary")
    func skipsWhenPersisted() {
        let decision = SummaryAutoStartPolicy.decide(
            autoEnabled: true,
            displayedEntryId: 10,
            candidateEntryId: 10,
            checkResult: .renderableAvailable
        )
        #expect(decision == .projectPersisted)
    }

    @Test("Shows fetch-failed retry and does not start")
    func showRetryWhenFetchFailed() {
        let decision = SummaryAutoStartPolicy.decide(
            autoEnabled: true,
            displayedEntryId: 10,
            candidateEntryId: 10,
            checkResult: .fetchFailed
        )
        #expect(decision == .showFetchFailedRetry)
    }

    @Test("Skips when candidate is no longer current displayed entry")
    func skipsWhenNotCurrent() {
        let decision = SummaryAutoStartPolicy.decide(
            autoEnabled: true,
            displayedEntryId: 11,
            candidateEntryId: 10,
            checkResult: .renderableMissing
        )
        #expect(decision == .skip)
    }

    @Test("Skips when auto is disabled")
    func skipsWhenDisabled() {
        #expect(
            SummaryAutoStartPolicy.decide(
                autoEnabled: false,
                displayedEntryId: 10,
                candidateEntryId: 10,
                checkResult: .renderableMissing
            ) == .skip
        )
    }
}
