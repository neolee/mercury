import Testing
@testable import Mercury

@Suite("Translation Contracts")
struct TranslationContractsTests {
    @Test("P0 strategy policy freeze")
    func strategyPolicyFreeze() {
        #expect(TranslationPolicy.defaultStrategy == .wholeArticleSingleRequest)
        #expect(TranslationPolicy.fallbackStrategy == .chunkedRequests)
        #expect(TranslationPolicy.enabledStrategiesForV1 == [.wholeArticleSingleRequest, .chunkedRequests])
        #expect(TranslationPolicy.deferredStrategiesForV1 == [.perSegmentRequests])
    }

    @Test("P0 thresholds and segmentation contract freeze")
    func thresholdsAndSegmentationFreeze() {
        #expect(TranslationThresholds.v1.maxSegmentsForStrategyA == 120)
        #expect(TranslationThresholds.v1.maxEstimatedTokenBudgetForStrategyA == 12_000)
        #expect(TranslationThresholds.v1.chunkSizeForStrategyC == 24)

        #expect(TranslationSegmentationContract.segmenterVersion == "v1")
        #expect(TranslationSegmentationContract.supportedSegmentTypes == [.p, .ul, .ol])
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
            #expect(TranslationPolicy.runWatchdogTimeoutSeconds == 180)
            #expect(TranslationPolicy.shouldFailClosedOnFetchError() == true)
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
