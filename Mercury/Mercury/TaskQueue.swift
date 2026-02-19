//
//  TaskQueue.swift
//  Mercury
//
//  Created by Codex on 2026/2/11.
//

import Combine
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

enum AppTaskPriority: Int, Sendable {
    case userInitiated = 0
    case utility = 1
    case background = 2
}

enum AppTaskState: Sendable {
    case queued
    case running
    case succeeded
    case failed(String)
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled:
            return true
        case .queued, .running:
            return false
        }
    }
}

typealias TaskProgressReporter = (_ progress: Double?, _ message: String?) async -> Void

struct AppTaskRecord: Identifiable, Sendable {
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

enum TaskQueueEvent: Sendable {
    case bootstrap([AppTaskRecord])
    case upsert(AppTaskRecord)
}

struct AppUserError: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let createdAt: Date
}

enum DebugIssueCategory: String, CaseIterable {
    case all
    case task
    case reader
    case general

    var label: String {
        switch self {
        case .all: return "All"
        case .task: return "Task"
        case .reader: return "Reader"
        case .general: return "General"
        }
    }
}

struct DebugIssue: Identifiable {
    let id = UUID()
    let category: DebugIssueCategory
    let title: String
    let detail: String
    let createdAt: Date
}

actor TaskQueue {
    private struct QueuedTask {
        let id: UUID
        let kind: AppTaskKind
        let title: String
        let priority: AppTaskPriority
        let createdAt: Date
        let operation: (TaskProgressReporter) async throws -> Void
    }

    private struct RunningTask {
        let kind: AppTaskKind
        let task: Task<Void, Never>
    }

    private let maxConcurrentTasks: Int
    private let perKindConcurrencyLimits: [AppTaskKind: Int]
    private var pending: [QueuedTask] = []
    private var running: [UUID: RunningTask] = [:]
    private var records: [UUID: AppTaskRecord] = [:]
    private var observers: [UUID: AsyncStream<TaskQueueEvent>.Continuation] = [:]

    init(
        maxConcurrentTasks: Int = 2,
        perKindConcurrencyLimits: [AppTaskKind: Int] = [:]
    ) {
        self.maxConcurrentTasks = max(1, maxConcurrentTasks)
        self.perKindConcurrencyLimits = Dictionary(
            uniqueKeysWithValues: perKindConcurrencyLimits.map { key, value in
                (key, max(1, value))
            }
        )
    }

    func events() -> AsyncStream<TaskQueueEvent> {
        let observerId = UUID()
        return AsyncStream { continuation in
            observers[observerId] = continuation
            let snapshot = records.values.sorted { lhs, rhs in
                lhs.createdAt > rhs.createdAt
            }
            continuation.yield(.bootstrap(snapshot))
            continuation.onTermination = { [observerId] _ in
                Task {
                    await self.removeObserver(observerId)
                }
            }
        }
    }

    @discardableResult
    func enqueue(
        kind: AppTaskKind,
        title: String,
        priority: AppTaskPriority = .utility,
        operation: @escaping (TaskProgressReporter) async throws -> Void
    ) -> UUID {
        let id = UUID()
        let createdAt = Date()

        let record = AppTaskRecord(
            id: id,
            kind: kind,
            title: title,
            priority: priority,
            createdAt: createdAt,
            startedAt: nil,
            finishedAt: nil,
            progress: nil,
            message: nil,
            state: .queued
        )
        records[id] = record
        pending.append(
            QueuedTask(
                id: id,
                kind: kind,
                title: title,
                priority: priority,
                createdAt: createdAt,
                operation: operation
            )
        )

        emit(.upsert(record))
        scheduleIfNeeded()
        return id
    }

    func cancel(taskId: UUID) {
        if let index = pending.firstIndex(where: { $0.id == taskId }) {
            pending.remove(at: index)
            updateRecord(taskId: taskId) { current in
                current.state = .cancelled
                current.finishedAt = Date()
            }
            return
        }

        guard let runningTask = running[taskId] else { return }
        runningTask.task.cancel()
    }

    private func scheduleIfNeeded() {
        guard running.count < maxConcurrentTasks else { return }

        while running.count < maxConcurrentTasks {
            guard let next = popNextPendingTask() else { break }
            start(next)
        }
    }

    private func popNextPendingTask() -> QueuedTask? {
        guard pending.isEmpty == false else { return nil }
        let nextIndex = pending
            .enumerated()
            .filter { canStartTaskKind($0.element.kind) }
            .min { lhs, rhs in
                if lhs.element.priority.rawValue != rhs.element.priority.rawValue {
                    return lhs.element.priority.rawValue < rhs.element.priority.rawValue
                }
                return lhs.element.createdAt < rhs.element.createdAt
            }?
            .offset

        guard let nextIndex else { return nil }
        return pending.remove(at: nextIndex)
    }

    private func start(_ queuedTask: QueuedTask) {
        updateRecord(taskId: queuedTask.id) { current in
            current.state = .running
            current.startedAt = Date()
            current.progress = 0
        }

        let work = Task { [operation = queuedTask.operation] in
            do {
                try Task.checkCancellation()
                try await operation { progress, message in
                    self.updateProgress(
                        taskId: queuedTask.id,
                        progress: progress,
                        message: message
                    )
                }
                self.finish(taskId: queuedTask.id, state: .succeeded)
            } catch is CancellationError {
                self.finish(taskId: queuedTask.id, state: .cancelled)
            } catch {
                self.finish(taskId: queuedTask.id, state: .failed(error.localizedDescription))
            }
        }

        running[queuedTask.id] = RunningTask(
            kind: queuedTask.kind,
            task: work
        )
    }

    private func canStartTaskKind(_ kind: AppTaskKind) -> Bool {
        let limit = perKindConcurrencyLimits[kind] ?? maxConcurrentTasks
        let runningCountForKind = running.values.reduce(into: 0) { result, runningTask in
            if runningTask.kind == kind {
                result += 1
            }
        }
        return runningCountForKind < limit
    }

    private func finish(taskId: UUID, state: AppTaskState) {
        running[taskId] = nil
        updateRecord(taskId: taskId) { current in
            current.state = state
            current.finishedAt = Date()
            if case .succeeded = state {
                current.progress = 1
            }
        }
        scheduleIfNeeded()
    }

    private func updateProgress(taskId: UUID, progress: Double?, message: String?) {
        updateRecord(taskId: taskId) { current in
            if let progress {
                current.progress = min(max(progress, 0), 1)
            }
            if let message {
                current.message = message
            }
        }
    }

    private func updateRecord(taskId: UUID, mutate: (inout AppTaskRecord) -> Void) {
        guard var current = records[taskId] else { return }
        mutate(&current)
        records[taskId] = current
        emit(.upsert(current))
    }

    private func emit(_ event: TaskQueueEvent) {
        for continuation in observers.values {
            continuation.yield(event)
        }
    }

    private func removeObserver(_ observerId: UUID) {
        observers[observerId] = nil
    }
}

