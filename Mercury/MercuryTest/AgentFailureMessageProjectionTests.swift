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

    private func withEnglishLanguage(_ body: () -> Void) {
        let originalOverride = LanguageManager.shared.languageOverride
        defer {
            LanguageManager.shared.setLanguage(originalOverride)
        }
        LanguageManager.shared.setLanguage("en")
        body()
    }
}
