import Testing
@testable import Mercury

@Suite("App Task Presentation Contracts")
struct AppTaskPresentationContractsTests {
    @Test("Agent task titles remain centrally owned on AppTaskKind")
    func agentTaskTitlesFreeze() {
        #expect(AppTaskKind.summary.displayTitle == "Summary")
        #expect(AppTaskKind.translation.displayTitle == "Translation")
        #expect(AppTaskKind.tagging.displayTitle == "Tagging")
        #expect(AppTaskKind.taggingBatch.displayTitle == "Tagging Batch")
    }

    @Test("Agent task progress vocabulary is centralized")
    @MainActor func agentTaskProgressMessagesFreeze() {
        withEnglishLanguage {
            #expect(AppTaskKind.summary.progressMessage(for: .preparing) == "Preparing summary")
            #expect(AppTaskKind.summary.progressMessage(for: .completed) == "Summary completed")
            #expect(AppTaskKind.translation.progressMessage(for: .preparing) == "Preparing translation")
            #expect(AppTaskKind.translation.progressMessage(for: .completed) == "Translation completed")
            #expect(AppTaskKind.tagging.progressMessage(for: .preparing) == "Preparing tag suggestions")
            #expect(AppTaskKind.tagging.progressMessage(for: .completed) == "Tagging completed")
            #expect(AppTaskKind.taggingBatch.progressMessage(for: .preparing) == nil)
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