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

func usageStatusForCancellation(terminationReason: AppTaskTerminationReason?) -> LLMUsageRequestStatus {
    if terminationReason == .timedOut {
        return .timedOut
    }
    return .cancelled
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
        failedDebugTitle: String,
        cancelledDebugTitle: String?,
        cancelledDebugDetail: String?
    ) async {
        let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)

        var runtimeSnapshot = runtimeSnapshotBase
        runtimeSnapshot["reason"] = outcome.runtimeReason
        if let failureReason = outcome.failureReason {
            runtimeSnapshot["failureReason"] = failureReason.rawValue
        }
        if let errorDescription = outcome.message {
            runtimeSnapshot["error"] = errorDescription
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
            switch outcome {
            case .failed(let failureReason, let message):
                let normalizedFailureReason = failureReason ?? .unknown
                // noModelRoute and invalidConfiguration are user-configurable states, not
                // diagnostic anomalies. Skip debug issue writes for those; the Reader banner
                // surfaces them to the user.
                if normalizedFailureReason != .noModelRoute && normalizedFailureReason != .invalidConfiguration {
                    self.reportDebugIssue(
                        title: failedDebugTitle,
                        detail: "entryId=\(entryId)\nfailureReason=\(normalizedFailureReason.rawValue)\nerror=\(message ?? "")",
                        category: .task
                    )
                }
            case .timedOut(let failureReason, let message):
                let normalizedFailureReason = failureReason ?? .timedOut
                self.reportDebugIssue(
                    title: failedDebugTitle,
                    detail: "entryId=\(entryId)\nfailureReason=\(normalizedFailureReason.rawValue)\nerror=\(message ?? "")",
                    category: .task
                )
            case .cancelled(let failureReason):
                let normalizedFailureReason = failureReason ?? .cancelled
                self.reportDebugIssue(
                    title: cancelledDebugTitle ?? failedDebugTitle,
                    detail: (cancelledDebugDetail ?? "entryId=\(entryId)") + "\nfailureReason=\(normalizedFailureReason.rawValue)",
                    category: .task
                )
            case .succeeded:
                break
            }
        }
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
        let failureReason = AgentFailureClassifier.classify(error: error, taskKind: taskKind)
        let outcome = TaskTerminalOutcome.failed(
            failureReason: failureReason,
            message: error.localizedDescription
        )
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

        switch cancellationOutcome {
        case .timedOut(let timeoutError, let failureReason):
            let outcome = TaskTerminalOutcome.timedOut(
                failureReason: failureReason,
                message: timeoutError.localizedDescription
            )
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
                failedDebugTitle: failedDebugTitle,
                cancelledDebugTitle: cancelledDebugTitle,
                cancelledDebugDetail: cancelledDebugDetail
            )

            await report(nil, reportFailureMessage)
            await onTerminal(outcome)
            throw timeoutError

        case .userCancelled(let failureReason):
            let outcome = TaskTerminalOutcome.cancelled(failureReason: failureReason)
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
                failedDebugTitle: failedDebugTitle,
                cancelledDebugTitle: cancelledDebugTitle,
                cancelledDebugDetail: cancelledDebugDetail
            )

            await onTerminal(outcome)
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
