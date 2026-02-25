import Foundation

typealias UnifiedTaskID = UUID

nonisolated enum UnifiedTaskIdentity {
    static func make() -> UnifiedTaskID {
        UUID()
    }
}

nonisolated enum UnifiedTaskFamily: String, Sendable {
    case agent
    case queueOnly
}

nonisolated enum UnifiedTaskKind: String, CaseIterable, Sendable {
    case bootstrap
    case syncAllFeeds
    case syncFeeds
    case importOPML
    case exportOPML
    case readerBuild
    case summary
    case translation
    case tagging
    case custom

    var family: UnifiedTaskFamily {
        switch self {
        case .summary, .translation, .tagging:
            return .agent
        case .bootstrap, .syncAllFeeds, .syncFeeds, .importOPML, .exportOPML, .readerBuild, .custom:
            return .queueOnly
        }
    }

    var appTaskKind: AppTaskKind {
        switch self {
        case .bootstrap:
            return .bootstrap
        case .syncAllFeeds:
            return .syncAllFeeds
        case .syncFeeds:
            return .syncFeeds
        case .importOPML:
            return .importOPML
        case .exportOPML:
            return .exportOPML
        case .readerBuild:
            return .readerBuild
        case .summary:
            return .summary
        case .translation:
            return .translation
        case .tagging, .custom:
            return .custom
        }
    }

    var agentTaskKind: AgentTaskKind? {
        switch self {
        case .summary:
            return .summary
        case .translation:
            return .translation
        case .tagging:
            return .tagging
        case .bootstrap, .syncAllFeeds, .syncFeeds, .importOPML, .exportOPML, .readerBuild, .custom:
            return nil
        }
    }

    var agentTaskType: AgentTaskType? {
        switch self {
        case .summary:
            return .summary
        case .translation:
            return .translation
        case .tagging:
            return .tagging
        case .bootstrap, .syncAllFeeds, .syncFeeds, .importOPML, .exportOPML, .readerBuild, .custom:
            return nil
        }
    }
}

extension UnifiedTaskKind {
    nonisolated static func from(appTaskKind: AppTaskKind) -> UnifiedTaskKind {
        switch appTaskKind {
        case .bootstrap:
            return .bootstrap
        case .syncAllFeeds:
            return .syncAllFeeds
        case .syncFeeds:
            return .syncFeeds
        case .importOPML:
            return .importOPML
        case .exportOPML:
            return .exportOPML
        case .readerBuild:
            return .readerBuild
        case .summary:
            return .summary
        case .translation:
            return .translation
        case .custom:
            return .custom
        }
    }

    nonisolated static func from(agentTaskKind: AgentTaskKind) -> UnifiedTaskKind {
        switch agentTaskKind {
        case .summary:
            return .summary
        case .translation:
            return .translation
        case .tagging:
            return .tagging
        }
    }

    nonisolated static func from(agentTaskType: AgentTaskType) -> UnifiedTaskKind {
        switch agentTaskType {
        case .summary:
            return .summary
        case .translation:
            return .translation
        case .tagging:
            return .tagging
        }
    }
}

nonisolated enum TaskTerminalOutcome: Sendable, Equatable {
    case succeeded
    case failed(failureReason: AgentFailureReason?, message: String?)
    case timedOut(failureReason: AgentFailureReason?, message: String?)
    case cancelled(failureReason: AgentFailureReason?)

    var runtimeReason: String {
        switch self {
        case .succeeded:
            return "succeeded"
        case .failed:
            return "failed"
        case .timedOut:
            return "timed_out"
        case .cancelled:
            return "cancelled"
        }
    }

    var failureReason: AgentFailureReason? {
        switch self {
        case .failed(let failureReason, _),
                .timedOut(let failureReason, _),
                .cancelled(let failureReason):
            return failureReason
        case .succeeded:
            return nil
        }
    }

    var normalizedFailureReason: AgentFailureReason? {
        switch self {
        case .failed(let failureReason, _):
            return failureReason ?? .unknown
        case .timedOut(let failureReason, _):
            return failureReason ?? .timedOut
        case .cancelled(let failureReason):
            return failureReason ?? .cancelled
        case .succeeded:
            return nil
        }
    }

    var message: String? {
        switch self {
        case .failed(_, let message), .timedOut(_, let message):
            return message
        case .succeeded, .cancelled:
            return nil
        }
    }

    var agentTaskRunStatus: AgentTaskRunStatus {
        switch self {
        case .succeeded:
            return .succeeded
        case .failed:
            return .failed
        case .timedOut:
            return .timedOut
        case .cancelled:
            return .cancelled
        }
    }

    var agentRunPhase: AgentRunPhase {
        switch self {
        case .succeeded:
            return .completed
        case .failed:
            return .failed
        case .timedOut:
            return .timedOut
        case .cancelled:
            return .cancelled
        }
    }

    var usageStatus: LLMUsageRequestStatus {
        switch self {
        case .succeeded:
            return .succeeded
        case .failed:
            return .failed
        case .timedOut:
            return .timedOut
        case .cancelled:
            return .cancelled
        }
    }

    func appTaskState(
        defaultFailureMessage: String = "Task failed.",
        defaultTimeoutMessage: String = "Task timed out."
    ) -> AppTaskState {
        switch self {
        case .succeeded:
            return .succeeded
        case .failed(_, let message):
            return .failed(message ?? defaultFailureMessage)
        case .timedOut(_, let message):
            return .timedOut(message ?? defaultTimeoutMessage)
        case .cancelled:
            return .cancelled
        }
    }
}
