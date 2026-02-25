import Foundation
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
            taskId: UUID(),
            owner: AgentRunOwner(taskKind: .translation, entryId: 1, slotKey: "slot"),
            phase: .waiting,
            statusText: "   ",
            progress: nil,
            activeToken: nil,
            terminalReason: nil,
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
            taskId: UUID(),
            owner: AgentRunOwner(taskKind: .summary, entryId: 2, slotKey: "en|medium"),
            phase: .failed,
            statusText: nil,
            progress: nil,
            activeToken: nil,
            terminalReason: nil,
            updatedAt: Date()
        )

        let projected = AgentRuntimeProjection.statusProjection(state: state)
        #expect(projected.shouldRenderNoContentStatus == true)
        #expect(projected.isWaiting == false)
    }

    @Test("Missing-content status prefers projected placeholder when no explicit status")
    func missingContentStatusUsesProjectedPlaceholder() {
        let projected = AgentRuntimeStatusProjection(
            phase: .generating,
            statusText: nil,
            isWaiting: false,
            shouldRenderNoContentStatus: false
        )

        let status = AgentRuntimeProjection.missingContentStatusText(
            projection: projected,
            cachedStatus: nil,
            transientStatuses: [],
            noContentStatus: "No translation",
            strings: strings
        )
        #expect(status == "Generating")
    }

    @Test("Missing-content status falls back to no-content for transient cached status")
    func missingContentStatusDropsTransientCache() {
        let status = AgentRuntimeProjection.missingContentStatusText(
            projection: nil,
            cachedStatus: "Generating...",
            transientStatuses: ["Generating..."],
            noContentStatus: "No translation",
            strings: strings
        )
        #expect(status == "No translation")
    }

    @Test("Summary placeholder helper maps requesting phase")
    @MainActor func summaryPlaceholderRequesting() {
        withEnglishLanguage {
            let text = AgentRuntimeProjection.summaryPlaceholderText(
                hasContent: false,
                isLoading: false,
                hasFetchFailure: false,
                hasPendingRequest: false,
                activePhase: .requesting
            )
            #expect(text == "Requesting...")
        }
    }

    @Test("Translation missing-status helper maps waiting projection")
    @MainActor func translationMissingStatusUsesWaitingText() {
        withEnglishLanguage {
            let projected = AgentRuntimeStatusProjection(
                phase: .waiting,
                statusText: nil,
                isWaiting: true,
                shouldRenderNoContentStatus: false
            )

            let text = AgentRuntimeProjection.translationMissingStatusText(
                projection: projected,
                cachedPhase: nil,
                noContentStatus: "No translation",
                fetchFailedRetryStatus: "Retry"
            )
            #expect(text == "Waiting for last generation to finish...")
        }
    }

    @Test("Translation phase status helper maps terminal and generating phases")
    @MainActor func translationPhaseStatusHelper() {
        withEnglishLanguage {
            #expect(AgentRuntimeProjection.translationStatusText(for: .generating) == "Generating...")
            #expect(
                AgentRuntimeProjection.translationStatusText(for: .failed)
                == AgentRuntimeProjection.translationNoContentStatus()
            )
        }
    }

    @Test("Summary status constants are centralized")
    @MainActor func summaryStatusConstants() {
        withEnglishLanguage {
            #expect(AgentRuntimeProjection.summaryNoContentStatus() == "No summary")
            #expect(AgentRuntimeProjection.summaryCancelledStatus() == "Cancelled.")
        }
    }

    @MainActor
    private func withEnglishLanguage(_ body: () -> Void) {
        let originalOverride = LanguageManager.shared.languageOverride
        defer {
            LanguageManager.shared.setLanguage(originalOverride)
        }
        LanguageManager.shared.setLanguage("en")
        body()
    }
}
