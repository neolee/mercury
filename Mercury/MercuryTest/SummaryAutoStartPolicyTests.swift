import Testing
@testable import Mercury

@Suite("Summary Auto Start Policy")
struct SummaryAutoStartPolicyTests {
    @Test("Starts only when current entry matches and check is ready")
    func startsWhenReady() {
        let decision = SummaryAutoStartPolicy.decide(
            autoEnabled: true,
            isSummaryRunning: false,
            displayedEntryId: 10,
            candidateEntryId: 10,
            checkResult: .ready
        )
        #expect(decision == .start)
    }

    @Test("Skips when check reports persisted summary")
    func skipsWhenPersisted() {
        let decision = SummaryAutoStartPolicy.decide(
            autoEnabled: true,
            isSummaryRunning: false,
            displayedEntryId: 10,
            candidateEntryId: 10,
            checkResult: .hasPersistedSummary
        )
        #expect(decision == .skip)
    }

    @Test("Shows fetch-failed retry and does not start")
    func showRetryWhenFetchFailed() {
        let decision = SummaryAutoStartPolicy.decide(
            autoEnabled: true,
            isSummaryRunning: false,
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
            isSummaryRunning: false,
            displayedEntryId: 11,
            candidateEntryId: 10,
            checkResult: .ready
        )
        #expect(decision == .skip)
    }

    @Test("Skips when auto is disabled or run already active")
    func skipsWhenDisabledOrRunning() {
        #expect(
            SummaryAutoStartPolicy.decide(
                autoEnabled: false,
                isSummaryRunning: false,
                displayedEntryId: 10,
                candidateEntryId: 10,
                checkResult: .ready
            ) == .skip
        )
        #expect(
            SummaryAutoStartPolicy.decide(
                autoEnabled: true,
                isSummaryRunning: true,
                displayedEntryId: 10,
                candidateEntryId: 10,
                checkResult: .ready
            ) == .skip
        )
    }
}
