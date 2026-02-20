import Foundation

enum TranslationRunStartDecision: Equatable {
    case startNow
    case renderStatus(String)
}

enum TranslationStartPolicy {
    static func decide(
        hasPersistedRecord: Bool,
        hasPendingRecordLoad: Bool,
        isCurrentSlotInFlight: Bool,
        hasAnyInFlight: Bool,
        hasManualRequest: Bool,
        currentStatus: String?
    ) -> TranslationRunStartDecision {
        if hasPersistedRecord {
            return .renderStatus("")
        }
        if hasPendingRecordLoad {
            return .renderStatus(currentStatus ?? AITranslationSegmentStatusText.generating.rawValue)
        }
        if isCurrentSlotInFlight {
            return .renderStatus(currentStatus ?? AITranslationSegmentStatusText.generating.rawValue)
        }
        if hasManualRequest == false {
            return .renderStatus(currentStatus ?? AITranslationGlobalStatusText.noTranslationYet)
        }
        if hasAnyInFlight {
            return .renderStatus(AITranslationSegmentStatusText.waitingForPreviousRun.rawValue)
        }
        return .startNow
    }

}
