import Foundation
import Testing
@testable import Mercury

@Suite("Task Termination Semantics")
struct TaskTerminationSemanticsTests {
    @Test("Cancellation-like errors include provider cancelled and CancellationError")
    func cancellationLikeErrors() {
        #expect(isCancellationLikeError(CancellationError()))
        #expect(isCancellationLikeError(LLMProviderError.cancelled))
        #expect(isCancellationLikeError(LLMProviderError.network("boom")) == false)
    }

    @Test("Cancellation outcome maps timeout reason to timeout terminal")
    func cancellationOutcomeTimedOut() {
        let outcome = resolveAgentCancellationOutcome(
            taskKind: .summary,
            terminationReason: .timedOut
        )
        switch outcome {
        case .timedOut:
            #expect(true)
        case .userCancelled:
            Issue.record("Expected timeout outcome for timedOut termination reason.")
        }
    }

    @Test("Cancellation outcome maps user cancel reason to cancelled terminal")
    func cancellationOutcomeUserCancelled() {
        let outcome = resolveAgentCancellationOutcome(
            taskKind: .translation,
            terminationReason: .userCancelled
        )
        switch outcome {
        case .userCancelled:
            #expect(true)
        case .timedOut:
            Issue.record("Expected user-cancelled outcome for userCancelled termination reason.")
        }
    }

    @Test("Usage status maps timeout-like failure reason to timedOut")
    func usageStatusMapsTimeoutFailure() {
        let status = usageStatusForFailure(
            error: URLError(.timedOut),
            taskKind: .summary
        )
        #expect(status == .timedOut)
    }

    @Test("Usage status maps provider timeout message to timedOut")
    func usageStatusMapsProviderTimeoutFailure() {
        let status = usageStatusForFailure(
            error: LLMProviderError.network("Request timed out waiting for first token."),
            taskKind: .translation
        )
        #expect(status == .timedOut)
    }

    @Test("Usage status maps provider unknown timeout message to timedOut")
    func usageStatusMapsProviderUnknownTimeoutFailure() {
        let status = usageStatusForFailure(
            error: LLMProviderError.unknown("The request timed out."),
            taskKind: .translation
        )
        #expect(status == .timedOut)
    }

    @Test("Usage status maps provider typed timeout to timedOut")
    func usageStatusMapsProviderTypedTimeoutFailure() {
        let status = usageStatusForFailure(
            error: LLMProviderError.timedOut(kind: .request, message: "Request timed out."),
            taskKind: .translation
        )
        #expect(status == .timedOut)
    }

    @Test("Failure terminal outcome maps timeout-like errors to timedOut")
    func failureTerminalOutcomeTimedOut() {
        let outcome = terminalOutcomeForFailure(
            error: LLMProviderError.network("Stream idle timed out."),
            taskKind: .summary
        )

        switch outcome {
        case .timedOut(let failureReason, _):
            #expect(failureReason == .timedOut)
        default:
            Issue.record("Expected timedOut terminal outcome for timeout-like provider failure.")
        }
    }

    @Test("Agent debug projection skips no-model-route failures")
    func debugProjectionSkipsNoModelRoute() {
        let outcome = TaskTerminalOutcome.failed(
            failureReason: .noModelRoute,
            message: "no route"
        )
        let projection = outcome.agentDebugIssueProjection(
            entryId: 42,
            failedDebugTitle: "Summary Failed",
            cancelledDebugTitle: "Summary Cancelled",
            cancelledDebugDetail: nil
        )
        #expect(projection == nil)
    }

    @Test("Agent debug projection keeps timedOut diagnostics")
    func debugProjectionForTimedOut() {
        let outcome = TaskTerminalOutcome.timedOut(
            failureReason: .timedOut,
            message: "timeout"
        )
        let projection = outcome.agentDebugIssueProjection(
            entryId: 7,
            failedDebugTitle: "Translation Failed",
            cancelledDebugTitle: "Translation Cancelled",
            cancelledDebugDetail: nil
        )
        #expect(projection?.title == "Translation Failed")
        #expect(projection?.detail.contains("failureReason=timed_out") == true)
    }