@MainActor
final class TaskCenter: ObservableObject {
    @Published private(set) var tasks: [AppTaskRecord] = []
    @Published var latestUserError: AppUserError?
    @Published private(set) var debugIssues: [DebugIssue] = []

    private let queue: TaskQueue
    private var streamTask: Task<Void, Never>?

    init(queue: TaskQueue) {
        self.queue = queue
        observeQueueEvents()
    }

    deinit {
        streamTask?.cancel()
    }

    @discardableResult
    func enqueue(
        kind: AppTaskKind,
        title: String,
        priority: AppTaskPriority = .utility,
        operation: @escaping (TaskProgressReporter) async throws -> Void
    ) async -> UUID {
        await queue.enqueue(kind: kind, title: title, priority: priority, operation: operation)
    }

    func cancel(taskId: UUID) async {
        await queue.cancel(taskId: taskId)
    }

    func reportUserError(title: String, message: String) {
        latestUserError = AppUserError(title: title, message: message, createdAt: Date())
    }

    func dismissUserError() {
        latestUserError = nil
    }

    func reportDebugIssue(title: String, detail: String, category: DebugIssueCategory = .general) {
        let issue = DebugIssue(category: category, title: title, detail: detail, createdAt: Date())
        debugIssues.insert(issue, at: 0)
    }

    func clearDebugIssues() {
        debugIssues.removeAll()
    }

    private func observeQueueEvents() {
        streamTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let stream = await queue.events()
            for await event in stream {
                if Task.isCancelled { return }
                self.apply(event)
            }
        }
    }

    private func apply(_ event: TaskQueueEvent) {
        switch event {
        case .bootstrap(let records):
            tasks = records.sorted(by: taskSort)
        case .upsert(let record):
            if let index = tasks.firstIndex(where: { $0.id == record.id }) {
                tasks[index] = record
            } else {
                tasks.append(record)
            }
            tasks.sort(by: taskSort)
            if case .failed(let message) = record.state {
                if FailurePolicy.shouldSurfaceFailureToUser(kind: record.kind, message: message) {
                    latestUserError = AppUserError(
                        title: record.title,
                        message: message,
                        createdAt: Date()
                    )
                }
                let detail = [
                    "Task: \(record.title)",
                    "Kind: \(record.kind.rawValue)",
                    "State: failed",
                    "Message: \(message)"
                ].joined(separator: "\n")
                debugIssues.insert(
                    DebugIssue(category: .task, title: "Task Failure", detail: detail, createdAt: Date()),
                    at: 0
                )
            }
        }
    }

    private func taskSort(lhs: AppTaskRecord, rhs: AppTaskRecord) -> Bool {
        if lhs.state.isTerminal != rhs.state.isTerminal {
            return lhs.state.isTerminal == false
        }
        return lhs.createdAt > rhs.createdAt
    }
}
