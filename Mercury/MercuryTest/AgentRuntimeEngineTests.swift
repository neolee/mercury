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

    @Test("Submit and finish emit deterministic terminal promotion sequence")
    func deterministicTerminalPromotionSequence() async {
        let engine = AgentRuntimeEngine(
            policy: AgentRuntimePolicy(perTaskConcurrencyLimit: [.translation: 1])
        )
        let firstOwner = AgentRunOwner(taskKind: .translation, entryId: 11, slotKey: "slot-1")
        let secondOwner = AgentRunOwner(taskKind: .translation, entryId: 22, slotKey: "slot-2")
        let firstSpec = AgentTaskSpec(owner: firstOwner, requestSource: .manual)
        let secondSpec = AgentTaskSpec(owner: secondOwner, requestSource: .manual)

        let stream = await engine.events()
        var iterator = stream.makeAsyncIterator()

        #expect(await engine.submit(spec: firstSpec) == .startNow)
        #expect(await engine.submit(spec: secondSpec) == .queuedWaiting(position: 1))

        let activatedFirst = await iterator.next()
        let queuedSecond = await iterator.next()

        let result = await engine.finish(owner: firstOwner, terminalPhase: .completed, reason: nil)
        #expect(result.promotedOwner == secondOwner)

        let terminalFirst = await iterator.next()
        let activatedSecond = await iterator.next()
        let promotedEvent = await iterator.next()

        #expect(activatedFirst == .activated(taskId: firstSpec.taskId, owner: firstOwner, activeToken: activatedToken(from: activatedFirst)))
        #expect(queuedSecond == .queued(taskId: secondSpec.taskId, owner: secondOwner, position: 1))
        #expect(terminalFirst == .terminal(taskId: firstSpec.taskId, owner: firstOwner, phase: .completed, reason: nil))
        #expect(activatedSecond == .activated(taskId: secondSpec.taskId, owner: secondOwner, activeToken: activatedToken(from: activatedSecond)))
        #expect(promotedEvent == .promoted(from: firstOwner, to: secondOwner))
    }

    @Test("Update phase emits phase and progress events")
    func updatePhaseEmitsPhaseAndProgress() async {
        let engine = AgentRuntimeEngine(
            policy: AgentRuntimePolicy(perTaskConcurrencyLimit: [.summary: 1])
        )
        let owner = AgentRunOwner(taskKind: .summary, entryId: 7, slotKey: "en|short")
        let spec = AgentTaskSpec(owner: owner, requestSource: .manual)

        let stream = await engine.events()
        var iterator = stream.makeAsyncIterator()

        #expect(await engine.submit(spec: spec) == .startNow)
        _ = await iterator.next()

        let progress = AgentRunProgress(completed: 1, total: 3)
        await engine.updatePhase(owner: owner, phase: .generating, statusText: "Generating...", progress: progress)

        let phaseEvent = await iterator.next()
        let progressEvent = await iterator.next()
        #expect(phaseEvent == .phaseChanged(taskId: spec.taskId, owner: owner, phase: .generating))
        #expect(progressEvent == .progressUpdated(taskId: spec.taskId, owner: owner, progress: progress))
    }

    @Test("Translation waiting drop emits dropped event and prevents later activation")
    func translationWaitingDropEventAndNoLaterActivation() async {
        let engine = AgentRuntimeEngine(
            policy: AgentRuntimePolicy(perTaskConcurrencyLimit: [.translation: 1])
        )
        let activeOwner = AgentRunOwner(taskKind: .translation, entryId: 1001, slotKey: "slot-a")
        let waitingOwner = AgentRunOwner(taskKind: .translation, entryId: 1002, slotKey: "slot-b")
        let activeSpec = AgentTaskSpec(owner: activeOwner, requestSource: .manual)
        let waitingSpec = AgentTaskSpec(owner: waitingOwner, requestSource: .manual)

        let stream = await engine.events()
        var iterator = stream.makeAsyncIterator()

        #expect(await engine.submit(spec: activeSpec) == .startNow)
        #expect(await engine.submit(spec: waitingSpec) == .queuedWaiting(position: 1))

        _ = await iterator.next()
        _ = await iterator.next()

        await engine.abandonWaiting(taskKind: .translation, entryId: waitingOwner.entryId)
        let dropped = await iterator.next()
        #expect(dropped == .dropped(taskId: waitingSpec.taskId, owner: waitingOwner, reason: "abandoned_by_entry_switch"))
        #expect(await engine.state(for: waitingOwner)?.phase == .cancelled)

        let result = await engine.finish(owner: activeOwner, terminalPhase: .completed, reason: nil)
        #expect(result.promotedOwner == nil)

        let terminal = await iterator.next()
        let promoted = await iterator.next()
        #expect(terminal == .terminal(taskId: activeSpec.taskId, owner: activeOwner, phase: .completed, reason: nil))
        #expect(promoted == .promoted(from: activeOwner, to: nil))
    }

    private func activatedToken(from event: AgentRuntimeEvent?) -> String {
        guard case let .activated(_, _, token)? = event else {
            return ""
        }
        return token
    }
}
