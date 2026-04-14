import Foundation
import Testing
@testable import Mercury

@Suite("Agent Runtime Projection")
@MainActor
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

    @Test("Reader-bound tasks use reader banner host")
    func readerBoundTasksUseReaderBannerHost() {
        #expect(AgentMessagePresentation.policy(for: .summary).primaryMessageHost == .readerTopBanner)
        #expect(AgentMessagePresentation.policy(for: .translation).primaryMessageHost == .readerTopBanner)
        #expect(AgentMessagePresentation.policy(for: .tagging).primaryMessageHost == .readerTopBanner)
    }

    @Test("Batch tagging uses sheet footer message area")
    func batchTaggingUsesSheetFooterHost() {
        let policy = AgentMessagePresentation.policy(for: .taggingBatch)
        #expect(policy.primaryMessageHost == .batchSheetFooterMessageArea)
        #expect(policy.allowsInlineNoticeDuringRun == true)
    }

    @Test("Reader banner arbitration drops incoming message for non-displayed entry")
    func arbitrationDropsNonDisplayedEntry() {
        let current = makeCandidate(
            taskKind: .summary,
            entryId: 7,
            requestSource: .manual,
            createdAt: Date(timeIntervalSinceReferenceDate: 10),
            text: "Current"
        )
        let incoming = makeCandidate(
            taskKind: .translation,
            entryId: 8,
            requestSource: .manual,
            createdAt: Date(timeIntervalSinceReferenceDate: 20),
            text: "Incoming"
        )

        let winner = AgentMessagePresentation.arbitrateReaderBanner(
            current: current,
            incoming: incoming,
            displayedEntryId: 7
        )
        #expect(winner == current)
    }

    @Test("Reader banner arbitration prefers manual over automatic messages")
    func arbitrationPrefersManual() {
        let current = makeCandidate(
            taskKind: .summary,
            entryId: 7,
            requestSource: .auto,
            createdAt: Date(timeIntervalSinceReferenceDate: 10),
            text: "Auto"
        )
        let incoming = makeCandidate(
            taskKind: .translation,
            entryId: 7,
            requestSource: .manual,
            createdAt: Date(timeIntervalSinceReferenceDate: 5),
            text: "Manual"
        )

        let winner = AgentMessagePresentation.arbitrateReaderBanner(
            current: current,
            incoming: incoming,
            displayedEntryId: 7
        )
        #expect(winner == incoming)
    }

    @Test("Reader banner arbitration prefers messages with actions")
    func arbitrationPrefersActions() {
        let current = makeCandidate(
            taskKind: .summary,
            entryId: 7,
            requestSource: .manual,
            createdAt: Date(timeIntervalSinceReferenceDate: 10),
            text: "No Action"
        )
        let incoming = makeCandidate(
            taskKind: .translation,
            entryId: 7,
            requestSource: .manual,
            createdAt: Date(timeIntervalSinceReferenceDate: 5),
            text: "Has Action",
            primaryAction: AgentProjectedMessageAction(id: .openSettings, label: "Open Settings")
        )

        let winner = AgentMessagePresentation.arbitrateReaderBanner(
            current: current,
            incoming: incoming,
            displayedEntryId: 7
        )
        #expect(winner == incoming)
    }

    @Test("Reader banner arbitration prefers newer message when priorities tie")
    func arbitrationPrefersNewerWhenPriorityTies() {
        let current = makeCandidate(
            taskKind: .summary,
            entryId: 7,
            requestSource: .manual,
            createdAt: Date(timeIntervalSinceReferenceDate: 10),
            text: "Older"
        )
        let incoming = makeCandidate(
            taskKind: .translation,
            entryId: 7,
            requestSource: .manual,
            createdAt: Date(timeIntervalSinceReferenceDate: 20),
            text: "Newer"
        )

        let winner = AgentMessagePresentation.arbitrateReaderBanner(
            current: current,
            incoming: incoming,
            displayedEntryId: 7
        )
        #expect(winner == incoming)
    }

    @Test("Legacy reader banner bridges to shared host model")
    func legacyReaderBannerBridgesToSharedHostModel() {
        let banner = ReaderBannerMessage(
            text: "Need attention",
            severity: .error,
            action: .init(label: "Open Settings", handler: {}),
            secondaryAction: .init(label: "Open Debug Issues", handler: {})
        )

        let model = AgentMessageHostAdapter.readerBannerModel(from: banner)
        #expect(model?.primaryText == "Need attention")
        #expect(model?.severity == .error)
        #expect(model?.primaryActionLabel == "Open Settings")
        #expect(model?.secondaryActionLabel == "Open Debug Issues")
    }

    @Test("Projected batch footer message bridges to shared host model")
    func projectedBatchFooterBridgesToSharedHostModel() {
        let projected = AgentProjectedMessage(
            primaryText: "Batch warning",
            secondaryText: "Check scope before continuing.",
            severity: .warning,
            primaryAction: nil,
            secondaryAction: nil,
            host: .batchSheetFooterMessageArea
        )

        let model = AgentMessageHostAdapter.batchSheetFooterModel(from: projected)
        #expect(model?.primaryText == "Batch warning")
        #expect(model?.secondaryText == "Check scope before continuing.")
        #expect(model?.severity == .warning)
    }

    @Test("Projected host adapter rejects mismatched host")
    func projectedHostAdapterRejectsMismatchedHost() {
        let projected = AgentProjectedMessage(
            primaryText: "Reader only",
            secondaryText: nil,
            severity: .info,
            primaryAction: nil,
            secondaryAction: nil,
            host: .readerTopBanner
        )

        #expect(AgentMessageHostAdapter.batchSheetFooterModel(from: projected) == nil)
    }

    @MainActor @Test("Projected reader banner bridges custom action handlers")
    func projectedReaderBannerBridgesCustomHandlers() {
        let projected = AgentProjectedMessage(
            primaryText: "Need configuration",
            secondaryText: nil,
            severity: .warning,
            primaryAction: AgentProjectedMessageAction(id: .openSettings, label: "Open Settings"),
            secondaryAction: nil,
            host: .readerTopBanner
        )

        let banner = AgentMessageHostAdapter.readerBannerMessage(
            from: projected,
            actionHandler: { actionID in
                switch actionID {
                case .openSettings:
                    return {}
                default:
                    return nil
                }
            }
        )

        #expect(banner?.text == "Need configuration")
        #expect(banner?.severity == .warning)
        #expect(banner?.action?.label == "Open Settings")
    }

    @Test("Summary typed notice projects shared prompt fallback message")
    @MainActor func summaryTypedNoticeProjectsPromptFallbackMessage() {
        withEnglishLanguage {
            let message = AgentRuntimeProjection.summaryNoticeMessage(
                .promptTemplateFallback(.invalidCustomTemplate)
            )
            #expect(message == "Custom Summary prompt is invalid. Using built-in prompt.")
        }
    }

    @Test("Translation typed notice projects shared prompt fallback message")
    @MainActor func translationTypedNoticeProjectsPromptFallbackMessage() {
        withEnglishLanguage {
            let message = AgentRuntimeProjection.translationNoticeMessage(
                .promptTemplateFallback(.invalidCustomTemplate)
            )
            #expect(message == "Custom Translation prompt is invalid. Using built-in prompt.")
        }
    }

    @Test("Tagging typed notice projects shared prompt fallback message")
    @MainActor func taggingTypedNoticeProjectsPromptFallbackMessage() {
        withEnglishLanguage {
            let message = AgentRuntimeProjection.taggingNoticeMessage(
                .promptTemplateFallback(.invalidCustomTemplate)
            )
            #expect(message == "Custom Tagging prompt is invalid. Using built-in prompt.")
        }
    }

    @Test("Translation version mismatch notice projects dedicated prompt fallback message")
    @MainActor func translationVersionMismatchNoticeProjectsDedicatedPromptFallbackMessage() {
        withEnglishLanguage {
            let message = AgentRuntimeProjection.translationNoticeMessage(
                .promptTemplateFallback(.versionMismatch(customVersion: "v2", builtInVersion: "v4"))
            )
            #expect(
                message
                    == "Custom Translation prompt template version (v2) does not match the built-in version (v4). Using built-in prompt."
            )
        }
    }

    @Test("Availability projected message includes settings action")
    @MainActor func availabilityProjectedMessageIncludesSettingsAction() {
        withEnglishLanguage {
            let projected = AgentRuntimeProjection.availabilityProjectedMessage(
                for: .summary,
                summaryAvailable: false,
                translationAvailable: false,
                taggingAvailable: false
            )

            #expect(projected.host == .readerTopBanner)
            #expect(projected.primaryAction?.id == .openSettings)
            #expect(projected.primaryAction?.label == "Open Settings")
        }
    }

    @Test("Translation partial completion projected message includes retry action")
    @MainActor func translationPartialCompletionProjectedMessageIncludesRetryAction() {
        withEnglishLanguage {
            let projected = AgentRuntimeProjection.translationPartialCompletionProjectedMessage()

            #expect(projected.host == .readerTopBanner)
            #expect(projected.secondaryAction?.id == .retryFailedSegments)
            #expect(projected.secondaryAction?.label == "Retry failed segments")
        }
    }

    @Test("Translation resume projected message includes resume action")
    @MainActor func translationResumeProjectedMessageIncludesResumeAction() {
        withEnglishLanguage {
            let projected = AgentRuntimeProjection.translationResumeAvailableProjectedMessage()

            #expect(projected.host == .readerTopBanner)
            #expect(projected.primaryAction?.id == .resumeTranslation)
            #expect(projected.primaryAction?.label == "Resume Translation")
        }
    }

    @Test("Projected action labels remain shared")
    @MainActor func projectedActionLabelsRemainShared() {
        withEnglishLanguage {
            let bundle = LanguageManager.shared.bundle

            #expect(AgentRuntimeProjection.actionLabel(for: .openSettings, bundle: bundle) == "Open Settings")
            #expect(AgentRuntimeProjection.actionLabel(for: .openDebugIssues, bundle: bundle) == "Open Debug Issues")
            #expect(AgentRuntimeProjection.actionLabel(for: .resumeTranslation, bundle: bundle) == "Resume Translation")
            #expect(AgentRuntimeProjection.actionLabel(for: .retryFailedSegments, bundle: bundle) == "Retry failed segments")
        }
    }

    @Test("Batch notice projected message uses footer host and warning severity")
    @MainActor func batchNoticeProjectedMessageUsesFooterHost() {
        withEnglishLanguage {
            let projected = AgentRuntimeProjection.taggingBatchNoticeProjectedMessage(
                .promptTemplateFallback(.invalidCustomTemplate)
            )

            #expect(projected.host == .batchSheetFooterMessageArea)
            #expect(projected.severity == .warning)
        }
    }

    @Test("Batch no eligible projected message uses info severity")
    @MainActor func batchNoEligibleProjectedMessageUsesInfoSeverity() {
        withEnglishLanguage {
            let projected = AgentRuntimeProjection.taggingBatchNoEligibleEntriesProjectedMessage()

            #expect(projected.host == .batchSheetFooterMessageArea)
            #expect(projected.severity == .info)
            #expect(projected.primaryText == "No eligible entries found for the selected scope.")
        }
    }

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

    private func makeCandidate(
        taskKind: AgentTaskKind,
        entryId: Int64,
        requestSource: AgentTaskRequestSource,
        createdAt: Date,
        text: String,
        primaryAction: AgentProjectedMessageAction? = nil
    ) -> AgentProjectedMessageCandidate {
        AgentProjectedMessageCandidate(
            owner: AgentRunOwner(taskKind: taskKind, entryId: entryId, slotKey: "slot"),
            requestSource: requestSource,
            createdAt: createdAt,
            message: AgentProjectedMessage(
                primaryText: text,
                secondaryText: nil,
                severity: .info,
                primaryAction: primaryAction,
                secondaryAction: nil,
                host: .readerTopBanner
            )
        )
    }
}
