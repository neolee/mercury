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
    case readerBuild
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

struct AppTaskRecord: Identifiable, Sendable {
    let id: UUID
    let kind: AppTaskKind
    let title: String
    let priority: AppTaskPriority
    let createdAt: Date
    var startedAt: Date?
    var finishedAt: Date?
    var state: AppTaskState
}

enum TaskQueueEvent: Sendable {
    case bootstrap([AppTaskRecord])
    case upsert(AppTaskRecord)
}

actor TaskQueue {
    private struct QueuedTask {
        let id: UUID
        let kind: AppTaskKind
        let title: String
        let priority: AppTaskPriority
        let createdAt: Date
        let operation: @Sendable () async throws -> Void
    }

    private struct RunningTask {
        let task: Task<Void, Never>
    }

    private let maxConcurrentTasks: Int
    private var pending: [QueuedTask] = []
    private var running: [UUID: RunningTask] = [:]
    private var records: [UUID: AppTaskRecord] = [:]
    private var observers: [UUID: AsyncStream<TaskQueueEvent>.Continuation] = [:]

    init(maxConcurrentTasks: Int = 2) {
        self.maxConcurrentTasks = max(1, maxConcurrentTasks)
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
        operation: @escaping @Sendable () async throws -> Void
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
        }

        let work = Task.detached { [operation = queuedTask.operation] in
            do {
                try Task.checkCancellation()
                try await operation()
                await self.finish(taskId: queuedTask.id, state: .succeeded)
            } catch is CancellationError {
                await self.finish(taskId: queuedTask.id, state: .cancelled)
            } catch {
                await self.finish(taskId: queuedTask.id, state: .failed(error.localizedDescription))
            }
        }

        running[queuedTask.id] = RunningTask(task: work)
    }

    private func finish(taskId: UUID, state: AppTaskState) {
        running[taskId] = nil
        updateRecord(taskId: taskId) { current in
            current.state = state
            current.finishedAt = Date()
        }
        scheduleIfNeeded()
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
        operation: @escaping @Sendable () async throws -> Void
    ) async -> UUID {
        await queue.enqueue(kind: kind, title: title, priority: priority, operation: operation)
    }

    func cancel(taskId: UUID) async {
        await queue.cancel(taskId: taskId)
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
        }
    }

    private func taskSort(lhs: AppTaskRecord, rhs: AppTaskRecord) -> Bool {
        if lhs.state.isTerminal != rhs.state.isTerminal {
            return lhs.state.isTerminal == false
        }
        return lhs.createdAt > rhs.createdAt
    }
}
