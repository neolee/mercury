import Foundation
import GRDB

struct AgentRouteCandidate: Sendable {
    let provider: AgentProviderProfile
    let model: AgentModelProfile
    let apiKey: String
}

struct AgentTerminalRunContext: Sendable {
    let providerProfileId: Int64?
    let modelProfileId: Int64?
    let templateId: String?
    let templateVersion: String?
    let runtimeSnapshot: [String: String]
}

enum AgentExecutionSharedError: LocalizedError {
    case missingTaskRunID

    var errorDescription: String? {
        switch self {
        case .missingTaskRunID:
            return "Task run ID is missing after insert."
        }
    }
}

struct LLMUsageEventContext: Sendable {
    let taskRunId: Int64?
    let entryId: Int64?
    let taskType: AgentTaskType
    let providerProfileId: Int64?
    let modelProfileId: Int64?
    let providerBaseURLSnapshot: String
    let providerResolvedURLSnapshot: String?
    let providerResolvedHostSnapshot: String?
    let providerResolvedPathSnapshot: String?
    let providerNameSnapshot: String?
    let modelNameSnapshot: String
    let requestPhase: LLMUsageRequestPhase
    let requestStatus: LLMUsageRequestStatus
    let promptTokens: Int?
    let completionTokens: Int?
    let startedAt: Date?
    let finishedAt: Date?
}

enum AgentExecutionShared {
    static func languageDisplayName(for identifier: String) -> String {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return "English (en)"
        }
        if let localized = Locale.current.localizedString(forIdentifier: trimmed) {
            return "\(localized) (\(trimmed))"
        }
        return trimmed
    }

    static func encodeRuntimeSnapshot(_ snapshot: [String: String]) throws -> String? {
        guard snapshot.isEmpty == false else {
            return nil
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        return String(data: data, encoding: .utf8)
    }
}

nonisolated enum AgentCancellationOutcome: Sendable {
    case timedOut(error: AppTaskTimeoutError, failureReason: AgentFailureReason)
    case userCancelled(failureReason: AgentFailureReason)
}

private func timeoutKindForProviderKind(_ kind: LLMProviderError.TimeoutKind) -> TaskTimeoutKind {
    switch kind {
    case .request:
        return .request
    case .resource:
        return .resource
    case .streamFirstToken:
        return .streamFirstToken
    case .streamIdle:
        return .streamIdle
    }
}

private func isTimeoutMessage(_ message: String) -> Bool {
    let message = message.lowercased()
    return message.contains("timed out") || message.contains("timeout")
}

private func timeoutKindForError(_ error: Error) -> TaskTimeoutKind? {
    if let providerError = error as? LLMProviderError {
        switch providerError {
        case .timedOut(let kind, _):
            return timeoutKindForProviderKind(kind)
        case .network(let message), .unknown(let message):
            return isTimeoutMessage(message) ? .unknown : nil
        case .invalidConfiguration, .unauthorized, .cancelled:
            return nil
        }
    }

    if error is AppTaskTimeoutError {
        return .execution
    }

    if let urlError = error as? URLError, urlError.code == .timedOut {
        return .request
    }
    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain && nsError.code == URLError.timedOut.rawValue {
        return .request
    }
    if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ETIMEDOUT) {
        return .request
    }
    return nil
}

func terminalOutcomeForCancellation(
    taskKind: AgentTaskKind,
    terminationReason: AppTaskTerminationReason?
) -> TaskTerminalOutcome {
    let cancellationOutcome = resolveAgentCancellationOutcome(
        taskKind: taskKind,
        terminationReason: terminationReason
    )
    switch cancellationOutcome {
    case .timedOut(let timeoutError, let failureReason):
        return .timedOut(
            failureReason: failureReason,
            message: timeoutError.localizedDescription
        )
    case .userCancelled(let failureReason):
        return .cancelled(failureReason: failureReason)
    }
}

func resolveAgentCancellationOutcome(
    taskKind: AgentTaskKind,
    terminationReason: AppTaskTerminationReason?
) -> AgentCancellationOutcome {
    if terminationReason == .timedOut {
        let timeoutError = makeAgentTimeoutError(taskKind: taskKind)
        let failureReason = AgentFailureClassifier.classify(error: timeoutError, taskKind: taskKind)
        return .timedOut(error: timeoutError, failureReason: failureReason)
    }

    // Queue cancellation should always set a reason. If missing, normalize to user-cancelled
    // instead of inferring timeout semantics.
    if terminationReason == nil {
        assertionFailure("Missing task termination reason for cancellation.")
    }
    let failureReason = AgentFailureClassifier.classify(error: CancellationError(), taskKind: taskKind)
    return .userCancelled(failureReason: failureReason)
}

