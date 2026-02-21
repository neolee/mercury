import Foundation

nonisolated enum AgentTaskKind: String, CaseIterable, Codable, Sendable {
    case summary
    case translation
    case tagging
}

nonisolated enum AgentRunPhase: String, Codable, Sendable {
    case idle
    case waiting
    case requesting
    case generating
    case persisting
    case completed
    case failed
    case cancelled
    case timedOut
}

nonisolated struct AgentRunOwner: Hashable, Codable, Sendable {
    let taskKind: AgentTaskKind
    let entryId: Int64
    let slotKey: String
}

nonisolated struct AgentRunProgress: Equatable, Codable, Sendable {
    let completed: Int
    let total: Int
}

nonisolated struct AgentRunState: Equatable, Codable, Sendable {
    var owner: AgentRunOwner
    var phase: AgentRunPhase
    var statusText: String?
    var progress: AgentRunProgress?
    var updatedAt: Date
}

nonisolated enum AgentRunRequestDecision: Equatable, Sendable {
    case startNow
    case queuedWaiting(position: Int)
    case alreadyActive
    case alreadyWaiting(position: Int)
}

nonisolated struct AgentRuntimePolicy: Sendable {
    var perTaskConcurrencyLimit: [AgentTaskKind: Int]

    init(perTaskConcurrencyLimit: [AgentTaskKind: Int] = [.summary: 1, .translation: 1, .tagging: 2]) {
        self.perTaskConcurrencyLimit = perTaskConcurrencyLimit
    }

    func limit(for taskKind: AgentTaskKind) -> Int {
        max(1, perTaskConcurrencyLimit[taskKind] ?? 1)
    }
}

nonisolated struct AgentRunSnapshot: Sendable {
    let activeByTask: [AgentTaskKind: Set<AgentRunOwner>]
    let waitingByTask: [AgentTaskKind: [AgentRunOwner]]
    let states: [AgentRunOwner: AgentRunState]
}