    @Test("Terminal outcome projections stay consistent across layers")
    func terminalProjectionConsistency() {
        let matrix: [(TaskTerminalOutcome, AgentTaskRunStatus, AgentRunPhase, LLMUsageRequestStatus)] = [
            (.succeeded, .succeeded, .completed, .succeeded),
            (.failed(failureReason: .unknown, message: "x"), .failed, .failed, .failed),
            (.timedOut(failureReason: .timedOut, message: "x"), .timedOut, .timedOut, .timedOut),
            (.cancelled(failureReason: .cancelled), .cancelled, .cancelled, .cancelled)
        ]

        for (outcome, expectedRunStatus, expectedPhase, expectedUsageStatus) in matrix {
            #expect(outcome.agentTaskRunStatus == expectedRunStatus)
            #expect(outcome.agentRunPhase == expectedPhase)
            #expect(outcome.usageStatus == expectedUsageStatus)
        }

        if case .succeeded = TaskTerminalOutcome.succeeded.appTaskState() {
            #expect(true)
        } else {
            Issue.record("Expected succeeded app task state projection.")
        }
        if case .timedOut = TaskTerminalOutcome
            .timedOut(failureReason: .timedOut, message: "x")
            .appTaskState() {
            #expect(true)
        } else {
            Issue.record("Expected timedOut app task state projection.")
        }
    }

    @Test("Queue execution timeout exposes timedOut reason to operation context")
    func queueTimeoutReasonPropagation() async throws {
        let queue = TaskQueue(maxConcurrentTasks: 1)
        let probe = TerminationProbe()
        let taskId = UUID()

        _ = await queue.enqueue(
            taskId: taskId,
            kind: .summary,
            title: "timeout-probe",
            executionTimeout: 1
        ) { context in
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            } catch {
                if isCancellationLikeError(error) {
                    await probe.setReason(await context.terminationReason())
                    throw CancellationError()
                }
                throw error
            }
        }

        let terminal = try await waitForTerminalRecord(queue: queue, taskId: taskId, timeoutSeconds: 6)
        #expect(await probe.reason == .timedOut)
        #expect(isTimedOutState(terminal.state))
    }

    @Test("Queue user cancellation exposes userCancelled reason to operation context")
    func queueUserCancelReasonPropagation() async throws {
        let queue = TaskQueue(maxConcurrentTasks: 1)
        let probe = TerminationProbe()
        let startProbe = StartProbe()
        let taskId = UUID()

        _ = await queue.enqueue(
            taskId: taskId,
            kind: .summary,
            title: "cancel-probe",
            executionTimeout: 10
        ) { context in
            await startProbe.markStarted()
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            } catch {
                if isCancellationLikeError(error) {
                    await probe.setReason(await context.terminationReason())
                    throw CancellationError()
                }
                throw error
            }
        }

        try await waitUntilStarted(startProbe: startProbe, timeoutSeconds: 2)
        await queue.cancel(taskId: taskId)

        let terminal = try await waitForTerminalRecord(queue: queue, taskId: taskId, timeoutSeconds: 6)
        #expect(await probe.reason == .userCancelled)
        #expect(isCancelledState(terminal.state))
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

    private func isTimedOutState(_ state: AppTaskState) -> Bool {
        if case .timedOut = state {
            return true
        }
        return false
    }

    private func isCancelledState(_ state: AppTaskState) -> Bool {
        if case .cancelled = state {
            return true
        }
        return false
    }
}

private actor TerminationProbe {
    private(set) var reason: AppTaskTerminationReason?

    func setReason(_ reason: AppTaskTerminationReason?) {
        self.reason = reason
    }
}

private actor StartProbe {
    private(set) var started: Bool = false

    func markStarted() {
        started = true
    }
}

private struct WaitTimeoutError: Error {}
