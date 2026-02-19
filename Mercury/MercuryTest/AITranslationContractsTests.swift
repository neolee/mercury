import Testing
@testable import Mercury

@Suite("AI Translation Contracts")
struct AITranslationContractsTests {
    @Test("P0 strategy policy freeze")
    func strategyPolicyFreeze() {
        #expect(AITranslationPolicy.defaultStrategy == .wholeArticleSingleRequest)
        #expect(AITranslationPolicy.fallbackStrategy == .chunkedRequests)
        #expect(AITranslationPolicy.enabledStrategiesForV1 == [.wholeArticleSingleRequest, .chunkedRequests])
        #expect(AITranslationPolicy.deferredStrategiesForV1 == [.perSegmentRequests])
    }

    @Test("P0 thresholds and segmentation contract freeze")
    func thresholdsAndSegmentationFreeze() {
        #expect(AITranslationThresholds.v1.maxSegmentsForStrategyA == 120)
        #expect(AITranslationThresholds.v1.maxEstimatedTokenBudgetForStrategyA == 12_000)
        #expect(AITranslationThresholds.v1.chunkSizeForStrategyC == 24)

        #expect(AITranslationSegmentationContract.segmenterVersion == "v1")
        #expect(AITranslationSegmentationContract.supportedSegmentTypes == [.p, .ul, .ol])
    }

    @Test("P0 status vocabulary and fail-closed behavior freeze")
    func statusAndFailClosedFreeze() {
        #expect(AITranslationSegmentStatusText.requesting.rawValue == "Requesting...")
        #expect(AITranslationSegmentStatusText.generating.rawValue == "Generating...")
        #expect(AITranslationSegmentStatusText.waitingForPreviousRun.rawValue == "Waiting for last generation to finish...")
        #expect(AITranslationGlobalStatusText.fetchFailedRetry == "Fetch data failed. Retry?")
        #expect(AITranslationGlobalStatusText.noTranslationYet == "No translation yet.")
        #expect(AITranslationPolicy.shouldFailClosedOnFetchError() == true)
    }
}
