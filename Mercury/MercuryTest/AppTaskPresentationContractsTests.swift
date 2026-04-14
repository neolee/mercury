import Testing
@testable import Mercury

@Suite("App Task Presentation Contracts")
@MainActor
struct AppTaskPresentationContractsTests {
    @Test("Agent task titles remain centrally owned on AppTaskKind")
    func agentTaskTitlesFreeze() {
        #expect(AppTaskKind.summary.displayTitle == "Summary")
        #expect(AppTaskKind.translation.displayTitle == "Translation")
        #expect(AppTaskKind.tagging.displayTitle == "Tagging")
        #expect(AppTaskKind.taggingBatch.displayTitle == "Tagging Batch")
    }

    @Test("Reader-bound agent tasks remain outside queue-only presentation surface")
    func readerBoundAgentTasksStayInAgentFamily() {
        #expect(UnifiedTaskKind.from(appTaskKind: .summary).family == .agent)
        #expect(UnifiedTaskKind.from(appTaskKind: .translation).family == .agent)
        #expect(UnifiedTaskKind.from(appTaskKind: .tagging).family == .agent)
        #expect(UnifiedTaskKind.from(appTaskKind: .taggingBatch).family == .agent)

        #expect(UnifiedTaskKind.from(appTaskKind: .syncFeeds).family == .queueOnly)
        #expect(UnifiedTaskKind.from(appTaskKind: .importOPML).family == .queueOnly)
        #expect(UnifiedTaskKind.from(appTaskKind: .readerBuild).family == .queueOnly)
    }

    @Test("Batch tagging scope and status labels stay centralized")
    @MainActor func batchTaggingLabelsFreeze() {
        withEnglishLanguage {
            let bundle = LanguageManager.shared.bundle

            #expect(TagBatchSelectionScope.pastWeek.displayTitle(bundle: bundle) == "1 Week")
            #expect(TagBatchSelectionScope.unreadEntries.displayTitle(bundle: bundle) == "All Unread")
            #expect(TagBatchRunStatus.readyNext.displayTitle(bundle: bundle) == "Ready")
            #expect(TagBatchRunStatus.cancelled.displayTitle(bundle: bundle) == "Cancelled")
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
