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

    @Test("Status projection trims empty status text and marks waiting")
    func statusProjectionNormalizesStatusText() {
        let state = AgentRunState(
            owner: AgentRunOwner(taskKind: .translation, entryId: 1, slotKey: "slot"),
            phase: .waiting,
            statusText: "   ",
            progress: nil,
            updatedAt: Date()
        )

        let projected = AgentRuntimeProjection.statusProjection(state: state)
        #expect(projected.statusText == nil)
        #expect(projected.isWaiting == true)
        #expect(projected.shouldRenderNoContentStatus == false)
    }

    @Test("Status projection marks terminal phases as no-content status")
    func statusProjectionMarksTerminalAsNoContent() {
        let state = AgentRunState(
            owner: AgentRunOwner(taskKind: .summary, entryId: 2, slotKey: "en|medium"),
            phase: .failed,
            statusText: nil,
            progress: nil,
            updatedAt: Date()
        )

        let projected = AgentRuntimeProjection.statusProjection(state: state)
        #expect(projected.shouldRenderNoContentStatus == true)
        #expect(projected.isWaiting == false)
    }
}
