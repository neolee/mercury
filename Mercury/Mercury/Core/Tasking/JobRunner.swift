//
//  JobRunner.swift
//  Mercury
//
//  Created by Neo on 2026/2/4.
//

import Foundation

struct JobEvent: Identifiable {
    let id = UUID()
    let label: String
    let message: String
    let timestamp: Date
}

final class JobHandle<Result> {
    let id: UUID
    let events: AsyncStream<JobEvent>
    let task: Task<Result, Error>

    init(id: UUID, events: AsyncStream<JobEvent>, task: Task<Result, Error>) {
        self.id = id
        self.events = events
        self.task = task
    }

    func cancel() {
        task.cancel()
    }
}

enum JobError: Error {
    case timeout(String)
}

actor JobRunner {
    func start<Result>(
        label: String,
        timeout: TimeInterval? = nil,
        operation: @escaping @Sendable (_ report: @Sendable (String) -> Void) async throws -> Result
    ) async -> JobHandle<Result> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<JobEvent>.makeStream()
        let report: @Sendable (String) -> Void = { message in
            continuation.yield(JobEvent(label: label, message: message, timestamp: Date()))
        }

        let task = Task<Result, Error> {
            report("start")
            do {
                let result: Result
                if let timeout {
                    result = try await withThrowingTaskGroup(of: Result.self) { group in
                        group.addTask {
                            try await operation(report)
                        }
                        group.addTask {
                            try await Task.sleep(for: .seconds(timeout))
                            throw JobError.timeout(label)
                        }
                        let result = try await group.next()!
                        group.cancelAll()
                        return result
                    }
                } else {
                    result = try await operation(report)
                }
                report("finish")
                continuation.finish()
                return result
            } catch {
                report("error: \(error)")
                continuation.finish()
                throw error
            }
        }

        let handle = await MainActor.run {
            JobHandle(id: id, events: stream, task: task)
        }
        return handle
    }

    func run<Result>(
        label: String,
        timeout: TimeInterval? = nil,
        onEvent: ((JobEvent) -> Void)? = nil,
        operation: @escaping @Sendable (_ report: @Sendable (String) -> Void) async throws -> Result
    ) async throws -> Result {
        let handle = await start(label: label, timeout: timeout, operation: operation)
        if let onEvent {
            Task {
                for await event in handle.events {
                    onEvent(event)
                }
            }
        }
        return try await handle.task.value
    }
}
