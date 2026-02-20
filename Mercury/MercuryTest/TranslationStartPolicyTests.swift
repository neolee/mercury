import Testing
@testable import Mercury

@Suite("AI Translation Start Policy")
struct TranslationStartPolicyTests {
    @Test("Manual request starts immediately when no other run is in flight")
    func startNowWhenIdle() {
        let decision = TranslationStartPolicy.decide(
            hasPersistedRecord: false,
            hasPendingRecordLoad: false,
            isCurrentSlotInFlight: false,
            hasAnyInFlight: false,
            hasManualRequest: true,
            currentStatus: nil
        )
        #expect(decision == .startNow)
    }

    @Test("Manual request shows waiting when another run is active")
    func waitingWhenAnotherRunActive() {
        let decision = TranslationStartPolicy.decide(
            hasPersistedRecord: false,
            hasPendingRecordLoad: false,
            isCurrentSlotInFlight: false,
            hasAnyInFlight: true,
            hasManualRequest: true,
            currentStatus: nil
        )
        #expect(decision == .renderStatus(AITranslationSegmentStatusText.waitingForPreviousRun.rawValue))
    }

    @Test("Without manual request, default status stays no translation")
    func noAutoStartWithoutManualRequest() {
        let decision = TranslationStartPolicy.decide(
            hasPersistedRecord: false,
            hasPendingRecordLoad: false,
            isCurrentSlotInFlight: false,
            hasAnyInFlight: false,
            hasManualRequest: false,
            currentStatus: nil
        )
        #expect(decision == .renderStatus(AITranslationGlobalStatusText.noTranslationYet))
    }

    @Test("Pending load keeps generating status")
    func pendingLoadKeepsGenerating() {
        let decision = TranslationStartPolicy.decide(
            hasPersistedRecord: false,
            hasPendingRecordLoad: true,
            isCurrentSlotInFlight: false,
            hasAnyInFlight: false,
            hasManualRequest: true,
            currentStatus: nil
        )
        #expect(decision == .renderStatus(AITranslationSegmentStatusText.generating.rawValue))
    }

}
