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

nonisolated enum AgentQueueReplacementPolicy: String, Codable, Sendable {
    case latestOnlyReplaceWaiting
    case rejectNew
}

nonisolated enum AgentVisibilityPolicy: String, Codable, Sendable {
    case selectedEntryOnly
    case always
}

nonisolated struct AgentQueuePolicy: Equatable, Codable, Sendable {
    var concurrentLimitPerKind: Int
    var waitingCapacityPerKind: Int
    var replacementWhenFull: AgentQueueReplacementPolicy

    init(
        concurrentLimitPerKind: Int = 1,
        waitingCapacityPerKind: Int = 1,
        replacementWhenFull: AgentQueueReplacementPolicy = .latestOnlyReplaceWaiting
    ) {
        self.concurrentLimitPerKind = max(1, concurrentLimitPerKind)
        self.waitingCapacityPerKind = max(1, waitingCapacityPerKind)
        self.replacementWhenFull = replacementWhenFull
    }
}

nonisolated struct AgentTaskSpec: Equatable, Codable, Sendable {
    let taskId: AgentTaskID
    let owner: AgentTaskOwner
    let requestSource: AgentTaskRequestSource
    let queuePolicy: AgentQueuePolicy
    let visibilityPolicy: AgentVisibilityPolicy
    let submittedAt: Date

    init(
        taskId: AgentTaskID = UUID(),
        owner: AgentTaskOwner,
        requestSource: AgentTaskRequestSource,
        queuePolicy: AgentQueuePolicy = AgentQueuePolicy(),
        visibilityPolicy: AgentVisibilityPolicy = .selectedEntryOnly,
        submittedAt: Date = Date()
    ) {
        self.taskId = taskId
        self.owner = owner
        self.requestSource = requestSource
        self.queuePolicy = queuePolicy
        self.visibilityPolicy = visibilityPolicy
        self.submittedAt = submittedAt
    }
}

nonisolated struct AgentRunProgress: Equatable, Codable, Sendable {
    let completed: Int
    let total: Int
}

nonisolated struct AgentRunState: Equatable, Codable, Sendable {
    var taskId: AgentTaskID?
    var owner: AgentRunOwner
    var phase: AgentRunPhase
    var statusText: String?
    var progress: AgentRunProgress?
    var activeToken: String?
    var terminalReason: String?
    var updatedAt: Date
}

typealias AgentTaskState = AgentRunState

nonisolated enum AgentRuntimeContract {
    static let baselineConcurrentLimitPerKind = 1
    static let baselineWaitingCapacityPerKind = 1
}

nonisolated enum AgentRunRequestDecision: Equatable, Sendable {
    case startNow
    case queuedWaiting(position: Int)
    case alreadyActive
    case alreadyWaiting(position: Int)
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
