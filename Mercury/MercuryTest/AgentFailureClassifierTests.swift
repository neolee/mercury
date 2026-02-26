import Foundation
import Testing
@testable import Mercury

@Suite("Agent Failure Classifier")
struct AgentFailureClassifierTests {
    @Test("Classifies summary route-missing as no model route")
    func summaryNoModelRoute() {
        let reason = AgentFailureClassifier.classify(
            error: SummaryExecutionError.noUsableModelRoute,
            taskKind: .summary
        )
        #expect(reason == .noModelRoute)
    }

    @Test("Classifies translation parser errors")
    func translationParserError() {
        let reason = AgentFailureClassifier.classify(
            error: TranslationExecutionError.invalidModelResponse,
            taskKind: .translation
        )
        #expect(reason == .parser)
    }

    @Test("Classifies translation rate-limit errors as network")
    func translationRateLimitError() {
        let reason = AgentFailureClassifier.classify(
            error: TranslationExecutionError.rateLimited(details: "HTTP 429"),
            taskKind: .translation
        )
        #expect(reason == .network)
    }

    @Test("Classifies provider unauthorized as authentication")
    func providerUnauthorized() {
        let reason = AgentFailureClassifier.classify(
            error: LLMProviderError.unauthorized,
            taskKind: .summary
        )
        #expect(reason == .authentication)
    }

    @Test("Classifies transport timeout as timed out")
    func timeoutError() {
        let reason = AgentFailureClassifier.classify(
            error: URLError(.timedOut),
            taskKind: .translation
        )
        #expect(reason == .timedOut)
    }

    @Test("Classifies provider timeout messages as timed out")
    func providerTimeoutMessageError() {
        let timeoutMessages = [
            "Request timed out.",
            "Request timed out waiting for first token.",
            "Stream idle timed out."
        ]

        for message in timeoutMessages {
            let reason = AgentFailureClassifier.classify(
                error: LLMProviderError.network(message),
                taskKind: .translation
            )
            #expect(reason == .timedOut)
        }
    }

    @Test("Classifies non-timeout provider network errors as network")
    func providerNetworkError() {
        let reason = AgentFailureClassifier.classify(
            error: LLMProviderError.network("Connection reset by peer."),
            taskKind: .summary
        )
        #expect(reason == .network)
    }

    @Test("Classifies provider unknown timeout message as timed out")
    func providerUnknownTimeoutMessageError() {
        let reason = AgentFailureClassifier.classify(
            error: LLMProviderError.unknown("The request timed out."),
            taskKind: .translation
        )
        #expect(reason == .timedOut)
    }

    @Test("Classifies provider typed timeout as timed out")
    func providerTypedTimeoutError() {
        let reason = AgentFailureClassifier.classify(
            error: LLMProviderError.timedOut(kind: .streamFirstToken, message: nil),
            taskKind: .translation
        )
        #expect(reason == .timedOut)
    }

    @Test("Classifies translation watchdog timeout as timed out")
    func translationExecutionTimeoutError() {
        let reason = AgentFailureClassifier.classify(
            error: TranslationExecutionError.executionTimedOut(seconds: 180),
            taskKind: .translation
        )
        #expect(reason == .timedOut)
    }

    @Test("Classifies cancellation")
    func cancellation() {
        let reason = AgentFailureClassifier.classify(
            error: CancellationError(),
            taskKind: .summary
        )
        #expect(reason == .cancelled)
    }
}
