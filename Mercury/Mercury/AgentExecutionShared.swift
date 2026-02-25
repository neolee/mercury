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

func resolveAgentCancellationOutcome(taskKind: AgentTaskKind) async -> AgentCancellationOutcome {
    let terminationReason = await AppTaskCancellationContext.currentReason()
    if terminationReason == .userCancelled {
        let failureReason = AgentFailureClassifier.classify(error: CancellationError(), taskKind: taskKind)
        return .userCancelled(failureReason: failureReason)
    }

    // In this execution path, cancellation should only come from explicit user abort or queue timeout.
    // If the reason is missing, prefer timeout semantics instead of collapsing into "cancelled".
    if terminationReason == .timedOut || terminationReason == nil {
        let timeoutError = makeAgentTimeoutError(taskKind: taskKind)
        let failureReason = AgentFailureClassifier.classify(error: timeoutError, taskKind: taskKind)
        return .timedOut(error: timeoutError, failureReason: failureReason)
    }

    let failureReason = AgentFailureClassifier.classify(error: CancellationError(), taskKind: taskKind)
    return .userCancelled(failureReason: failureReason)
}

private func makeAgentTimeoutError(taskKind: AgentTaskKind) -> AppTaskTimeoutError {
    let appTaskKind: AppTaskKind
    switch taskKind {
    case .summary:
        appTaskKind = .summary
    case .translation:
        appTaskKind = .translation
    case .tagging:
        appTaskKind = .custom
    }
    let timeoutSeconds = Int(TaskTimeoutPolicy.executionTimeout(for: appTaskKind) ?? 0)
    return AppTaskTimeoutError.executionTimedOut(kind: appTaskKind, seconds: timeoutSeconds)
}

extension AppModel {
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
        onFailed: @escaping @Sendable (String, AgentFailureReason) async -> Void,
        onCancelled: @escaping @Sendable () async -> Void
    ) async throws {
        let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        let cancellationOutcome = await resolveAgentCancellationOutcome(taskKind: taskKind)

        switch cancellationOutcome {
        case .timedOut(let timeoutError, let failureReason):
            var runtimeSnapshot = runtimeSnapshotBase
            runtimeSnapshot["reason"] = "timed_out"
            runtimeSnapshot["failureReason"] = failureReason.rawValue
            runtimeSnapshot["error"] = timeoutError.localizedDescription

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
                status: .timedOut,
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
                self.reportDebugIssue(
                    title: failedDebugTitle,
                    detail: "entryId=\(entryId)\nfailureReason=\(failureReason.rawValue)\nerror=\(timeoutError.localizedDescription)",
                    category: .task
                )
            }

            await report(nil, reportFailureMessage)
            await onFailed(timeoutError.localizedDescription, failureReason)
            throw timeoutError

        case .userCancelled(let failureReason):
            var runtimeSnapshot = runtimeSnapshotBase
            runtimeSnapshot["reason"] = "cancelled"
            runtimeSnapshot["failureReason"] = failureReason.rawValue

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
                status: .cancelled,
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
                self.reportDebugIssue(
                    title: cancelledDebugTitle,
                    detail: cancelledDebugDetail + "\nfailureReason=\(failureReason.rawValue)",
                    category: .task
                )
            }

            await onCancelled()
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
