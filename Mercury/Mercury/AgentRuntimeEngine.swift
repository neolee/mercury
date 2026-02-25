import Foundation

actor AgentRuntimeEngine {
    private let policy: AgentRuntimePolicy
    private var store = AgentRuntimeStore()
    private var eventContinuations: [UUID: AsyncStream<AgentRuntimeEvent>.Continuation] = [:]

    init(policy: AgentRuntimePolicy = AgentRuntimePolicy()) {
        self.policy = policy
    }

    func submit(spec: AgentTaskSpec, at now: Date = Date()) -> AgentRunRequestDecision {
        let owner = spec.owner
        store.upsertSpec(spec)

        if store.isActive(owner) {
            return .alreadyActive
        }

        if let position = store.waitingPosition(of: owner) {
            return .alreadyWaiting(position: position)
        }

        if store.activeCount(for: owner.taskKind) < policy.limit(for: owner.taskKind) {
            let activeToken = UUID().uuidString
            store.activate(
                owner: owner,
                taskId: spec.taskId,
                activeToken: activeToken,
                phase: .requesting,
                statusText: nil,
                progress: nil,
                at: now
            )
            emit(.activated(taskId: spec.taskId, owner: owner, activeToken: activeToken))
            return .startNow
        }

        // When the waiting queue is at capacity, pop from the front (oldest first) until exactly
        // one slot is free, then enqueue the incoming owner at the back. Oldest tasks are dropped
        // so the newest candidate always survives.
        // Waiting capacity is owned by runtime policy (`perTaskWaitingLimit`).
        let currentWaitingCount = store.waitingByTask[owner.taskKind, default: []].count
        let waitingLimit = policy.waitingLimit(for: owner.taskKind)
        let excessCount = max(0, currentWaitingCount - waitingLimit + 1)
        for _ in 0..<excessCount {
            guard let droppedOwner = store.popWaiting(taskKind: owner.taskKind) else { break }
            guard let droppedTaskId = taskID(for: droppedOwner) else {
                assertionFailure("Missing task ID for dropped owner: \(droppedOwner)")
                continue
            }
            if let current = store.state(for: droppedOwner),
               AgentRunStateMachine.canTransition(from: current.phase, to: .cancelled) {
                store.updateState(
                    owner: droppedOwner,
                    phase: .cancelled,
                    statusText: nil,
                    progress: nil,
                    terminalReason: AgentFailureReason.cancelled.rawValue,
                    at: now
                )
            }
            emit(.dropped(taskId: droppedTaskId, owner: droppedOwner, reason: "replaced_by_latest"))
        }

        let position = store.enqueueWaiting(
            owner: owner,
            taskId: spec.taskId,
            statusText: nil,
            at: now
        )
        emit(.queued(taskId: spec.taskId, owner: owner, position: position))
        return .queuedWaiting(position: position)
    }

    func updatePhase(
        owner: AgentRunOwner,
        phase: AgentRunPhase,
        statusText: String? = nil,
        progress: AgentRunProgress? = nil,
        activeToken: String? = nil,
        at now: Date = Date()
    ) {
        guard let current = store.state(for: owner) else { return }
        if let activeToken, store.activeToken(for: owner) != activeToken { return }
        guard AgentRunStateMachine.canTransition(from: current.phase, to: phase) else { return }
        store.updateState(
            owner: owner,
            phase: phase,
            statusText: statusText,
            progress: progress,
            at: now
        )

        let taskId = current.taskId
        emit(.phaseChanged(taskId: taskId, owner: owner, phase: phase))
        if let progress {
            emit(.progressUpdated(taskId: taskId, owner: owner, progress: progress))
        }
    }

    func finish(owner: AgentRunOwner, terminalPhase: AgentRunPhase, at now: Date = Date()) -> AgentRunOwner? {
        finish(owner: owner, terminalPhase: terminalPhase, reason: nil, at: now).promotedOwner
    }

    func finish(
        owner: AgentRunOwner,
        terminalPhase: AgentRunPhase,
        reason: AgentFailureReason?,
        activeToken: String? = nil,
        at now: Date = Date()
    ) -> AgentPromotionResult {
        precondition(AgentRunStateMachine.isTerminal(terminalPhase))
        if let activeToken, store.activeToken(for: owner) != activeToken {
            return AgentPromotionResult(promotedOwner: nil, droppedOwners: [])
        }
        guard let taskId = taskID(for: owner) else {
            assertionFailure("Missing task ID for finished owner: \(owner)")
            return AgentPromotionResult(promotedOwner: nil, droppedOwners: [])
        }

        store.removeFromActive(owner)

        if let current = store.state(for: owner),
           AgentRunStateMachine.canTransition(from: current.phase, to: terminalPhase) {
            store.updateState(
                owner: owner,
                phase: terminalPhase,
                statusText: current.statusText,
                progress: current.progress,
                terminalReason: reason?.rawValue,
                at: now
            )
        }

        emit(.terminal(taskId: taskId, owner: owner, phase: terminalPhase, reason: reason))

        let promotedOwner = promoteNextWaitingIfPossible(taskKind: owner.taskKind, at: now)
        emit(.promoted(from: owner, to: promotedOwner))

        return AgentPromotionResult(promotedOwner: promotedOwner)
    }

    func abandonWaiting(taskKind: AgentTaskKind? = nil, entryId: Int64, at now: Date = Date()) {
        let kinds = taskKind.map { [$0] } ?? AgentTaskKind.allCases
        for kind in kinds {
            let removed = store.removeWaiting(taskKind: kind) { $0.entryId == entryId }
            for owner in removed {
                guard let taskId = taskID(for: owner) else {
                    assertionFailure("Missing task ID for abandoned owner by entry switch: \(owner)")
                    continue
                }
                if let current = store.state(for: owner),
                   AgentRunStateMachine.canTransition(from: current.phase, to: .cancelled) {
                    store.updateState(
                        owner: owner,
                        phase: .cancelled,
                        statusText: nil,
                        progress: nil,
                        terminalReason: AgentFailureReason.cancelled.rawValue,
                        at: now
                    )
                }
                emit(.dropped(taskId: taskId, owner: owner, reason: "abandoned_by_entry_switch"))
            }
        }
    }

    func abandonWaiting(owner: AgentRunOwner, at now: Date = Date()) {
        guard store.removeWaiting(owner: owner) else { return }
        guard let taskId = taskID(for: owner) else {
            assertionFailure("Missing task ID for abandoned owner: \(owner)")
            return
        }
        if let current = store.state(for: owner),
           AgentRunStateMachine.canTransition(from: current.phase, to: .cancelled) {
            store.updateState(
                owner: owner,
                phase: .cancelled,
                statusText: nil,
                progress: nil,
                terminalReason: AgentFailureReason.cancelled.rawValue,
                at: now
            )
        }
        emit(.dropped(taskId: taskId, owner: owner, reason: "abandoned_by_owner"))
    }

    func state(for owner: AgentRunOwner) -> AgentRunState? {
        store.state(for: owner)
    }

    func activeToken(for owner: AgentRunOwner) -> String? {
        store.activeToken(for: owner)
    }

    func statusProjection(for owner: AgentRunOwner) -> AgentRuntimeStatusProjection? {
        guard let state = store.state(for: owner) else {
            return nil
        }
        return AgentRuntimeProjection.statusProjection(state: state)
    }

    func snapshot() -> AgentRunSnapshot {
        store.snapshot()
    }

    func events() -> AsyncStream<AgentRuntimeEvent> {
        let streamId = UUID()
        return AsyncStream { continuation in
            eventContinuations[streamId] = continuation
            continuation.onTermination = { [weak self] _ in
                Task {
                    await self?.removeContinuation(id: streamId)
                }
            }
        }
    }

    private func removeContinuation(id: UUID) {
        eventContinuations[id] = nil
    }

    private func emit(_ event: AgentRuntimeEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    private func promoteNextWaitingIfPossible(taskKind: AgentTaskKind, at now: Date) -> AgentRunOwner? {
        guard store.activeCount(for: taskKind) < policy.limit(for: taskKind) else {
            return nil
        }
        guard let next = store.popWaiting(taskKind: taskKind) else {
            return nil
        }

        guard let taskId = taskID(for: next) else {
            assertionFailure("Missing task ID for promoted owner: \(next)")
            return nil
        }
        let activeToken = UUID().uuidString

        store.activate(
            owner: next,
            taskId: taskId,
            activeToken: activeToken,
            phase: .requesting,
            statusText: nil,
            progress: nil,
            at: now
        )

        emit(.activated(taskId: taskId, owner: next, activeToken: activeToken))

        return next
    }

    private func taskID(for owner: AgentRunOwner) -> AgentTaskID? {
        store.state(for: owner)?.taskId ?? store.spec(for: owner)?.taskId
    }
}
