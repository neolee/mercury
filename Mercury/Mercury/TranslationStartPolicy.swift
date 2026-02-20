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
            return .renderStatus(currentStatus ?? TranslationSegmentStatusText.generating.rawValue)
        }
        if isCurrentSlotInFlight {
            return .renderStatus(currentStatus ?? TranslationSegmentStatusText.generating.rawValue)
        }
        if hasManualRequest == false {
            return .renderStatus(currentStatus ?? TranslationGlobalStatusText.noTranslationYet)
        }
        if hasAnyInFlight {
            return .renderStatus(TranslationSegmentStatusText.waitingForPreviousRun.rawValue)
        }
        return .startNow
    }

}
