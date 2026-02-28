import Foundation

extension AppModel {
    private func recordAgentTerminalOutcome(
        database: DatabaseManager,
        startedAt: Date,
        entryId: Int64,
        taskType: AgentTaskType,
        targetLanguage: String,
        templateId: String,
        templateVersion: String,
        runtimeSnapshotBase: [String: String],
        outcome: TaskTerminalOutcome,
        timeoutKind: TaskTimeoutKind?,
        failedDebugTitle: String,
        cancelledDebugTitle: String?,
        cancelledDebugDetail: String?
    ) async {
        let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        let runtimeTrace = await runtimeTraceLinesForDebug(runtimeSnapshotBase: runtimeSnapshotBase, outcome: outcome)

        var runtimeSnapshot = runtimeSnapshotBase
        runtimeSnapshot["reason"] = outcome.runtimeReason
        if let failureReason = outcome.failureReason {
            runtimeSnapshot["failureReason"] = failureReason.rawValue
        }
        if let errorDescription = outcome.message {
            runtimeSnapshot["error"] = errorDescription
        }
        if case .timedOut = outcome {
            runtimeSnapshot["timeoutKind"] = (timeoutKind ?? .unknown).rawValue
        }
        if runtimeTrace.isEmpty == false {
            runtimeSnapshot["runtimeTraceCount"] = String(runtimeTrace.count)
            runtimeSnapshot["runtimeTraceLast"] = runtimeTrace.last
        }

        let context = AgentTerminalRunContext(
            providerProfileId: nil,
            modelProfileId: nil,
            templateId: templateId,
            templateVersion: templateVersion,
            runtimeSnapshot: runtimeSnapshot
        )
        if let runID = try? await recordAgentTerminalRun(
            database: database,
            entryId: entryId,
            taskType: taskType,
            status: outcome.agentTaskRunStatus,
            context: context,
            targetLanguage: targetLanguage,
            durationMs: durationMs
        ) {
            try? await linkRecentUsageEventsToTaskRun(
                database: database,
                taskRunId: runID,
                entryId: entryId,
                taskType: taskType,
                startedAt: startedAt,
                finishedAt: Date()
            )
        }

        await MainActor.run {
            if let debugIssue = outcome.agentDebugIssueProjection(
                entryId: entryId,
                failedDebugTitle: failedDebugTitle,
                cancelledDebugTitle: cancelledDebugTitle,
                cancelledDebugDetail: cancelledDebugDetail,
                timeoutKind: timeoutKind
            ) {
                var detail = debugIssue.detail
                if runtimeTrace.isEmpty == false {
                    detail += "\nruntimeTrace:\n\(runtimeTrace.joined(separator: "\n"))"
                }
                self.reportDebugIssue(
                    title: debugIssue.title,
                    detail: detail,
                    category: .task
                )
            }
        }
    }

    private func runtimeTraceLinesForDebug(
        runtimeSnapshotBase: [String: String],
        outcome: TaskTerminalOutcome
    ) async -> [String] {
        switch outcome {
        case .failed, .timedOut:
            break
        case .succeeded, .cancelled:
            return []
        }

        guard let rawTaskID = runtimeSnapshotBase["taskId"],
              let taskId = UUID(uuidString: rawTaskID) else {
            return []
        }
        return await agentRuntimeEngine.recentEventTraceLines(taskId: taskId, limit: 20)
    }

    func handleAgentFailure(
        database: DatabaseManager,
        startedAt: Date,
        entryId: Int64,
        taskType: AgentTaskType,
        taskKind: AgentTaskKind,
        targetLanguage: String,
        templateId: String,
        templateVersion: String,
        runtimeSnapshotBase: [String: String],
        failedDebugTitle: String,
        reportFailureMessage: String,
        report: TaskProgressReporter,
        error: Error,
        onTerminal: @escaping @Sendable (TaskTerminalOutcome) async -> Void
    ) async {
        let outcome = terminalOutcomeForFailure(error: error, taskKind: taskKind)
        let timeoutKind = timeoutKindForError(error)
        await recordAgentTerminalOutcome(
            database: database,
            startedAt: startedAt,
            entryId: entryId,
            taskType: taskType,
            targetLanguage: targetLanguage,
            templateId: templateId,
            templateVersion: templateVersion,
            runtimeSnapshotBase: runtimeSnapshotBase,
            outcome: outcome,
            timeoutKind: timeoutKind,
            failedDebugTitle: failedDebugTitle,
            cancelledDebugTitle: nil,
            cancelledDebugDetail: nil
        )

        await report(nil, reportFailureMessage)
        await onTerminal(outcome)
    }

    func handleAgentCancellation(
        database: DatabaseManager,
        startedAt: Date,
        entryId: Int64,
        taskType: AgentTaskType,
        taskKind: AgentTaskKind,
        targetLanguage: String,
        templateId: String,
        templateVersion: String,
        runtimeSnapshotBase: [String: String],
        failedDebugTitle: String,
        cancelledDebugTitle: String,
        cancelledDebugDetail: String,
        reportFailureMessage: String,
        report: TaskProgressReporter,
        terminationReason: AppTaskTerminationReason?,
        onTerminal: @escaping @Sendable (TaskTerminalOutcome) async -> Void
    ) async throws {
        let cancellationOutcome = resolveAgentCancellationOutcome(
            taskKind: taskKind,
            terminationReason: terminationReason
        )
        let outcome = terminalOutcomeForCancellation(
            taskKind: taskKind,
            terminationReason: terminationReason
        )
        let timeoutKind: TaskTimeoutKind?
        switch cancellationOutcome {
        case .timedOut:
            timeoutKind = .execution
        case .userCancelled:
            timeoutKind = nil
        }
        await recordAgentTerminalOutcome(
            database: database,
            startedAt: startedAt,
            entryId: entryId,
            taskType: taskType,
            targetLanguage: targetLanguage,
            templateId: templateId,
            templateVersion: templateVersion,
            runtimeSnapshotBase: runtimeSnapshotBase,
            outcome: outcome,
            timeoutKind: timeoutKind,
            failedDebugTitle: failedDebugTitle,
            cancelledDebugTitle: cancelledDebugTitle,
            cancelledDebugDetail: cancelledDebugDetail
        )
        await onTerminal(outcome)

        switch cancellationOutcome {
        case .timedOut(let timeoutError, _):
            await report(nil, reportFailureMessage)
            throw timeoutError

        case .userCancelled:
            throw CancellationError()
        }
    }
}
