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
}

enum TranslationSegmentationContract {
    nonisolated static let segmenterVersion = "v1"
    nonisolated static let supportedSegmentTypes: Set<TranslationSegmentType> = [.p, .ul, .ol]
}

nonisolated enum TranslationRuntimePolicy {
    static func makeRunOwnerSlotKey(_ slotKey: TranslationSlotKey) -> String {
        AgentLanguageOption.option(for: slotKey.targetLanguage).code
    }

    static func decodeRunOwnerSlot(_ owner: AgentRunOwner?) -> TranslationSlotKey? {
        guard let owner,
              owner.taskKind == .translation else {
            return nil
        }
        let normalizedLanguage = AgentLanguageOption.option(for: owner.slotKey).code
        guard normalizedLanguage.isEmpty == false else {
            return nil
        }
        return TranslationSlotKey(
            entryId: owner.entryId,
            targetLanguage: normalizedLanguage
        )
    }

    static func shouldAutoEnterBilingual(currentEntryId: Int64?, runningOwner: AgentRunOwner?) -> Bool {
        guard let currentEntryId,
              let slot = decodeRunOwnerSlot(runningOwner) else {
            return false
        }
        return slot.entryId == currentEntryId
    }
}

nonisolated enum AgentDisplayOwnershipPolicy {
    static func shouldProject(owner: AgentRunOwner, displayedEntryId: Int64?) -> Bool {
        owner.entryId == displayedEntryId
    }

    static func shouldProject(candidateEntryId: Int64, displayedEntryId: Int64?) -> Bool {
        candidateEntryId == displayedEntryId
    }
}

nonisolated enum TranslationModePolicy {
    static func toggledMode(from current: TranslationMode) -> TranslationMode {
        switch current {
        case .original:
            return .bilingual
        case .bilingual:
            return .original
        }
    }

    static func toolbarButtonIconName(for mode: TranslationMode) -> String {
        switch mode {
        case .original:
            return "globe"
        case .bilingual:
            return "globe.badge.chevron.backward"
        }
    }

    static func isToolbarButtonVisible(readingMode: ReadingMode) -> Bool {
        readingMode == .reader
    }
}
