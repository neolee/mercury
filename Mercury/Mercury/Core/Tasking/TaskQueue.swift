//
//  TaskQueue.swift
//  Mercury
//
//  Created by Codex on 2026/2/11.
//

import Foundation

actor TaskQueue {
    private struct QueuedTask {
        let id: UUID
        let kind: AppTaskKind
        let title: String
        let priority: AppTaskPriority
        let executionTimeout: TimeInterval?
        let createdAt: Date
        let operation: (AppTaskExecutionContext) async throws -> Void
    }

    private struct RunningTask {
        let kind: AppTaskKind
        let task: Task<Void, Never>
    }

    private let maxConcurrentTasks: Int
    private let perKindConcurrencyLimits: [AppTaskKind: Int]
    private var pending: [QueuedTask] = []
    private var running: [UUID: RunningTask] = [:]
    private var terminationReasons: [UUID: AppTaskTerminationReason] = [:]
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
        taskId: UUID,
        kind: AppTaskKind,
        title: String,
        priority: AppTaskPriority = .utility,
        executionTimeout: TimeInterval? = nil,
        operation: @escaping (AppTaskExecutionContext) async throws -> Void
    ) -> UUID {
        let id = taskId
        let createdAt = Date()
        let resolvedExecutionTimeout = executionTimeout ?? TaskTimeoutPolicy.executionTimeout(for: kind)

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
                executionTimeout: resolvedExecutionTimeout,
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
        terminationReasons[taskId] = .userCancelled
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
            let terminationReasonProvider: AppTaskTerminationReasonProvider = {
                await self.terminationReason(for: queuedTask.id)
            }
            let reportProgress: TaskProgressReporter = { progress, message in
                await self.updateProgress(
                    taskId: queuedTask.id,
                    progress: progress,
                    message: message
                )
            }
            let executionContext = AppTaskExecutionContext(
                reportProgress: reportProgress,
                terminationReasonProvider: terminationReasonProvider
            )

            do {
                try Task.checkCancellation()
                let runOperation: @Sendable () async throws -> Void = {
                    try await operation(executionContext)
                }

                if let executionTimeout = queuedTask.executionTimeout {
                    try await self.withExecutionTimeout(
                        seconds: executionTimeout,
                        kind: queuedTask.kind,
                        taskId: queuedTask.id,
                        operation: runOperation
                    )
                } else {
                    try await runOperation()
                }

                self.finish(
                    taskId: queuedTask.id,
                    state: TaskTerminalOutcome.succeeded.appTaskState()
                )
            } catch is CancellationError {
                let reason = self.terminationReason(for: queuedTask.id)
                if reason == .timedOut {
                    let timeoutSeconds = Int(max(1, queuedTask.executionTimeout ?? 1))
                    let timeoutMessage = AppTaskTimeoutError.executionTimedOut(
                        kind: queuedTask.kind,
                        seconds: timeoutSeconds
                    ).localizedDescription
                    self.finish(
                        taskId: queuedTask.id,
                        state: TaskTerminalOutcome
                            .timedOut(failureReason: nil, message: timeoutMessage)
                            .appTaskState()
                    )
                } else {
                    self.finish(
                        taskId: queuedTask.id,
                        state: TaskTerminalOutcome.cancelled(failureReason: nil).appTaskState()
                    )
                }
            } catch let timeoutError as AppTaskTimeoutError {
                self.finish(
                    taskId: queuedTask.id,
                    state: TaskTerminalOutcome
                        .timedOut(failureReason: nil, message: timeoutError.localizedDescription)
                        .appTaskState()
                )
            } catch {
                self.finish(
                    taskId: queuedTask.id,
                    state: TaskTerminalOutcome
                        .failed(failureReason: nil, message: error.localizedDescription)
                        .appTaskState()
                )
            }
        }

        running[queuedTask.id] = RunningTask(
            kind: queuedTask.kind,
            task: work
        )
    }

    private func withExecutionTimeout(
        seconds: TimeInterval,
        kind: AppTaskKind,
        taskId: UUID,
        operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        let clampedSeconds = max(1, seconds)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(clampedSeconds))
                await self.setTerminationReason(taskId: taskId, reason: .timedOut)
                throw AppTaskTimeoutError.executionTimedOut(
                    kind: kind,
                    seconds: Int(clampedSeconds)
                )
            }
            _ = try await group.next()
            group.cancelAll()
        }
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
        terminationReasons[taskId] = nil
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

    private func setTerminationReason(taskId: UUID, reason: AppTaskTerminationReason) {
        terminationReasons[taskId] = reason
    }

    private func terminationReason(for taskId: UUID) -> AppTaskTerminationReason? {
        terminationReasons[taskId]
    }
}
