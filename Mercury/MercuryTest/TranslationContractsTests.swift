import Testing
@testable import Mercury

@Suite("Translation Contracts")
struct TranslationContractsTests {
    @Test("Segmentation contract and fail-closed policy freeze")
    func segmentationAndFailClosedFreeze() {
        #expect(TranslationSegmentationContract.segmenterVersion == "v1")
        #expect(TranslationSegmentationContract.supportedSegmentTypes == [.p, .ul, .ol])
        #expect(TranslationPolicy.shouldFailClosedOnFetchError() == true)
    }

    @Test("Translation concurrency settings freeze")
    func translationConcurrencySettingsFreeze() {
        #expect(TranslationSettingsKey.defaultConcurrencyDegree == 3)
        #expect(TranslationSettingsKey.concurrencyRange == 1...5)
        #expect(TranslationSettingsKey.concurrencyDegree == "Agent.Translation.concurrencyDegree")
    }

    @Test("P0 status vocabulary and fail-closed behavior freeze")
    @MainActor func statusAndFailClosedFreeze() {
        withEnglishLanguage {
            #expect(AgentRuntimeProjection.translationStatusText(for: .requesting) == "Requesting...")
            #expect(AgentRuntimeProjection.translationStatusText(for: .generating) == "Generating...")
            #expect(AgentRuntimeProjection.translationStatusText(for: .persisting) == "Persisting...")
            #expect(AgentRuntimeProjection.translationWaitingStatus() == "Waiting for last generation to finish...")
            #expect(AgentRuntimeProjection.translationFetchFailedRetryStatus() == "Fetch data failed.")
            #expect(AgentRuntimeProjection.translationNoContentStatus() == "No translation")
            #expect(TaskTimeoutPolicy.executionTimeout(for: AppTaskKind.translation) == 300)
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
