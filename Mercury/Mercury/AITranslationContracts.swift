import Foundation

enum AITranslationRequestStrategy: String, Sendable {
    case wholeArticleSingleRequest = "A"
    case perSegmentRequests = "B"
    case chunkedRequests = "C"
}

enum AITranslationMode: String, Sendable {
    case original
    case bilingual
}

enum AITranslationSegmentStatusText: String, Sendable, CaseIterable {
    case requesting = "Requesting..."
    case generating = "Generating..."
    case waitingForPreviousRun = "Waiting for last generation to finish..."
}

enum AITranslationGlobalStatusText {
    static let fetchFailedRetry = "Fetch data failed. Retry?"
    static let noTranslationYet = "No translation yet."
}

struct AITranslationThresholds: Sendable, Equatable {
    let maxSegmentsForStrategyA: Int
    let maxEstimatedTokenBudgetForStrategyA: Int
    let chunkSizeForStrategyC: Int

    static let v1 = AITranslationThresholds(
        maxSegmentsForStrategyA: 120,
        maxEstimatedTokenBudgetForStrategyA: 12_000,
        chunkSizeForStrategyC: 24
    )
}

enum AITranslationPolicy {
    static let defaultStrategy: AITranslationRequestStrategy = .wholeArticleSingleRequest
    static let fallbackStrategy: AITranslationRequestStrategy = .chunkedRequests
    static let enabledStrategiesForV1: Set<AITranslationRequestStrategy> = [
        .wholeArticleSingleRequest,
        .chunkedRequests
    ]
    static let deferredStrategiesForV1: Set<AITranslationRequestStrategy> = [
        .perSegmentRequests
    ]

    static func shouldFailClosedOnFetchError() -> Bool {
        true
    }
}

struct AITranslationSlotKey: Sendable, Hashable {
    var entryId: Int64
    var targetLanguage: String
    var sourceContentHash: String
    var segmenterVersion: String
}

enum AITranslationSegmentationContract {
    static let segmenterVersion = "v1"
    static let supportedSegmentTypes: Set<AITranslationSegmentType> = [.p, .ul, .ol]
}
