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
    func statusAndFailClosedFreeze() {
        #expect(TranslationSegmentStatusText.requesting.rawValue == "Requesting...")
        #expect(TranslationSegmentStatusText.generating.rawValue == "Generating...")
        #expect(TranslationSegmentStatusText.persisting.rawValue == "Persisting...")
        #expect(TranslationSegmentStatusText.waitingForPreviousRun.rawValue == "Waiting for last generation to finish...")
        #expect(TranslationGlobalStatusText.fetchFailedRetry == "Fetch data failed.")
        #expect(TranslationGlobalStatusText.noTranslationYet == "No translation")
        #expect(TranslationPolicy.runWatchdogTimeoutSeconds == 180)
        #expect(TranslationPolicy.shouldFailClosedOnFetchError() == true)
    }
}
