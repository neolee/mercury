import Foundation

typealias UnifiedTaskID = UUID

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
    static func from(appTaskKind: AppTaskKind) -> UnifiedTaskKind {
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

    static func from(agentTaskKind: AgentTaskKind) -> UnifiedTaskKind {
        switch agentTaskKind {
        case .summary:
            return .summary
        case .translation:
            return .translation
        case .tagging:
            return .tagging
        }
    }

    static func from(agentTaskType: AgentTaskType) -> UnifiedTaskKind {
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
