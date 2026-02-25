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

typealias AgentTaskID = UUID
typealias AgentTaskOwner = AgentRunOwner

nonisolated enum AgentTaskRequestSource: String, Codable, Sendable {
    case manual
    case auto
    case system
}

nonisolated enum AgentVisibilityPolicy: String, Codable, Sendable {
    case selectedEntryOnly
    case always
}

nonisolated struct AgentTaskSpec: Equatable, Codable, Sendable {
    let taskId: AgentTaskID
    let owner: AgentTaskOwner
    let requestSource: AgentTaskRequestSource
    let visibilityPolicy: AgentVisibilityPolicy
    let submittedAt: Date

    init(
        taskId: AgentTaskID,
        owner: AgentTaskOwner,
        requestSource: AgentTaskRequestSource,
        visibilityPolicy: AgentVisibilityPolicy = .selectedEntryOnly,
        submittedAt: Date = Date()
    ) {
        self.taskId = taskId
        self.owner = owner
        self.requestSource = requestSource
        self.visibilityPolicy = visibilityPolicy
        self.submittedAt = submittedAt
    }
}

nonisolated struct AgentRunProgress: Equatable, Codable, Sendable {
    let completed: Int
    let total: Int
}

nonisolated struct AgentRunState: Equatable, Codable, Sendable {
    var taskId: AgentTaskID
    var owner: AgentRunOwner
    var phase: AgentRunPhase
    var statusText: String?
    var progress: AgentRunProgress?
    var activeToken: String?
    var terminalReason: String?
    var updatedAt: Date
}

typealias AgentTaskState = AgentRunState

nonisolated enum AgentRunRequestDecision: Equatable, Sendable {
    case startNow
    case queuedWaiting(position: Int)
    case alreadyActive
    case alreadyWaiting(position: Int)
}

nonisolated struct AgentPromotionResult: Equatable, Sendable {
    let promotedOwner: AgentRunOwner?
    let droppedOwners: [AgentRunOwner]

    init(promotedOwner: AgentRunOwner?, droppedOwners: [AgentRunOwner] = []) {
        self.promotedOwner = promotedOwner
        self.droppedOwners = droppedOwners
    }
}

nonisolated enum AgentRuntimeEvent: Equatable, Sendable {
    case queued(taskId: AgentTaskID, owner: AgentRunOwner, position: Int)
    case activated(taskId: AgentTaskID, owner: AgentRunOwner, activeToken: String)
    case phaseChanged(taskId: AgentTaskID, owner: AgentRunOwner, phase: AgentRunPhase)
    case progressUpdated(taskId: AgentTaskID, owner: AgentRunOwner, progress: AgentRunProgress)
    case terminal(taskId: AgentTaskID, owner: AgentRunOwner, phase: AgentRunPhase, reason: AgentFailureReason?)
    case promoted(from: AgentRunOwner, to: AgentRunOwner?)
    case dropped(taskId: AgentTaskID, owner: AgentRunOwner, reason: String)
}

nonisolated struct AgentRuntimeEventLogEntry: Equatable, Sendable {
    let timestamp: Date
    let event: AgentRuntimeEvent
}

nonisolated struct AgentRuntimePolicy: Sendable {
    var perTaskConcurrencyLimit: [AgentTaskKind: Int]
    var perTaskWaitingLimit: [AgentTaskKind: Int]

    init(
        perTaskConcurrencyLimit: [AgentTaskKind: Int] = [.summary: 1, .translation: 1, .tagging: 2],
        perTaskWaitingLimit: [AgentTaskKind: Int] = [.summary: 1, .translation: 1, .tagging: 1]
    ) {
        self.perTaskConcurrencyLimit = perTaskConcurrencyLimit
        self.perTaskWaitingLimit = perTaskWaitingLimit
    }

    func limit(for taskKind: AgentTaskKind) -> Int {
        max(1, perTaskConcurrencyLimit[taskKind] ?? 1)
    }

    func waitingLimit(for taskKind: AgentTaskKind) -> Int {
        max(1, perTaskWaitingLimit[taskKind] ?? 1)
    }
}

nonisolated struct AgentRunSnapshot: Sendable {
    let activeByTask: [AgentTaskKind: Set<AgentRunOwner>]
    let waitingByTask: [AgentTaskKind: [AgentRunOwner]]
    let states: [AgentRunOwner: AgentRunState]
}
