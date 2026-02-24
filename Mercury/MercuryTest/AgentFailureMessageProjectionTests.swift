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

    private func withEnglishLanguage(_ body: () -> Void) {
        let originalOverride = LanguageManager.shared.languageOverride
        defer {
            LanguageManager.shared.setLanguage(originalOverride)
        }
        LanguageManager.shared.setLanguage("en")
        body()
    }
}
