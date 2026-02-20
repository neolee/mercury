import Foundation

enum TranslationRequestStrategy: String, Sendable {
    case wholeArticleSingleRequest = "A"
    case perSegmentRequests = "B"
    case chunkedRequests = "C"
}

enum TranslationMode: String, Sendable {
    case original
    case bilingual
}

enum TranslationSegmentStatusText: String, Sendable, CaseIterable {
    case requesting = "Requesting..."
    case generating = "Generating..."
    case persisting = "Persisting..."
    case waitingForPreviousRun = "Waiting for last generation to finish..."
}

enum TranslationGlobalStatusText {
    nonisolated static let fetchFailedRetry = "Fetch data failed."
    nonisolated static let noTranslationYet = "No translation"
}

struct TranslationThresholds: Sendable, Equatable {
    let maxSegmentsForStrategyA: Int
    let maxEstimatedTokenBudgetForStrategyA: Int
    let chunkSizeForStrategyC: Int

    nonisolated static let v1 = TranslationThresholds(
        maxSegmentsForStrategyA: 120,
        maxEstimatedTokenBudgetForStrategyA: 12_000,
        chunkSizeForStrategyC: 24
    )
}

enum TranslationPolicy {
    nonisolated static let defaultStrategy: TranslationRequestStrategy = .wholeArticleSingleRequest
    nonisolated static let fallbackStrategy: TranslationRequestStrategy = .chunkedRequests
    nonisolated static let enabledStrategiesForV1: Set<TranslationRequestStrategy> = [
        .wholeArticleSingleRequest,
        .chunkedRequests
    ]
    nonisolated static let deferredStrategiesForV1: Set<TranslationRequestStrategy> = [
        .perSegmentRequests
    ]
    nonisolated static let runWatchdogTimeoutSeconds: TimeInterval = 180

    static func shouldFailClosedOnFetchError() -> Bool {
        true
    }
}

struct TranslationSlotKey: Sendable, Hashable {
    var entryId: Int64
    var targetLanguage: String
    var sourceContentHash: String
    var segmenterVersion: String
}

enum TranslationSegmentationContract {
    nonisolated static let segmenterVersion = "v1"
    nonisolated static let supportedSegmentTypes: Set<TranslationSegmentType> = [.p, .ul, .ol]
}
