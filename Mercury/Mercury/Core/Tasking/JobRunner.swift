//
//  JobRunner.swift
//  Mercury
//
//  Created by Neo on 2026/2/4.
//

import Foundation

nonisolated struct JobEvent: Identifiable, Sendable {
    let id = UUID()
    let label: String
    let message: String
    let timestamp: Date
}

nonisolated enum JobError: Error {
    case timeout(String)
    case missingResult(String)
}

nonisolated final class JobResultBox<Result>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result?

    func store(_ value: Result) {
        lock.lock()
        defer { lock.unlock() }
        self.value = value
    }

    func take() -> Result? {
        lock.lock()
        defer { lock.unlock() }
        let result = value
        value = nil
        return result
    }
}

nonisolated final class JobRunner {
    func run<Result>(
        label: String,
        timeout: TimeInterval? = nil,
        onEvent: (@Sendable (JobEvent) -> Void)? = nil,
        operation: @escaping @Sendable (_ report: @Sendable (String) -> Void) async throws -> Result
    ) async throws -> Result {
        let (stream, continuation) = AsyncStream<JobEvent>.makeStream()
        let report: @Sendable (String) -> Void = { message in
            continuation.yield(JobEvent(label: label, message: message, timestamp: Date()))
        }
        let observerTask: Task<Void, Never>?
        if let onEvent {
            observerTask = Task {
                for await event in stream {
                    onEvent(event)
                }
            }
        } else {
            observerTask = nil
        }
        defer {
            observerTask?.cancel()
            continuation.finish()
        }

        report("start")
        do {
            let result: Result
            if let timeout {
                result = try await Self.runWithTimeout(
                    label: label,
                    timeout: timeout,
                    report: report,
                    operation: operation
                )
            } else {
                result = try await operation(report)
            }
            report("finish")
            return result
        } catch {
            report("error: \(error)")
            throw error
        }
    }

    private static func runWithTimeout<Result>(
        label: String,
        timeout: TimeInterval,
        report: @escaping @Sendable (String) -> Void,
        operation: @escaping @Sendable (_ report: @Sendable (String) -> Void) async throws -> Result
    ) async throws -> Result {
        let resultBox = JobResultBox<Result>()

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                let result = try await operation(report)
                resultBox.store(result)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw JobError.timeout(label)
            }

            try await group.next()
            group.cancelAll()
        }

        guard let result = resultBox.take() else {
            throw JobError.missingResult(label)
        }
        return result
    }
}
