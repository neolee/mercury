import Foundation
import GRDB

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
