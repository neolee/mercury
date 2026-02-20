import Testing
@testable import Mercury

@Suite("Agent Runtime Projection")
struct AgentRuntimeProjectionTests {
    private let strings = AgentRuntimeDisplayStrings(
        noContent: "No content",
        loading: "Loading",
        waiting: "Waiting",
        requesting: "Requesting",
        generating: "Generating",
        persisting: "Persisting",
        fetchFailedRetry: "Retry"
    )

    @Test("Content suppresses placeholder regardless of other flags")
    func contentWins() {
        let text = AgentRuntimeProjection.placeholderText(
            input: AgentRuntimeProjectionInput(
                hasContent: true,
                isLoading: true,
                hasFetchFailure: true,
                hasPendingRequest: true,
                activePhase: .generating
            ),
            strings: strings
        )
        #expect(text == "")
    }

    @Test("Fetch failure has higher priority than loading and waiting")
    func fetchFailurePriority() {
        let text = AgentRuntimeProjection.placeholderText(
            input: AgentRuntimeProjectionInput(
                hasContent: false,
                isLoading: true,
                hasFetchFailure: true,
                hasPendingRequest: true,
                activePhase: .generating
            ),
            strings: strings
        )
        #expect(text == "Retry")
    }

    @Test("Loading has higher priority than waiting and run phase")
    func loadingPriority() {
        let text = AgentRuntimeProjection.placeholderText(
            input: AgentRuntimeProjectionInput(
                hasContent: false,
                isLoading: true,
                hasFetchFailure: false,
                hasPendingRequest: true,
                activePhase: .requesting
            ),
            strings: strings
        )
        #expect(text == "Loading")
    }

    @Test("Waiting has higher priority than run phase")
    func waitingPriority() {
        let text = AgentRuntimeProjection.placeholderText(
            input: AgentRuntimeProjectionInput(
                hasContent: false,
                isLoading: false,
                hasFetchFailure: false,
                hasPendingRequest: true,
                activePhase: .generating
            ),
            strings: strings
        )
        #expect(text == "Waiting")
    }

    @Test("Run phase maps to expected status text")
    func phaseMapping() {
        #expect(
            AgentRuntimeProjection.placeholderText(
                input: AgentRuntimeProjectionInput(
                    hasContent: false,
                    isLoading: false,
                    hasFetchFailure: false,
                    hasPendingRequest: false,
                    activePhase: .requesting
                ),
                strings: strings
            ) == "Requesting"
        )
        #expect(
            AgentRuntimeProjection.placeholderText(
                input: AgentRuntimeProjectionInput(
                    hasContent: false,
                    isLoading: false,
                    hasFetchFailure: false,
                    hasPendingRequest: false,
                    activePhase: .generating
                ),
                strings: strings
            ) == "Generating"
        )
        #expect(
            AgentRuntimeProjection.placeholderText(
                input: AgentRuntimeProjectionInput(
                    hasContent: false,
                    isLoading: false,
                    hasFetchFailure: false,
                    hasPendingRequest: false,
                    activePhase: .persisting
                ),
                strings: strings
            ) == "Persisting"
        )
        #expect(
            AgentRuntimeProjection.placeholderText(
                input: AgentRuntimeProjectionInput(
                    hasContent: false,
                    isLoading: false,
                    hasFetchFailure: false,
                    hasPendingRequest: false,
                    activePhase: nil
                ),
                strings: strings
            ) == "No content"
        )
    }
}
