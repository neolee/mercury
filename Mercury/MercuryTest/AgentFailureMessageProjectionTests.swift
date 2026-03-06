import Testing
@testable import Mercury

@Suite("Agent Runtime Failure Projection")
@MainActor
struct AgentRuntimeFailureProjectionTests {
    @Test("Maps parser failures to concise message")
    func parserMessage() {
        withEnglishLanguage {
            let message = AgentRuntimeProjection.failureMessage(for: .parser, taskKind: .translation)
            #expect(message == "Model response format invalid.")
        }
    }

    @Test("Maps no model route to settings guidance")
    func noModelRouteMessage() {
        withEnglishLanguage {
            let message = AgentRuntimeProjection.failureMessage(for: .noModelRoute, taskKind: .summary)
            #expect(message == "No model route. Check agent settings.")
        }
    }

    @Test("Maps unknown to debug guidance")
    func unknownMessage() {
        withEnglishLanguage {
            let message = AgentRuntimeProjection.failureMessage(for: .unknown, taskKind: .summary)
            #expect(message == "Failed. Check Debug Issues.")
        }
    }

    @Test("Builds banner message from terminal timeout outcome")
    func timeoutOutcomeBannerMessage() {
        withEnglishLanguage {
            let message = AgentRuntimeProjection.bannerMessage(
                for: .timedOut(failureReason: .timedOut, message: "timeout"),
                taskKind: .summary
            )
            #expect(message == "Request timed out.")
        }
    }

    @Test("Does not build banner message for cancelled outcome")
    func cancelledOutcomeBannerMessage() {
        withEnglishLanguage {
            let message = AgentRuntimeProjection.bannerMessage(
                for: .cancelled(failureReason: .cancelled),
                taskKind: .translation
            )
            #expect(message == nil)
        }
    }

    @Test("Maps tagging batch invalid input to tagging-specific message")
    func taggingBatchInvalidInputMessage() {
        withEnglishLanguage {
            let message = AgentRuntimeProjection.failureMessage(for: .invalidInput, taskKind: .taggingBatch)
            #expect(message == "No tagging source available.")
        }
    }

    @Test("Builds translation rate-limit guidance banner from 429 message")
    func rateLimitBannerMessage() {
        withEnglishLanguage {
            let message = AgentRuntimeProjection.bannerMessage(
                for: .failed(
                    failureReason: .network,
                    message: "HTTP 429: Too Many Requests"
                ),
                taskKind: .translation
            )
            #expect(
                message == "Rate limit reached. Reduce translation concurrency, switch model/provider tier, then retry later."
            )
        }
    }

    @Test("Builds summary availability message when no agents are configured")
    func summaryAvailabilityMessageWithoutAnyConfiguredAgent() {
        withEnglishLanguage {
            let message = AgentRuntimeProjection.availabilityMessage(
                for: .summary,
                summaryAvailable: false,
                translationAvailable: false,
                taggingAvailable: false
            )
            #expect(message == "Agents are not configured. Add a provider and model in Settings.")
        }
    }

    @Test("Builds translation availability message when tagging alone is configured")
    func translationAvailabilityMessageWithTaggingConfigured() {
        withEnglishLanguage {
            let message = AgentRuntimeProjection.availabilityMessage(
                for: .translation,
                summaryAvailable: false,
                translationAvailable: false,
                taggingAvailable: true
            )
            #expect(message == "Translation agent is not configured. Add a provider and model in Settings to enable translation.")
        }
    }

    @Test("Combines summary notice and failure into one terminal banner message")
    func summaryTerminalBannerMessageCombinesNoticeAndFailure() {
        withEnglishLanguage {
            let message = AgentRuntimeProjection.terminalBannerMessage(
                for: .failed(failureReason: .network, message: "network error"),
                taskKind: .summary,
                noticeText: "Custom Summary prompt is invalid. Using built-in prompt."
            )
            #expect(
                message == "Custom Summary prompt is invalid. Using built-in prompt. Network error."
            )
        }
    }

    @Test("Combines translation notice and failure into one terminal banner message")
    func terminalBannerMessageCombinesNoticeAndFailure() {
        withEnglishLanguage {
            let message = AgentRuntimeProjection.terminalBannerMessage(
                for: .failed(failureReason: .network, message: "network error"),
                taskKind: .translation,
                noticeText: "Custom Translation prompt is invalid. Using built-in prompt."
            )
            #expect(
                message == "Custom Translation prompt is invalid. Using built-in prompt. Network error."
            )
        }
    }

    @Test("Builds translation terminal projected message with actions")
    func translationTerminalProjectedMessageIncludesStructuredActions() {
        withEnglishLanguage {
            let projected = AgentRuntimeProjection.terminalProjectedMessage(
                for: .failed(failureReason: .network, message: "network error"),
                taskKind: .translation,
                noticeText: "Custom Translation prompt is invalid. Using built-in prompt.",
                primaryActionID: .openDebugIssues,
                secondaryActionID: .retryFailedSegments
            )

            #expect(projected?.primaryText == "Custom Translation prompt is invalid. Using built-in prompt. Network error.")
            #expect(projected?.primaryAction?.id == .openDebugIssues)
            #expect(projected?.secondaryAction?.id == .retryFailedSegments)
            #expect(projected?.host == .readerTopBanner)
        }
    }

    @Test("Builds shared tagging update failure message")
    func taggingUpdateFailedMessage() {
        withEnglishLanguage {
            let message = AgentRuntimeProjection.taggingUpdateFailedMessage()
            #expect(message == "Tag update failed")
        }
    }

    @Test("Builds batch failure projected message on footer host")
    func taggingBatchFailureProjectedMessageUsesFooterHost() {
        withEnglishLanguage {
            let projected = AgentRuntimeProjection.taggingBatchFailureProjectedMessage(reason: .storage)

            #expect(projected.host == .batchSheetFooterMessageArea)
            #expect(projected.severity == .error)
            #expect(projected.primaryText == "Failed to save result. Check Debug Issues.")
        }
    }

    private func withEnglishLanguage(_ body: () -> Void) {
        let originalOverride = LanguageManager.shared.languageOverride
        defer {
            LanguageManager.shared.setLanguage(originalOverride)
        }
        LanguageManager.shared.setLanguage("en")
        body()
    }
}
