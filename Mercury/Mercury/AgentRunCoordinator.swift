import Foundation

actor AgentRunCoordinator {
    private let policy: AgentRunCoordinatorPolicy
    private var activeByTask: [AgentTaskKind: Set<AgentRunOwner>] = [:]
    private var waitingByTask: [AgentTaskKind: [AgentRunOwner]] = [:]
    private var states: [AgentRunOwner: AgentRunState] = [:]

    init(policy: AgentRunCoordinatorPolicy = AgentRunCoordinatorPolicy()) {
        self.policy = policy
    }

    func requestStart(owner: AgentRunOwner, at now: Date = Date()) -> AgentRunRequestDecision {
        if activeByTask[owner.taskKind, default: []].contains(owner) {
            return .alreadyActive
        }

        if let index = waitingByTask[owner.taskKind, default: []].firstIndex(of: owner) {
            return .alreadyWaiting(position: index + 1)
        }

        let activeCount = activeByTask[owner.taskKind, default: []].count
        if activeCount < policy.limit(for: owner.taskKind) {
            var set = activeByTask[owner.taskKind, default: []]
            set.insert(owner)
            activeByTask[owner.taskKind] = set
            states[owner] = AgentRunState(
                owner: owner,
                phase: .requesting,
                statusText: nil,
                progress: nil,
                updatedAt: now
            )
            return .startNow
        }

        var queue = waitingByTask[owner.taskKind, default: []]
        queue.append(owner)
        waitingByTask[owner.taskKind] = queue
        states[owner] = AgentRunState(
            owner: owner,
            phase: .waiting,
            statusText: "Waiting for last generation to finish...",
            progress: nil,
            updatedAt: now
        )
        return .queuedWaiting(position: queue.count)
    }

    func updatePhase(
        owner: AgentRunOwner,
        phase: AgentRunPhase,
        statusText: String? = nil,
        progress: AgentRunProgress? = nil,
        at now: Date = Date()
    ) {
        guard var state = states[owner] else {
            return
        }
        guard AgentRunStateMachine.canTransition(from: state.phase, to: phase) else {
            return
        }
        state.phase = phase
        state.statusText = statusText
        state.progress = progress
        state.updatedAt = now
        states[owner] = state
    }

    func finish(owner: AgentRunOwner, terminalPhase: AgentRunPhase, at now: Date = Date()) -> AgentRunOwner? {
        precondition(AgentRunStateMachine.isTerminal(terminalPhase))

        if var active = activeByTask[owner.taskKind] {
            active.remove(owner)
            activeByTask[owner.taskKind] = active
        }

        if var state = states[owner] {
            if AgentRunStateMachine.canTransition(from: state.phase, to: terminalPhase) {
                state.phase = terminalPhase
                state.updatedAt = now
                states[owner] = state
            }
        }

        return promoteNextWaitingIfPossible(taskKind: owner.taskKind, at: now)
    }

    func abandonWaiting(taskKind: AgentTaskKind? = nil, entryId: Int64, at now: Date = Date()) {
        let kinds = taskKind.map { [$0] } ?? AgentTaskKind.allCases
        for kind in kinds {
            var queue = waitingByTask[kind, default: []]
            let removedOwners = queue.filter { $0.entryId == entryId }
            queue.removeAll { $0.entryId == entryId }
            waitingByTask[kind] = queue

            for owner in removedOwners {
                if var state = states[owner] {
                    if AgentRunStateMachine.canTransition(from: state.phase, to: .cancelled) {
                        state.phase = .cancelled
                        state.statusText = nil
                        state.progress = nil
                        state.updatedAt = now
                        states[owner] = state
                    }
                }
            }
        }
    }

    func abandonWaiting(owner: AgentRunOwner, at now: Date = Date()) {
        var queue = waitingByTask[owner.taskKind, default: []]
        let originalCount = queue.count
        queue.removeAll { $0 == owner }
        waitingByTask[owner.taskKind] = queue
        guard queue.count < originalCount else {
            return
        }

        if var state = states[owner] {
            if AgentRunStateMachine.canTransition(from: state.phase, to: .cancelled) {
                state.phase = .cancelled
                state.statusText = nil
                state.progress = nil
                state.updatedAt = now
                states[owner] = state
            }
        }
    }

    func state(for owner: AgentRunOwner) -> AgentRunState? {
        states[owner]
    }

    func snapshot() -> AgentRunSnapshot {
        AgentRunSnapshot(
            activeByTask: activeByTask,
            waitingByTask: waitingByTask,
            states: states
        )
    }

    private func promoteNextWaitingIfPossible(taskKind: AgentTaskKind, at now: Date) -> AgentRunOwner? {
        let activeCount = activeByTask[taskKind, default: []].count
        guard activeCount < policy.limit(for: taskKind) else {
            return nil
        }

        var queue = waitingByTask[taskKind, default: []]
        guard queue.isEmpty == false else {
            return nil
        }
        let next = queue.removeFirst()
        waitingByTask[taskKind] = queue

        var active = activeByTask[taskKind, default: []]
        active.insert(next)
        activeByTask[taskKind] = active

        if var state = states[next] {
            if AgentRunStateMachine.canTransition(from: state.phase, to: .requesting) {
                state.phase = .requesting
                state.statusText = nil
                state.progress = nil
                state.updatedAt = now
                states[next] = state
            }
        } else {
            states[next] = AgentRunState(
                owner: next,
                phase: .requesting,
                statusText: nil,
                progress: nil,
                updatedAt: now
            )
        }

        return next
    }
}
