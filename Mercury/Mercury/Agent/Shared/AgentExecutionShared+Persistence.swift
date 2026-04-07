import Foundation
import GRDB

func resolveAgentRouteCandidates(
    taskType: AgentTaskType,
    primaryModelId: Int64?,
    fallbackModelId: Int64?,
    models: [AgentModelProfile],
    providers: [AgentProviderProfile],
    credentialStore: CredentialStore
) async throws -> [AgentRouteCandidate] {
    guard let primaryModelId else { return [] }

    let filteredModels = models.filter { model in
        guard model.isEnabled else { return false }
        switch taskType {
        case .summary:
            return model.supportsSummary
        case .translation:
            return model.supportsTranslation
        case .tagging:
            return model.supportsTagging
        }
    }
    let filteredProviders = providers.filter(\.isEnabled)

    let modelsByID = Dictionary(uniqueKeysWithValues: filteredModels.compactMap { model in
        model.id.map { ($0, model) }
    })
    let providersByID = Dictionary(uniqueKeysWithValues: filteredProviders.compactMap { provider in
        provider.id.map { ($0, provider) }
    })

    guard modelsByID[primaryModelId] != nil else { return [] }

    var routeModelIDs: [Int64] = [primaryModelId]

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

    return candidates
}

func resolveAgentRouteCandidates(
    taskType: AgentTaskType,
    primaryModelId: Int64?,
    fallbackModelId: Int64?,
    database: DatabaseManager,
    credentialStore: CredentialStore
) async throws -> [AgentRouteCandidate] {
    guard let primaryModelId else { return [] }

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

    return try await resolveAgentRouteCandidates(
        taskType: taskType,
        primaryModelId: primaryModelId,
        fallbackModelId: fallbackModelId,
        models: models,
        providers: providers,
        credentialStore: credentialStore
    )
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
