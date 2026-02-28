//
//  AppTaskContracts.swift
//  Mercury
//

import Foundation

enum AppTaskKind: String, Sendable {
    case bootstrap
    case syncAllFeeds
    case syncFeeds
    case importOPML
    case exportOPML
    case readerBuild
    case summary
    case translation
    case custom
}

nonisolated enum AppTaskTimeoutError: LocalizedError {
    case executionTimedOut(kind: AppTaskKind, seconds: Int)

    var errorDescription: String? {
        switch self {
        case .executionTimedOut(let kind, let seconds):
            return "\(kind.rawValue) task timed out after \(seconds) seconds."
        }
    }
}

nonisolated enum AppTaskTerminationReason: String, Sendable {
    case userCancelled = "user_cancelled"
    case timedOut = "timed_out"
}

enum AppTaskPriority: Int, Sendable {
    case userInitiated = 0
    case utility = 1
    case background = 2
}

nonisolated enum AppTaskState: Sendable {
    case queued
    case running
    case succeeded
    case failed(String)
    case timedOut(String)
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .timedOut, .cancelled:
            return true
        case .queued, .running:
            return false
        }
    }
}

typealias TaskProgressReporter = @Sendable (_ progress: Double?, _ message: String?) async -> Void
typealias AppTaskTerminationReasonProvider = @Sendable () async -> AppTaskTerminationReason?

nonisolated struct AppTaskExecutionContext: Sendable {
    let reportProgress: TaskProgressReporter
    let terminationReasonProvider: AppTaskTerminationReasonProvider

    func terminationReason() async -> AppTaskTerminationReason? {
        await terminationReasonProvider()
    }
}

nonisolated struct AppTaskRecord: Identifiable, Sendable {
    let id: UUID
    let kind: AppTaskKind
    let title: String
    let priority: AppTaskPriority
    let createdAt: Date
    var startedAt: Date?
    var finishedAt: Date?
    var progress: Double?
    var message: String?
    var state: AppTaskState
}

nonisolated enum TaskQueueEvent: Sendable {
    case bootstrap([AppTaskRecord])
    case upsert(AppTaskRecord)
}
