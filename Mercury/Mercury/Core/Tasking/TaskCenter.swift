//
//  TaskCenter.swift
//  Mercury
//

import Combine
import Foundation

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
        taskId: UUID,
        kind: AppTaskKind,
        title: String,
        priority: AppTaskPriority = .utility,
        executionTimeout: TimeInterval? = nil,
        operation: @escaping (AppTaskExecutionContext) async throws -> Void
    ) async -> UUID {
        await queue.enqueue(
            taskId: taskId,
            kind: kind,
            title: title,
            priority: priority,
            executionTimeout: executionTimeout,
            operation: operation
        )
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
                if UnifiedTaskKind.from(appTaskKind: record.kind).family == .queueOnly {
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
            } else if case .timedOut(let message) = record.state {
                if FailurePolicy.shouldSurfaceFailureToUser(kind: record.kind, message: message) {
                    latestUserError = AppUserError(
                        title: record.title,
                        message: message,
                        createdAt: Date()
                    )
                }
                if UnifiedTaskKind.from(appTaskKind: record.kind).family == .queueOnly {
                    let detail = [
                        "Task: \(record.title)",
                        "Kind: \(record.kind.rawValue)",
                        "State: timed_out",
                        "Message: \(message)"
                    ].joined(separator: "\n")
                    debugIssues.insert(
                        DebugIssue(category: .task, title: "Task Timeout", detail: detail, createdAt: Date()),
                        at: 0
                    )
                }
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
