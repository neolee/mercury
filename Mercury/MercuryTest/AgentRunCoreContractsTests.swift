import Foundation
import Testing
@testable import Mercury

@Suite("Agent Run Core Contracts")
struct AgentRunCoreContractsTests {
    @Test("Task identity and owner semantics are distinct")
    func taskIdentityAndOwnerSemantics() {
        let owner = AgentRunOwner(taskKind: .summary, entryId: 42, slotKey: "en|medium")
        let first = AgentTaskSpec(taskId: UUID(), owner: owner, requestSource: .manual)
        let second = AgentTaskSpec(taskId: UUID(), owner: owner, requestSource: .manual)

        #expect(first.owner == second.owner)
        #expect(first.taskId != second.taskId)
    }

    @Test("Queue policy defaults freeze per-kind baseline to one")
    func queuePolicyDefaults() {
        let policy = AgentQueuePolicy()

        #expect(policy.waitingCapacityPerKind == AgentRuntimeContract.baselineWaitingCapacityPerKind)
    }
}
