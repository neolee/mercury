import Foundation
import Testing
@testable import Mercury

@Suite("Agent Run Coordinator")
struct AgentRunCoordinatorTests {
    @Test("Serialized task enters waiting and is promoted after finish")
    func serializedWaitingAndPromotion() async {
        let coordinator = AgentRunCoordinator(
            policy: AgentRunCoordinatorPolicy(perTaskConcurrencyLimit: [.translation: 1])
        )
        let first = AgentRunOwner(taskKind: .translation, entryId: 1, slotKey: "slot-1")
        let second = AgentRunOwner(taskKind: .translation, entryId: 2, slotKey: "slot-2")

        #expect(await coordinator.requestStart(owner: first) == .startNow)
        #expect(await coordinator.requestStart(owner: second) == .queuedWaiting(position: 1))

        let secondWaitingState = await coordinator.state(for: second)
        #expect(secondWaitingState?.phase == .waiting)

        let promoted = await coordinator.finish(owner: first, terminalPhase: .completed)
        #expect(promoted == second)
        #expect(await coordinator.state(for: second)?.phase == .requesting)
    }

    @Test("Waiting can be abandoned by entry switch")
    func abandonWaitingByEntry() async {
        let coordinator = AgentRunCoordinator(
            policy: AgentRunCoordinatorPolicy(perTaskConcurrencyLimit: [.translation: 1])
        )
        let active = AgentRunOwner(taskKind: .translation, entryId: 1, slotKey: "slot-1")
        let waiting = AgentRunOwner(taskKind: .translation, entryId: 2, slotKey: "slot-2")

        #expect(await coordinator.requestStart(owner: active) == .startNow)
        #expect(await coordinator.requestStart(owner: waiting) == .queuedWaiting(position: 1))

        await coordinator.abandonWaiting(taskKind: .translation, entryId: 2)
        #expect(await coordinator.state(for: waiting)?.phase == .cancelled)

        let promoted = await coordinator.finish(owner: active, terminalPhase: .completed)
        #expect(promoted == nil)
    }

    @Test("Different task kinds do not block each other")
    func perTaskLimitIsolation() async {
        let coordinator = AgentRunCoordinator(
            policy: AgentRunCoordinatorPolicy(perTaskConcurrencyLimit: [.summary: 1, .translation: 1])
        )
        let summary = AgentRunOwner(taskKind: .summary, entryId: 1, slotKey: "s-1")
        let translation = AgentRunOwner(taskKind: .translation, entryId: 2, slotKey: "t-1")

        #expect(await coordinator.requestStart(owner: summary) == .startNow)
        #expect(await coordinator.requestStart(owner: translation) == .startNow)

        let snapshot = await coordinator.snapshot()
        #expect(snapshot.activeByTask[.summary]?.contains(summary) == true)
        #expect(snapshot.activeByTask[.translation]?.contains(translation) == true)
    }

    @Test("Abandon waiting owner removes it from queue and prevents later promotion")
    func abandonWaitingOwnerRemovesQueueItem() async {
        let coordinator = AgentRunCoordinator(
            policy: AgentRunCoordinatorPolicy(perTaskConcurrencyLimit: [.summary: 1])
        )
        let active = AgentRunOwner(taskKind: .summary, entryId: 1, slotKey: "en|medium")
        let waitingB = AgentRunOwner(taskKind: .summary, entryId: 2, slotKey: "en|medium")
        let waitingC = AgentRunOwner(taskKind: .summary, entryId: 3, slotKey: "en|medium")

        #expect(await coordinator.requestStart(owner: active) == .startNow)
        #expect(await coordinator.requestStart(owner: waitingB) == .queuedWaiting(position: 1))
        #expect(await coordinator.requestStart(owner: waitingC) == .queuedWaiting(position: 2))

        await coordinator.abandonWaiting(owner: waitingB)
        #expect(await coordinator.state(for: waitingB)?.phase == .cancelled)

        let promoted = await coordinator.finish(owner: active, terminalPhase: .completed)
        #expect(promoted == waitingC)
        #expect(await coordinator.state(for: waitingC)?.phase == .requesting)
    }

    @Test("Ignores invalid backward phase transition")
    func ignoresInvalidBackwardTransition() async {
        let coordinator = AgentRunCoordinator(
            policy: AgentRunCoordinatorPolicy(perTaskConcurrencyLimit: [.summary: 1])
        )
        let owner = AgentRunOwner(taskKind: .summary, entryId: 1, slotKey: "en|medium")

        #expect(await coordinator.requestStart(owner: owner) == .startNow)
        await coordinator.updatePhase(owner: owner, phase: .generating)
        #expect(await coordinator.state(for: owner)?.phase == .generating)

        await coordinator.updatePhase(owner: owner, phase: .requesting)
        #expect(await coordinator.state(for: owner)?.phase == .generating)
    }
}
