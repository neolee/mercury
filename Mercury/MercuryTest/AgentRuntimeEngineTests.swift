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
        let firstSpec = AgentTaskSpec(owner: first, requestSource: .manual)
        let secondSpec = AgentTaskSpec(owner: second, requestSource: .manual)

        #expect(await engine.submit(spec: firstSpec) == .startNow)
        #expect(await engine.submit(spec: secondSpec) == .queuedWaiting(position: 1))

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
        let activeSpec = AgentTaskSpec(owner: active, requestSource: .manual)
        let waitingSpec = AgentTaskSpec(owner: waiting, requestSource: .manual)

        #expect(await engine.submit(spec: activeSpec) == .startNow)
        #expect(await engine.submit(spec: waitingSpec) == .queuedWaiting(position: 1))

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
        let summarySpec = AgentTaskSpec(owner: summary, requestSource: .manual)
        let translationSpec = AgentTaskSpec(owner: translation, requestSource: .manual)

        #expect(await engine.submit(spec: summarySpec) == .startNow)
        #expect(await engine.submit(spec: translationSpec) == .startNow)

        let snapshot = await engine.snapshot()
        #expect(snapshot.activeByTask[.summary]?.contains(summary) == true)
        #expect(snapshot.activeByTask[.translation]?.contains(translation) == true)
    }

    @Test("Abandon waiting owner removes it from queue and prevents later promotion")
    func abandonWaitingOwnerRemovesQueueItem() async {
        // Uses capacity 2 to allow two waiting owners in the queue simultaneously.
        let twoSlotPolicy = AgentQueuePolicy(
            concurrentLimitPerKind: 1,
            waitingCapacityPerKind: 2,
            replacementWhenFull: .latestOnlyReplaceWaiting
        )
        let engine = AgentRuntimeEngine(
            policy: AgentRuntimePolicy(perTaskConcurrencyLimit: [.summary: 1])
        )
        let active = AgentRunOwner(taskKind: .summary, entryId: 1, slotKey: "en|medium")
        let waitingB = AgentRunOwner(taskKind: .summary, entryId: 2, slotKey: "en|medium")
        let waitingC = AgentRunOwner(taskKind: .summary, entryId: 3, slotKey: "en|medium")

        #expect(await engine.submit(spec: AgentTaskSpec(owner: active, requestSource: .manual, queuePolicy: twoSlotPolicy)) == .startNow)
        #expect(await engine.submit(spec: AgentTaskSpec(owner: waitingB, requestSource: .manual, queuePolicy: twoSlotPolicy)) == .queuedWaiting(position: 1))
        #expect(await engine.submit(spec: AgentTaskSpec(owner: waitingC, requestSource: .manual, queuePolicy: twoSlotPolicy)) == .queuedWaiting(position: 2))

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
        let specA = AgentTaskSpec(owner: activeA, requestSource: .manual)
        let specB = AgentTaskSpec(owner: waitingB, requestSource: .manual)

        #expect(await engine.submit(spec: specA) == .startNow)
        #expect(await engine.submit(spec: specB) == .queuedWaiting(position: 1))
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
        let spec = AgentTaskSpec(owner: owner, requestSource: .manual)

        #expect(await engine.submit(spec: spec) == .startNow)
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

    @Test("latestOnlyReplaceWaiting drops current waiting owner and queues the new one as sole waiting")
    func latestOnlyReplaceWaiting_dropsWaitingOwnerAndQueuesLatest() async {
        let engine = AgentRuntimeEngine(
            policy: AgentRuntimePolicy(perTaskConcurrencyLimit: [.translation: 1])
        )
        let ownerA = AgentRunOwner(taskKind: .translation, entryId: 1, slotKey: "slot-a")
        let ownerB = AgentRunOwner(taskKind: .translation, entryId: 2, slotKey: "slot-b")
        let ownerC = AgentRunOwner(taskKind: .translation, entryId: 3, slotKey: "slot-c")
        // Default AgentQueuePolicy: waitingCapacityPerKind = 1, latestOnlyReplaceWaiting.
        let specA = AgentTaskSpec(owner: ownerA, requestSource: .manual)
        let specB = AgentTaskSpec(owner: ownerB, requestSource: .auto)
        let specC = AgentTaskSpec(owner: ownerC, requestSource: .auto)

        let stream = await engine.events()
        var iterator = stream.makeAsyncIterator()

        // A goes active; B fills the single waiting slot.
        #expect(await engine.submit(spec: specA) == .startNow)
        #expect(await engine.submit(spec: specB) == .queuedWaiting(position: 1))
        // C is submitted: B is dropped (capacity full, latestOnlyReplaceWaiting) and C becomes
        // the new sole waiting owner.
        #expect(await engine.submit(spec: specC) == .queuedWaiting(position: 1))

        let activatedA = await iterator.next()
        let queuedB = await iterator.next()
        let droppedB = await iterator.next()
        let queuedC = await iterator.next()

        #expect(activatedA == .activated(taskId: specA.taskId, owner: ownerA, activeToken: activatedToken(from: activatedA)))
        #expect(queuedB == .queued(taskId: specB.taskId, owner: ownerB, position: 1))
        #expect(droppedB == .dropped(taskId: specB.taskId, owner: ownerB, reason: "replaced_by_latest"))
        #expect(queuedC == .queued(taskId: specC.taskId, owner: ownerC, position: 1))
        #expect(await engine.state(for: ownerB)?.phase == .cancelled)

        // A completes: C is promoted; B is not (it was already dropped).
        let result = await engine.finish(owner: ownerA, terminalPhase: .completed, reason: nil)
        #expect(result.promotedOwner == ownerC)

        let terminalA = await iterator.next()
        let activatedC = await iterator.next()
        let promotedEvent = await iterator.next()

        #expect(terminalA == .terminal(taskId: specA.taskId, owner: ownerA, phase: .completed, reason: nil))
        #expect(activatedC == .activated(taskId: specC.taskId, owner: ownerC, activeToken: activatedToken(from: activatedC)))
        #expect(promotedEvent == .promoted(from: ownerA, to: ownerC))
    }

    @Test("Summary completion does not promote a waiting translation owner")
    func summaryCompletion_doesNotPromoteWaitingTranslationOwner() async {
        let engine = AgentRuntimeEngine(
            policy: AgentRuntimePolicy(perTaskConcurrencyLimit: [.summary: 1, .translation: 1])
        )
        let summaryA = AgentRunOwner(taskKind: .summary, entryId: 1, slotKey: "en|medium")
        let translationB = AgentRunOwner(taskKind: .translation, entryId: 2, slotKey: "slot-b")
        let translationC = AgentRunOwner(taskKind: .translation, entryId: 3, slotKey: "slot-c")

        let specA = AgentTaskSpec(owner: summaryA, requestSource: .manual)
        let specB = AgentTaskSpec(owner: translationB, requestSource: .manual)
        let specC = AgentTaskSpec(owner: translationC, requestSource: .manual)

        // summaryA and translationB both go active (different kinds, separate slots).
        #expect(await engine.submit(spec: specA) == .startNow)
        #expect(await engine.submit(spec: specB) == .startNow)
        // translationC waits behind translationB.
        #expect(await engine.submit(spec: specC) == .queuedWaiting(position: 1))
        #expect(await engine.state(for: translationC)?.phase == .waiting)

        // summaryA completes: translationC must remain waiting, not be promoted.
        let summaryResult = await engine.finish(owner: summaryA, terminalPhase: .completed, reason: nil)
        #expect(summaryResult.promotedOwner == nil)
        #expect(await engine.state(for: translationC)?.phase == .waiting)

        // translationB completes: translationC is now promoted.
        let translationResult = await engine.finish(owner: translationB, terminalPhase: .completed, reason: nil)
        #expect(translationResult.promotedOwner == translationC)
        #expect(await engine.state(for: translationC)?.phase == .requesting)
    }

    @Test("updatePhase and finish with stale activeToken are ignored")
    func updatePhase_staleActiveToken_isIgnored() async {
        let engine = AgentRuntimeEngine(
            policy: AgentRuntimePolicy(perTaskConcurrencyLimit: [.summary: 1])
        )
        let owner = AgentRunOwner(taskKind: .summary, entryId: 1, slotKey: "en|medium")
        let spec = AgentTaskSpec(owner: owner, requestSource: .manual)

        #expect(await engine.submit(spec: spec) == .startNow)
        let staleToken = "stale-token-000"

        // updatePhase with wrong token is silently rejected.
        await engine.updatePhase(owner: owner, phase: .generating, activeToken: staleToken)
        #expect(await engine.state(for: owner)?.phase == .requesting)

        // updatePhase with correct token succeeds.
        let validToken = await engine.activeToken(for: owner) ?? ""
        #expect(validToken.isEmpty == false)
        await engine.updatePhase(owner: owner, phase: .generating, activeToken: validToken)
        #expect(await engine.state(for: owner)?.phase == .generating)

        // finish with stale token is silently rejected: no promotion, no terminal transition.
        let staleFinish = await engine.finish(owner: owner, terminalPhase: .completed, reason: nil, activeToken: staleToken)
        #expect(staleFinish.promotedOwner == nil)
        #expect(staleFinish.droppedOwners.isEmpty)
        #expect(await engine.state(for: owner)?.phase == .generating)

        // finish with valid token succeeds.
        let validFinish = await engine.finish(owner: owner, terminalPhase: .completed, reason: nil, activeToken: validToken)
        #expect(validFinish.promotedOwner == nil)
        #expect(await engine.state(for: owner)?.phase == .completed)
    }

    private func activatedToken(from event: AgentRuntimeEvent?) -> String {
        guard case let .activated(_, _, token)? = event else {
            return ""
        }
        return token
    }
}
