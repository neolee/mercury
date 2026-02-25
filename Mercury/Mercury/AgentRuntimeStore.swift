import Foundation

nonisolated struct AgentRuntimeStore {
    var activeByTask: [AgentTaskKind: Set<AgentRunOwner>] = [:]
    var waitingByTask: [AgentTaskKind: [AgentRunOwner]] = [:]
    var states: [AgentRunOwner: AgentRunState] = [:]
    var specByOwner: [AgentRunOwner: AgentTaskSpec] = [:]
    var activeTokenByOwner: [AgentRunOwner: String] = [:]

    func isActive(_ owner: AgentRunOwner) -> Bool {
        activeByTask[owner.taskKind, default: []].contains(owner)
    }

    func waitingPosition(of owner: AgentRunOwner) -> Int? {
        waitingByTask[owner.taskKind, default: []]
            .firstIndex(of: owner)
            .map { $0 + 1 }
    }

    func activeCount(for taskKind: AgentTaskKind) -> Int {
        activeByTask[taskKind, default: []].count
    }

    mutating func activate(
        owner: AgentRunOwner,
        taskId: AgentTaskID,
        activeToken: String? = nil,
        phase: AgentRunPhase,
        statusText: String?,
        progress: AgentRunProgress?,
        at now: Date
    ) {
        var active = activeByTask[owner.taskKind, default: []]
        active.insert(owner)
        activeByTask[owner.taskKind] = active
        activeTokenByOwner[owner] = activeToken
        states[owner] = AgentRunState(
            taskId: taskId,
            owner: owner,
            phase: phase,
            statusText: statusText,
            progress: progress,
            activeToken: activeToken,
            terminalReason: nil,
            updatedAt: now
        )
    }

    mutating func enqueueWaiting(owner: AgentRunOwner, taskId: AgentTaskID, statusText: String?, at now: Date) -> Int {
        var waiting = waitingByTask[owner.taskKind, default: []]
        waiting.append(owner)
        waitingByTask[owner.taskKind] = waiting
        states[owner] = AgentRunState(
            taskId: taskId,
            owner: owner,
            phase: .waiting,
            statusText: statusText,
            progress: nil,
            activeToken: nil,
            terminalReason: nil,
            updatedAt: now
        )
        return waiting.count
    }

    mutating func removeFromActive(_ owner: AgentRunOwner) {
        var active = activeByTask[owner.taskKind, default: []]
        active.remove(owner)
        activeByTask[owner.taskKind] = active
        activeTokenByOwner[owner] = nil
    }

    mutating func updateState(
        owner: AgentRunOwner,
        phase: AgentRunPhase,
        statusText: String?,
        progress: AgentRunProgress?,
        terminalReason: String? = nil,
        at now: Date
    ) {
        guard var state = states[owner] else { return }
        state.phase = phase
        state.statusText = statusText
        state.progress = progress
        if let terminalReason {
            state.terminalReason = terminalReason
        }
        state.updatedAt = now
        states[owner] = state
    }

    mutating func updateStatePhaseOnly(owner: AgentRunOwner, phase: AgentRunPhase, at now: Date) {
        guard var state = states[owner] else { return }
        state.phase = phase
        state.updatedAt = now
        states[owner] = state
    }

    mutating func popWaiting(taskKind: AgentTaskKind) -> AgentRunOwner? {
        var queue = waitingByTask[taskKind, default: []]
        guard queue.isEmpty == false else { return nil }
        let owner = queue.removeFirst()
        waitingByTask[taskKind] = queue
        return owner
    }

    mutating func removeWaiting(owner: AgentRunOwner) -> Bool {
        var queue = waitingByTask[owner.taskKind, default: []]
        let countBefore = queue.count
        queue.removeAll { $0 == owner }
        waitingByTask[owner.taskKind] = queue
        return queue.count < countBefore
    }

    mutating func removeWaiting(taskKind: AgentTaskKind, matching predicate: (AgentRunOwner) -> Bool) -> [AgentRunOwner] {
        var queue = waitingByTask[taskKind, default: []]
        let removed = queue.filter(predicate)
        queue.removeAll(where: predicate)
        waitingByTask[taskKind] = queue
        return removed
    }

    func state(for owner: AgentRunOwner) -> AgentRunState? {
        states[owner]
    }

    mutating func upsertSpec(_ spec: AgentTaskSpec) {
        specByOwner[spec.owner] = spec
    }

    func spec(for owner: AgentRunOwner) -> AgentTaskSpec? {
        specByOwner[owner]
    }

    mutating func setActiveToken(owner: AgentRunOwner, token: String?) {
        activeTokenByOwner[owner] = token
        guard var state = states[owner] else { return }
        state.activeToken = token
        states[owner] = state
    }

    func activeToken(for owner: AgentRunOwner) -> String? {
        activeTokenByOwner[owner]
    }

    mutating func removeTask(owner: AgentRunOwner) {
        _ = removeWaiting(owner: owner)
        removeFromActive(owner)
        activeTokenByOwner[owner] = nil
        specByOwner[owner] = nil
        states[owner] = nil
    }

    func snapshot() -> AgentRunSnapshot {
        AgentRunSnapshot(
            activeByTask: activeByTask,
            waitingByTask: waitingByTask,
            states: states
        )
    }
}
