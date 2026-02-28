//
//  TaskTimeoutPolicy.swift
//  Mercury
//

import Foundation

nonisolated struct NetworkTimeoutPolicy: Sendable, Equatable {
    let requestTimeout: TimeInterval
    let resourceTimeout: TimeInterval
    let streamFirstTokenTimeout: TimeInterval
    let streamIdleTimeout: TimeInterval

    init(
        requestTimeout: TimeInterval,
        resourceTimeout: TimeInterval,
        streamFirstTokenTimeout: TimeInterval,
        streamIdleTimeout: TimeInterval
    ) {
        self.requestTimeout = max(1, requestTimeout)
        self.resourceTimeout = max(1, resourceTimeout)
        self.streamFirstTokenTimeout = max(1, streamFirstTokenTimeout)
        self.streamIdleTimeout = max(1, streamIdleTimeout)
    }
}

nonisolated enum TaskTimeoutPolicy {
    static let executionTimeoutByTaskKind: [AppTaskKind: TimeInterval] = [
        .summary: 180,
        .translation: 300
    ]

    static let defaultNetwork = NetworkTimeoutPolicy(
        requestTimeout: 120,
        resourceTimeout: 600,
        streamFirstTokenTimeout: 120,
        streamIdleTimeout: 60
    )

    static func executionTimeout(for kind: AppTaskKind) -> TimeInterval? {
        executionTimeoutByTaskKind[kind]
    }

    static func executionTimeout(for kind: UnifiedTaskKind) -> TimeInterval? {
        executionTimeout(for: kind.appTaskKind)
    }

    static func executionTimeout(for kind: AgentTaskKind) -> TimeInterval? {
        executionTimeout(for: UnifiedTaskKind.from(agentTaskKind: kind))
    }

    static func networkTimeout(for _: AppTaskKind) -> NetworkTimeoutPolicy {
        defaultNetwork
    }

    static func networkTimeout(for kind: AgentTaskKind) -> NetworkTimeoutPolicy {
        networkTimeout(for: UnifiedTaskKind.from(agentTaskKind: kind).appTaskKind)
    }

    static let providerValidationTimeoutSeconds: TimeInterval = 120
}
