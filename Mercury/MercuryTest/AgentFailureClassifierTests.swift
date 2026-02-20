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
