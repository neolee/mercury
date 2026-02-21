import Testing
@testable import Mercury

@Suite("Summary Waiting Cleanup Policy")
struct SummaryWaitingCleanupPolicyTests {
    @Test("Entry switch abandons all waiting owners for previous entry")
    func cleanupAbandonsAllPreviousEntryWaiting() {
        let manualOwner = AgentRunOwner(taskKind: .summary, entryId: 10, slotKey: "en|short")
        let autoOwner = AgentRunOwner(taskKind: .summary, entryId: 10, slotKey: "en|medium")
        let otherEntryOwner = AgentRunOwner(taskKind: .summary, entryId: 11, slotKey: "en|medium")

        let decision = SummaryPolicy.decideWaitingCleanupOnEntrySwitch(
            previousEntryId: 10,
            nextSelectedEntryId: 11,
            existingWaiting: [
                manualOwner: .manual,
                autoOwner: .auto,
                otherEntryOwner: .auto
            ]
        )

        #expect(Set(decision.ownersToAbandon) == Set([manualOwner, autoOwner]))
    }

    @Test("No cleanup when staying on same entry")
    func cleanupKeepsWaitingWhenEntryUnchanged() {
        let owner = AgentRunOwner(taskKind: .summary, entryId: 10, slotKey: "en|medium")
        let decision = SummaryPolicy.decideWaitingCleanupOnEntrySwitch(
            previousEntryId: 10,
            nextSelectedEntryId: 10,
            existingWaiting: [owner: .manual]
        )

        #expect(decision.ownersToAbandon.isEmpty)
    }
}
