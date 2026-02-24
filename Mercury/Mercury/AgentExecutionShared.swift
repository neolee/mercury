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
) async throws {
    let snapshot = try AgentExecutionShared.encodeRuntimeSnapshot(context.runtimeSnapshot)
    let now = Date()
    try await database.write { db in
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
    }
}
