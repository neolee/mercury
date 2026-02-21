import Testing
@testable import Mercury

@Suite("Agent Entry Activation Runner")
struct AgentEntryActivationRunnerTests {
    @Test("Runs persisted-state check first and then executes the selected action")
    func checksFirstThenRunsSelectedAction() async {
        let context = AgentEntryActivationContext(
            autoEnabled: true,
            displayedEntryId: 1,
            candidateEntryId: 1
        )
        var trace: [String] = []

        await AgentEntryActivation.run(
            context: context,
            checkPersistedState: {
                trace.append("check")
                return .renderableAvailable
            },
            onProjectPersisted: {
                trace.append("project")
            },
            onRequestRun: {
                trace.append("request")
            },
            onSkip: {
                trace.append("skip")
            },
            onShowFetchFailedRetry: {
                trace.append("retry")
            }
        )

        #expect(trace == ["check", "project"])
    }

    @Test("Routes missing persisted state to request run")
    func routesMissingStateToRequest() async {
        let context = AgentEntryActivationContext(
            autoEnabled: true,
            displayedEntryId: 1,
            candidateEntryId: 1
        )
        var trace: [String] = []

        await AgentEntryActivation.run(
            context: context,
            checkPersistedState: {
                trace.append("check")
                return .renderableMissing
            },
            onProjectPersisted: {
                trace.append("project")
            },
            onRequestRun: {
                trace.append("request")
            },
            onSkip: {
                trace.append("skip")
            },
            onShowFetchFailedRetry: {
                trace.append("retry")
            }
        )

        #expect(trace == ["check", "request"])
    }

    @Test("Routes fetch failure to retry action")
    func routesFetchFailureToRetry() async {
        let context = AgentEntryActivationContext(
            autoEnabled: true,
            displayedEntryId: 1,
            candidateEntryId: 1
        )
        var trace: [String] = []

        await AgentEntryActivation.run(
            context: context,
            checkPersistedState: {
                trace.append("check")
                return .fetchFailed
            },
            onProjectPersisted: {
                trace.append("project")
            },
            onRequestRun: {
                trace.append("request")
            },
            onSkip: {
                trace.append("skip")
            },
            onShowFetchFailedRetry: {
                trace.append("retry")
            }
        )

        #expect(trace == ["check", "retry"])
    }
}
