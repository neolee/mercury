import Foundation
import Testing
@testable import Mercury

@Suite("TaskQueue Queue-Only Termination")
struct TaskQueueQueueOnlyTerminationTests {
    @Test("Queue-only task timeout ends as timedOut")
    func queueOnlyTimeoutTerminalState() async throws {
        let queue = TaskQueue(maxConcurrentTasks: 1)
        let taskId = UUID()

        _ = await queue.enqueue(
            taskId: taskId,
            kind: .syncFeeds,
            title: "queue-only-timeout",
            executionTimeout: 1
        ) { _ in
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }

        let terminal = try await waitForTerminalRecord(queue: queue, taskId: taskId, timeoutSeconds: 6)
        if case .timedOut = terminal.state {
            #expect(true)
        } else {
            Issue.record("Expected timedOut terminal state for queue-only timeout.")
        }
    }

    @Test("Queue-only user cancel ends as cancelled")
    func queueOnlyCancelTerminalState() async throws {
        let queue = TaskQueue(maxConcurrentTasks: 1)
        let taskId = UUID()
        let startProbe = StartProbe()

        _ = await queue.enqueue(
            taskId: taskId,
            kind: .syncFeeds,
            title: "queue-only-cancel"
        ) { _ in
            await startProbe.markStarted()
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }

        try await waitUntilStarted(startProbe: startProbe, timeoutSeconds: 2)
        await queue.cancel(taskId: taskId)

        let terminal = try await waitForTerminalRecord(queue: queue, taskId: taskId, timeoutSeconds: 6)
        if case .cancelled = terminal.state {
            #expect(true)
        } else {
            Issue.record("Expected cancelled terminal state for queue-only user cancellation.")
        }
    }

    @Test("Queue-only operation failure ends as failed")
    func queueOnlyFailureTerminalState() async throws {
        let queue = TaskQueue(maxConcurrentTasks: 1)
        let taskId = UUID()

        _ = await queue.enqueue(
            taskId: taskId,
            kind: .syncFeeds,
            title: "queue-only-failure"
        ) { _ in
            throw NSError(domain: "TaskQueueQueueOnlyTerminationTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"])
        }

        let terminal = try await waitForTerminalRecord(queue: queue, taskId: taskId, timeoutSeconds: 3)
        if case .failed(let message) = terminal.state {
            #expect(message.contains("boom"))
        } else {
            Issue.record("Expected failed terminal state for queue-only operation failure.")
        }
    }

    private func waitUntilStarted(
        startProbe: StartProbe,
        timeoutSeconds: TimeInterval
    ) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if await startProbe.started {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw WaitTimeoutError()
    }

    private func waitForTerminalRecord(
        queue: TaskQueue,
        taskId: UUID,
        timeoutSeconds: TimeInterval
    ) async throws -> AppTaskRecord {
        let stream = await queue.events()

        return try await withThrowingTaskGroup(of: AppTaskRecord.self) { group in
            group.addTask {
                for await event in stream {
                    switch event {
                    case .bootstrap(let records):
                        if let record = records.first(where: { $0.id == taskId && $0.state.isTerminal }) {
                            return record
                        }
                    case .upsert(let record):
                        if record.id == taskId && record.state.isTerminal {
                            return record
                        }
                    }
                }
                throw WaitTimeoutError()
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw WaitTimeoutError()
            }

            guard let result = try await group.next() else {
                group.cancelAll()
                throw WaitTimeoutError()
            }
            group.cancelAll()
            return result
        }
    }
}

private actor StartProbe {
    private(set) var started: Bool = false

    func markStarted() {
        started = true
    }
}

private struct WaitTimeoutError: Error {}