private func makeAgentTimeoutError(taskKind: AgentTaskKind) -> AppTaskTimeoutError {
    let unifiedKind = UnifiedTaskKind.from(agentTaskKind: taskKind)
    let appTaskKind = unifiedKind.appTaskKind
    let timeoutSeconds = Int(TaskTimeoutPolicy.executionTimeout(for: unifiedKind) ?? 0)
    return AppTaskTimeoutError.executionTimedOut(kind: appTaskKind, seconds: timeoutSeconds)
}

func usageStatusForCancellation(
    taskKind: AgentTaskKind,
    terminationReason: AppTaskTerminationReason?
) -> LLMUsageRequestStatus {
    terminalOutcomeForCancellation(taskKind: taskKind, terminationReason: terminationReason).usageStatus
}

func usageStatusForFailure(error: Error, taskKind: AgentTaskKind) -> LLMUsageRequestStatus {
    terminalOutcomeForFailure(error: error, taskKind: taskKind).usageStatus
}

func terminalOutcomeForFailure(error: Error, taskKind: AgentTaskKind) -> TaskTerminalOutcome {
    let failureReason = AgentFailureClassifier.classify(error: error, taskKind: taskKind)
    if failureReason == .timedOut {
        return TaskTerminalOutcome
            .timedOut(failureReason: failureReason, message: error.localizedDescription)
    }
    return TaskTerminalOutcome
        .failed(failureReason: failureReason, message: error.localizedDescription)
}

func isCancellationLikeError(_ error: Error) -> Bool {
    if error is CancellationError {
        return true
    }
    if let providerError = error as? LLMProviderError, case .cancelled = providerError {
        return true
    }
    return false
}

private func containsRateLimitSignal(_ message: String) -> Bool {
    let normalized = message.lowercased()
    if normalized.contains("too many requests") {
        return true
    }
    if normalized.contains("rate limit") || normalized.contains("rate-limit") {
        return true
    }
    if normalized.contains("http 429") || normalized.contains("status code: 429") || normalized.contains("status code 429") {
        return true
    }
    return normalized.contains("429")
}

func isRateLimitMessage(_ message: String) -> Bool {
    containsRateLimitSignal(message)
}

func isRateLimitError(_ error: Error) -> Bool {
    if let providerError = error as? LLMProviderError {
        switch providerError {
        case .network(let message), .unknown(let message):
            if containsRateLimitSignal(message) {
                return true
            }
        case .invalidConfiguration, .timedOut, .unauthorized, .cancelled:
            break
        }
    }

    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain, nsError.code == 429 {
        return true
    }
    return containsRateLimitSignal(nsError.localizedDescription)
}

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

func resolveAgentRouteCandidates(
    taskType: AgentTaskType,
    primaryModelId: Int64?,
    fallbackModelId: Int64?,
    database: DatabaseManager,
    credentialStore: CredentialStore
) async throws -> [AgentRouteCandidate] {
    let (models, providers) = try await database.read { db in
        let models: [AgentModelProfile]
        switch taskType {
        case .summary:
            models = try AgentModelProfile
                .filter(Column("supportsSummary") == true)
                .filter(Column("isEnabled") == true)
                .filter(Column("isArchived") == false)
                .fetchAll(db)
        case .translation:
            models = try AgentModelProfile
                .filter(Column("supportsTranslation") == true)
                .filter(Column("isEnabled") == true)
                .filter(Column("isArchived") == false)
                .fetchAll(db)
        case .tagging:
            models = try AgentModelProfile
                .filter(Column("supportsTagging") == true)
                .filter(Column("isEnabled") == true)
                .filter(Column("isArchived") == false)
                .fetchAll(db)
        }

        let providers = try AgentProviderProfile
            .filter(Column("isEnabled") == true)
            .filter(Column("isArchived") == false)
            .fetchAll(db)
        return (models, providers)
    }

    let modelsByID = Dictionary(uniqueKeysWithValues: models.compactMap { model in
        model.id.map { ($0, model) }
    })
    let providersByID = Dictionary(uniqueKeysWithValues: providers.compactMap { provider in
        provider.id.map { ($0, provider) }
    })

    var routeModelIDs: [Int64] = []
    if let primaryModelId {
        routeModelIDs.append(primaryModelId)
    } else if let defaultModel = models.first(where: { $0.isDefault }), let defaultModelId = defaultModel.id {
        routeModelIDs.append(defaultModelId)
    } else if let newest = models.sorted(by: { $0.updatedAt > $1.updatedAt }).first, let modelId = newest.id {
        routeModelIDs.append(modelId)
    }

    if let fallbackModelId, routeModelIDs.contains(fallbackModelId) == false {
        routeModelIDs.append(fallbackModelId)
    }

    var candidates: [AgentRouteCandidate] = []
    for modelID in routeModelIDs {
        guard let model = modelsByID[modelID] else { continue }
        guard let provider = providersByID[model.providerProfileId] else { continue }
        let apiKey = try credentialStore.readSecret(for: provider.apiKeyRef)
        candidates.append(AgentRouteCandidate(provider: provider, model: model, apiKey: apiKey))
    }

    if candidates.isEmpty {
        let fallbackModel = models
            .sorted { lhs, rhs in
                if lhs.isDefault != rhs.isDefault {
                    return lhs.isDefault && rhs.isDefault == false
                }
                return lhs.updatedAt > rhs.updatedAt
            }
            .first
        if let fallbackModel, let provider = providersByID[fallbackModel.providerProfileId] {
            let apiKey = try credentialStore.readSecret(for: provider.apiKeyRef)
            candidates.append(AgentRouteCandidate(provider: provider, model: fallbackModel, apiKey: apiKey))
        }
    }

    return candidates
}

