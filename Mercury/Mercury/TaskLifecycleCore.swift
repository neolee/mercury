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

nonisolated enum UnifiedTaskExecutionRoute: Equatable, Sendable {
    case queueOnly(appTaskKind: AppTaskKind)
    case queueAndRuntime(appTaskKind: AppTaskKind, agentTaskKind: AgentTaskKind)
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

    nonisolated var family: UnifiedTaskFamily {
        switch self {
        case .summary, .translation, .tagging:
            return .agent
        case .bootstrap, .syncAllFeeds, .syncFeeds, .importOPML, .exportOPML, .readerBuild, .custom:
            return .queueOnly
        }
    }

    nonisolated var appTaskKind: AppTaskKind {
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

    nonisolated var agentTaskKind: AgentTaskKind? {
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

    nonisolated var agentTaskType: AgentTaskType? {
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
    nonisolated var executionRoute: UnifiedTaskExecutionRoute {
        if let agentTaskKind {
            return .queueAndRuntime(
                appTaskKind: appTaskKind,
                agentTaskKind: agentTaskKind
            )
        }
        return .queueOnly(appTaskKind: appTaskKind)
    }

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

nonisolated enum UnifiedTaskExecutionRouter {
    nonisolated static func route(for kind: UnifiedTaskKind) -> UnifiedTaskExecutionRoute {
        kind.executionRoute
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

    func agentDebugIssueProjection(
        entryId: Int64,
        failedDebugTitle: String,
        cancelledDebugTitle: String?,
        cancelledDebugDetail: String?
    ) -> AgentDebugIssueProjection? {
        switch self {
        case .succeeded:
            return nil
        case .failed(let failureReason, let message):
            let normalizedFailureReason = failureReason ?? .unknown
            // noModelRoute and invalidConfiguration are user-configurable states, not
            // diagnostic anomalies. Reader banner already surfaces these states.
            if normalizedFailureReason == .noModelRoute || normalizedFailureReason == .invalidConfiguration {
                return nil
            }
            return AgentDebugIssueProjection(
                title: failedDebugTitle,
                detail: "entryId=\(entryId)\nfailureReason=\(normalizedFailureReason.rawValue)\nerror=\(message ?? "")"
            )
        case .timedOut(let failureReason, let message):
            let normalizedFailureReason = failureReason ?? .timedOut
            return AgentDebugIssueProjection(
                title: failedDebugTitle,
                detail: "entryId=\(entryId)\nfailureReason=\(normalizedFailureReason.rawValue)\nerror=\(message ?? "")"
            )
        case .cancelled(let failureReason):
            let normalizedFailureReason = failureReason ?? .cancelled
            let detailPrefix = cancelledDebugDetail ?? "entryId=\(entryId)"
            return AgentDebugIssueProjection(
                title: cancelledDebugTitle ?? failedDebugTitle,
                detail: "\(detailPrefix)\nfailureReason=\(normalizedFailureReason.rawValue)"
            )
        }
    }
}

nonisolated struct AgentDebugIssueProjection: Sendable, Equatable {
    let title: String
    let detail: String
}
