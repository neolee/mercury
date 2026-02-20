import Foundation

enum AITranslationRunStartDecision: Equatable {
    case startNow
    case renderStatus(String)
}

enum AITranslationStartPolicy {
    static func decide(
        hasPersistedRecord: Bool,
        hasPendingRecordLoad: Bool,
        isCurrentSlotInFlight: Bool,
        hasAnyInFlight: Bool,
        hasManualRequest: Bool,
        currentStatus: String?
    ) -> AITranslationRunStartDecision {
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
