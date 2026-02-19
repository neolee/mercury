import Foundation
import Testing
@testable import Mercury

@Suite("TaskQueue Concurrency Policy")
struct TaskQueueConcurrencyPolicyTests {
    @Test("Summary tasks respect per-kind limit=1")
    func summaryTasksAreSerializedByKindLimit() async throws {
        let queue = TaskQueue(
            maxConcurrentTasks: 5,
            perKindConcurrencyLimits: [.summary: 1]
        )
        let probe = ConcurrencyProbe()

        let ids = await [
            queue.enqueue(kind: .summary, title: "S1") { _ in
                try await runProbedOperation(probe: probe, durationNanos: 180_000_000)
            },
            queue.enqueue(kind: .summary, title: "S2") { _ in
                try await runProbedOperation(probe: probe, durationNanos: 180_000_000)
            },
            queue.enqueue(kind: .summary, title: "S3") { _ in
                try await runProbedOperation(probe: probe, durationNanos: 180_000_000)
            }
        ]

        try await waitUntilTasksTerminal(queue: queue, ids: ids, timeoutSeconds: 8)
        #expect(await probe.peak == 1)
    }

    @Test("Global max concurrent tasks limits overall parallelism")
    func globalMaxConcurrentIsEnforced() async throws {
        let queue = TaskQueue(maxConcurrentTasks: 2)
        let probe = ConcurrencyProbe()

        let ids = await [
            queue.enqueue(kind: .custom, title: "C1") { _ in
                try await runProbedOperation(probe: probe, durationNanos: 220_000_000)
            },
            queue.enqueue(kind: .custom, title: "C2") { _ in
                try await runProbedOperation(probe: probe, durationNanos: 220_000_000)
            },
            queue.enqueue(kind: .custom, title: "C3") { _ in
                try await runProbedOperation(probe: probe, durationNanos: 220_000_000)
            }
        ]

        try await waitUntilTasksTerminal(queue: queue, ids: ids, timeoutSeconds: 8)
        #expect(await probe.peak == 2)
    }

    private func waitUntilTasksTerminal(
        queue: TaskQueue,
        ids: [UUID],
        timeoutSeconds: TimeInterval
    ) async throws {
        let targetSet = Set(ids)
        let stream = await queue.events()

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var terminalSet: Set<UUID> = []
                for await event in stream {
                    switch event {
                    case .bootstrap(let records):
                        for record in records where targetSet.contains(record.id) {
                            if record.state.isTerminal {
                                terminalSet.insert(record.id)
                            }
                        }
                    case .upsert(let record):
                        guard targetSet.contains(record.id) else { continue }
                        if record.state.isTerminal {
                            terminalSet.insert(record.id)
                        }
                    }

                    if terminalSet == targetSet {
                        return
                    }
                }
                throw WaitTimeoutError()
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw WaitTimeoutError()
            }

            _ = try await group.next()
            group.cancelAll()
        }
    }

    private func runProbedOperation(
        probe: ConcurrencyProbe,
        durationNanos: UInt64
    ) async throws {
        await probe.start()
        do {
            try await Task.sleep(nanoseconds: durationNanos)
            await probe.end()
        } catch {
            await probe.end()
            throw error
        }
    }
}

private actor ConcurrencyProbe {
    private var current: Int = 0
    private(set) var peak: Int = 0

    func start() {
        current += 1
        if current > peak {
            peak = current
        }
    }

    func end() {
        current = max(0, current - 1)
    }
}

private struct WaitTimeoutError: Error {}
