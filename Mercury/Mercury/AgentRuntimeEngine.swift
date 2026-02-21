import Foundation

actor AgentRuntimeEngine {
    private let policy: AgentRuntimePolicy
    private var store = AgentRuntimeStore()

    init(policy: AgentRuntimePolicy = AgentRuntimePolicy()) {
        self.policy = policy
    }

    func requestStart(owner: AgentRunOwner, at now: Date = Date()) -> AgentRunRequestDecision {
        if store.isActive(owner) {
            return .alreadyActive
        }

        if let position = store.waitingPosition(of: owner) {
            return .alreadyWaiting(position: position)
        }

        if store.activeCount(for: owner.taskKind) < policy.limit(for: owner.taskKind) {
            store.activate(
                owner: owner,
                phase: .requesting,
                statusText: nil,
                progress: nil,
                at: now
            )
            return .startNow
        }

        let position = store.enqueueWaiting(
            owner: owner,
            statusText: "Waiting for last generation to finish...",
            at: now
        )
        return .queuedWaiting(position: position)
    }

    func updatePhase(
        owner: AgentRunOwner,
        phase: AgentRunPhase,
        statusText: String? = nil,
        progress: AgentRunProgress? = nil,
        at now: Date = Date()
    ) {
        guard let current = store.state(for: owner) else { return }
        guard AgentRunStateMachine.canTransition(from: current.phase, to: phase) else { return }
        store.updateState(
            owner: owner,
            phase: phase,
            statusText: statusText,
            progress: progress,
            at: now
        )
    }

    func finish(owner: AgentRunOwner, terminalPhase: AgentRunPhase, at now: Date = Date()) -> AgentRunOwner? {
        precondition(AgentRunStateMachine.isTerminal(terminalPhase))

        store.removeFromActive(owner)

        if let current = store.state(for: owner),
           AgentRunStateMachine.canTransition(from: current.phase, to: terminalPhase) {
            store.updateStatePhaseOnly(owner: owner, phase: terminalPhase, at: now)
        }

        return promoteNextWaitingIfPossible(taskKind: owner.taskKind, at: now)
    }

    func abandonWaiting(taskKind: AgentTaskKind? = nil, entryId: Int64, at now: Date = Date()) {
        let kinds = taskKind.map { [$0] } ?? AgentTaskKind.allCases
        for kind in kinds {
            let removed = store.removeWaiting(taskKind: kind) { $0.entryId == entryId }
            for owner in removed {
                if let current = store.state(for: owner),
                   AgentRunStateMachine.canTransition(from: current.phase, to: .cancelled) {
                    store.updateState(
                        owner: owner,
                        phase: .cancelled,
                        statusText: nil,
                        progress: nil,
                        at: now
                    )
                }
            }
        }
    }

    func abandonWaiting(owner: AgentRunOwner, at now: Date = Date()) {
        guard store.removeWaiting(owner: owner) else { return }
        if let current = store.state(for: owner),
           AgentRunStateMachine.canTransition(from: current.phase, to: .cancelled) {
            store.updateState(
                owner: owner,
                phase: .cancelled,
                statusText: nil,
                progress: nil,
                at: now
            )
        }
    }

    func state(for owner: AgentRunOwner) -> AgentRunState? {
        store.state(for: owner)
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

    private func promoteNextWaitingIfPossible(taskKind: AgentTaskKind, at now: Date) -> AgentRunOwner? {
        guard store.activeCount(for: taskKind) < policy.limit(for: taskKind) else {
            return nil
        }
        guard let next = store.popWaiting(taskKind: taskKind) else {
            return nil
        }

        if let current = store.state(for: next),
           AgentRunStateMachine.canTransition(from: current.phase, to: .requesting) {
            store.activate(owner: next, phase: .requesting, statusText: nil, progress: nil, at: now)
        } else {
            store.activate(owner: next, phase: .requesting, statusText: nil, progress: nil, at: now)
        }

        return next
    }
}
