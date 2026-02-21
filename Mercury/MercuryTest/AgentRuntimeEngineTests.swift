import Foundation
import Testing
@testable import Mercury

@Suite("Agent Runtime Engine")
struct AgentRuntimeEngineTests {
    @Test("Serialized task enters waiting and is promoted after finish")
    func serializedWaitingAndPromotion() async {
        let engine = AgentRuntimeEngine(
            policy: AgentRuntimePolicy(perTaskConcurrencyLimit: [.translation: 1])
        )
        let first = AgentRunOwner(taskKind: .translation, entryId: 1, slotKey: "slot-1")
        let second = AgentRunOwner(taskKind: .translation, entryId: 2, slotKey: "slot-2")

        #expect(await engine.requestStart(owner: first) == .startNow)
        #expect(await engine.requestStart(owner: second) == .queuedWaiting(position: 1))

        let secondWaitingState = await engine.state(for: second)
        #expect(secondWaitingState?.phase == .waiting)

        let promoted = await engine.finish(owner: first, terminalPhase: .completed)
        #expect(promoted == second)
        #expect(await engine.state(for: second)?.phase == .requesting)
    }

    @Test("Waiting can be abandoned by entry switch")
    func abandonWaitingByEntry() async {
        let engine = AgentRuntimeEngine(
            policy: AgentRuntimePolicy(perTaskConcurrencyLimit: [.translation: 1])
        )
        let active = AgentRunOwner(taskKind: .translation, entryId: 1, slotKey: "slot-1")
        let waiting = AgentRunOwner(taskKind: .translation, entryId: 2, slotKey: "slot-2")

        #expect(await engine.requestStart(owner: active) == .startNow)
        #expect(await engine.requestStart(owner: waiting) == .queuedWaiting(position: 1))

        await engine.abandonWaiting(taskKind: .translation, entryId: 2)
        #expect(await engine.state(for: waiting)?.phase == .cancelled)

        let promoted = await engine.finish(owner: active, terminalPhase: .completed)
        #expect(promoted == nil)
    }

    @Test("Different task kinds do not block each other")
    func perTaskLimitIsolation() async {
        let engine = AgentRuntimeEngine(
            policy: AgentRuntimePolicy(perTaskConcurrencyLimit: [.summary: 1, .translation: 1])
        )
        let summary = AgentRunOwner(taskKind: .summary, entryId: 1, slotKey: "s-1")
        let translation = AgentRunOwner(taskKind: .translation, entryId: 2, slotKey: "t-1")

        #expect(await engine.requestStart(owner: summary) == .startNow)
        #expect(await engine.requestStart(owner: translation) == .startNow)

        let snapshot = await engine.snapshot()
        #expect(snapshot.activeByTask[.summary]?.contains(summary) == true)
        #expect(snapshot.activeByTask[.translation]?.contains(translation) == true)
    }

    @Test("Abandon waiting owner removes it from queue and prevents later promotion")
    func abandonWaitingOwnerRemovesQueueItem() async {
        let engine = AgentRuntimeEngine(
            policy: AgentRuntimePolicy(perTaskConcurrencyLimit: [.summary: 1])
        )
        let active = AgentRunOwner(taskKind: .summary, entryId: 1, slotKey: "en|medium")
        let waitingB = AgentRunOwner(taskKind: .summary, entryId: 2, slotKey: "en|medium")
        let waitingC = AgentRunOwner(taskKind: .summary, entryId: 3, slotKey: "en|medium")

        #expect(await engine.requestStart(owner: active) == .startNow)
        #expect(await engine.requestStart(owner: waitingB) == .queuedWaiting(position: 1))
        #expect(await engine.requestStart(owner: waitingC) == .queuedWaiting(position: 2))

        await engine.abandonWaiting(owner: waitingB)
        #expect(await engine.state(for: waitingB)?.phase == .cancelled)

        let promoted = await engine.finish(owner: active, terminalPhase: .completed)
        #expect(promoted == waitingC)
        #expect(await engine.state(for: waitingC)?.phase == .requesting)
    }

    @Test("Waiting entry leaves queue before active completes")
    func waitingEntryLeavesQueueBeforeActiveCompletes() async {
        let engine = AgentRuntimeEngine(
            policy: AgentRuntimePolicy(perTaskConcurrencyLimit: [.translation: 1])
        )
        let activeA = AgentRunOwner(taskKind: .translation, entryId: 100, slotKey: "en|hash-a|v1")
        let waitingB = AgentRunOwner(taskKind: .translation, entryId: 200, slotKey: "ja|hash-b|v1")

        #expect(await engine.requestStart(owner: activeA) == .startNow)
        #expect(await engine.requestStart(owner: waitingB) == .queuedWaiting(position: 1))
        #expect(await engine.state(for: waitingB)?.phase == .waiting)

        await engine.abandonWaiting(taskKind: .translation, entryId: 200)
        #expect(await engine.state(for: waitingB)?.phase == .cancelled)

        let promoted = await engine.finish(owner: activeA, terminalPhase: .completed)
        #expect(promoted == nil)

        let snapshot = await engine.snapshot()
        #expect(snapshot.waitingByTask[.translation, default: []].contains(waitingB) == false)
        #expect(snapshot.activeByTask[.translation, default: []].contains(waitingB) == false)
    }

    @Test("Ignores invalid backward phase transition")
    func ignoresInvalidBackwardTransition() async {
        let engine = AgentRuntimeEngine(
            policy: AgentRuntimePolicy(perTaskConcurrencyLimit: [.summary: 1])
        )
        let owner = AgentRunOwner(taskKind: .summary, entryId: 1, slotKey: "en|medium")

        #expect(await engine.requestStart(owner: owner) == .startNow)
        await engine.updatePhase(owner: owner, phase: .generating)
        #expect(await engine.state(for: owner)?.phase == .generating)

        await engine.updatePhase(owner: owner, phase: .requesting)
        #expect(await engine.state(for: owner)?.phase == .generating)
    }
}
