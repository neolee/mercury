import Testing
@testable import Mercury

@Suite("Agent Failure Message Projection")
struct AgentFailureMessageProjectionTests {
    @Test("Maps parser failures to retryable message")
    func parserMessage() {
        let message = AgentFailureMessageProjection.message(for: .parser, taskKind: .translation)
        #expect(message == "Model response format invalid. Retry?")
    }

    @Test("Maps no model route to settings guidance")
    func noModelRouteMessage() {
        let message = AgentFailureMessageProjection.message(for: .noModelRoute, taskKind: .summary)
        #expect(message == "No model route. Check AI settings.")
    }

    @Test("Maps unknown to debug guidance")
    func unknownMessage() {
        let message = AgentFailureMessageProjection.message(for: .unknown, taskKind: .summary)
        #expect(message == "Failed. Check Debug Issues.")
    }
}
