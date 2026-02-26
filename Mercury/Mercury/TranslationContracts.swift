import Foundation

enum TranslationMode: String, Sendable {
    case original
    case bilingual
}

enum TranslationPolicy {
    static func shouldFailClosedOnFetchError() -> Bool {
        true
    }
}

enum TranslationSettingsKey {
    nonisolated static let targetLanguage = "Agent.Translation.DefaultTargetLanguage"
    nonisolated static let primaryModelId = "Agent.Translation.PrimaryModelId"
    nonisolated static let fallbackModelId = "Agent.Translation.FallbackModelId"
    nonisolated static let concurrencyDegree = "Agent.Translation.concurrencyDegree"

    nonisolated static let defaultConcurrencyDegree = 3
    nonisolated static let concurrencyRange: ClosedRange<Int> = 1...5
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
