import Testing
@testable import Mercury

@Suite("Summary Waiting Decision")
struct SummaryWaitingDecisionTests {
    @Test("Manual waiting replaces previous waiting owners")
    func manualReplacesPreviousWaiting() {
        let existingAuto = AgentRunOwner(taskKind: .summary, entryId: 2, slotKey: "en|medium")
        let queued = AgentRunOwner(taskKind: .summary, entryId: 3, slotKey: "en|medium")
        let decision = SummaryPolicy.decideWaiting(
            queuedOwner: queued,
            queuedTrigger: .manual,
            displayedEntryId: 3,
            existingWaiting: [existingAuto: .auto]
        )

        #expect(decision.shouldKeepCurrent == true)
        #expect(decision.ownersToCancel == [existingAuto])
    }

    @Test("Auto waiting does not override existing manual waiting")
    func autoDoesNotOverrideManual() {
        let existingManual = AgentRunOwner(taskKind: .summary, entryId: 2, slotKey: "en|medium")
        let queued = AgentRunOwner(taskKind: .summary, entryId: 3, slotKey: "en|medium")
        let decision = SummaryPolicy.decideWaiting(
            queuedOwner: queued,
            queuedTrigger: .auto,
            displayedEntryId: 3,
            existingWaiting: [existingManual: .manual]
        )

        #expect(decision.shouldKeepCurrent == false)
        #expect(decision.ownersToCancel == [queued])
    }

    @Test("Auto waiting keeps latest-only among auto waiting owners")
    func autoKeepsLatestOnly() {
        let existingAuto = AgentRunOwner(taskKind: .summary, entryId: 2, slotKey: "en|medium")
        let queued = AgentRunOwner(taskKind: .summary, entryId: 3, slotKey: "en|medium")
        let decision = SummaryPolicy.decideWaiting(
            queuedOwner: queued,
            queuedTrigger: .auto,
            displayedEntryId: 3,
            existingWaiting: [existingAuto: .auto]
        )

        #expect(decision.shouldKeepCurrent == true)
        #expect(decision.ownersToCancel == [existingAuto])
    }

    @Test("Stale queued owner is abandoned when entry already changed")
    func staleQueuedOwnerIsDropped() {
        let queued = AgentRunOwner(taskKind: .summary, entryId: 2, slotKey: "en|medium")
        let decision = SummaryPolicy.decideWaiting(
            queuedOwner: queued,
            queuedTrigger: .manual,
            displayedEntryId: 3,
            existingWaiting: [:]
        )

        #expect(decision.shouldKeepCurrent == false)
        #expect(decision.ownersToCancel == [queued])
    }
}