func recordAgentTerminalRun(
    database: DatabaseManager,
    entryId: Int64,
    taskType: AgentTaskType,
    status: AgentTaskRunStatus,
    context: AgentTerminalRunContext,
    targetLanguage: String,
    durationMs: Int
) async throws -> Int64 {
    let snapshot = try AgentExecutionShared.encodeRuntimeSnapshot(context.runtimeSnapshot)
    let now = Date()
    return try await database.write { db in
        var run = AgentTaskRun(
            id: nil,
            entryId: entryId,
            taskType: taskType,
            status: status,
            agentProfileId: nil,
            providerProfileId: context.providerProfileId,
            modelProfileId: context.modelProfileId,
            promptVersion: nil,
            targetLanguage: targetLanguage,
            templateId: context.templateId,
            templateVersion: context.templateVersion,
            runtimeParameterSnapshot: snapshot,
            durationMs: durationMs,
            createdAt: now,
            updatedAt: now
        )
        try run.insert(db)
        guard let runID = run.id else {
            throw AgentExecutionSharedError.missingTaskRunID
        }
        return runID
    }
}

func recordLLMUsageEvent(
    database: DatabaseManager,
    context: LLMUsageEventContext
) async throws {
    let promptTokens = context.promptTokens
    let completionTokens = context.completionTokens
    let totalTokens: Int?
    if let promptTokens, let completionTokens {
        totalTokens = promptTokens + completionTokens
    } else {
        totalTokens = nil
    }
    let usageAvailability: LLMUsageAvailability = totalTokens == nil ? .missing : .actual

    try await database.write { db in
        var event = LLMUsageEvent(
            id: nil,
            taskRunId: context.taskRunId,
            entryId: context.entryId,
            taskType: context.taskType,
            providerProfileId: context.providerProfileId,
            modelProfileId: context.modelProfileId,
            providerBaseURLSnapshot: context.providerBaseURLSnapshot,
            providerResolvedURLSnapshot: context.providerResolvedURLSnapshot,
            providerResolvedHostSnapshot: context.providerResolvedHostSnapshot,
            providerResolvedPathSnapshot: context.providerResolvedPathSnapshot,
            providerNameSnapshot: context.providerNameSnapshot,
            modelNameSnapshot: context.modelNameSnapshot,
            requestPhase: context.requestPhase,
            requestStatus: context.requestStatus,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            totalTokens: totalTokens,
            usageAvailability: usageAvailability,
            startedAt: context.startedAt,
            finishedAt: context.finishedAt,
            createdAt: context.finishedAt ?? Date()
        )
        try event.insert(db)
    }
}

func linkRecentUsageEventsToTaskRun(
    database: DatabaseManager,
    taskRunId: Int64,
    entryId: Int64,
    taskType: AgentTaskType,
    startedAt: Date,
    finishedAt: Date
) async throws {
    let lowerBound = startedAt.addingTimeInterval(-1)
    let upperBound = finishedAt.addingTimeInterval(1)

    try await database.write { db in
        _ = try LLMUsageEvent
            .filter(Column("taskRunId") == nil)
            .filter(Column("entryId") == entryId)
            .filter(Column("taskType") == taskType.rawValue)
            .filter(Column("createdAt") >= lowerBound)
            .filter(Column("createdAt") <= upperBound)
            .updateAll(db, Column("taskRunId").set(to: taskRunId))
    }
}
