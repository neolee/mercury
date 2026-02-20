import Testing
@testable import Mercury

@Suite("Agent Runtime Failure Projection")
struct AgentRuntimeFailureProjectionTests {
    @Test("Maps parser failures to concise message")
    func parserMessage() {
        let message = AgentRuntimeProjection.failureMessage(for: .parser, taskKind: .translation)
        #expect(message == "Model response format invalid.")
    }

    @Test("Maps no model route to settings guidance")
    func noModelRouteMessage() {
        let message = AgentRuntimeProjection.failureMessage(for: .noModelRoute, taskKind: .summary)
        #expect(message == "No model route. Check agent settings.")
    }

    @Test("Maps unknown to debug guidance")
    func unknownMessage() {
        let message = AgentRuntimeProjection.failureMessage(for: .unknown, taskKind: .summary)
        #expect(message == "Failed. Check Debug Issues.")
    }
}
