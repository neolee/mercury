//
//  AppModel+TagExecution.swift
//  Mercury
//

import Foundation
import GRDB

struct TaggingPanelRequest: Sendable {
    let entryId: Int64
    let title: String
    // First 800 chars of Readability body, or Entry.summary if unavailable.
    let body: String
}

enum TaggingPanelEvent: Sendable {
    case started(UUID)
    // Resolved tag names (existing canonical names or normalized new proposals).
    case completed([String])
    case terminal(TaskTerminalOutcome)
}

enum TaggingExecutionError: LocalizedError {
    case noUsableModelRoute

    var errorDescription: String? {
        switch self {
        case .noUsableModelRoute:
            return "No usable tagging model route is configured. Please check model/provider settings."
        }
    }
}

private struct TaggingExecutionSuccess: Sendable {
    let providerProfileId: Int64
    let modelProfileId: Int64
    let templateId: String
    let templateVersion: String
    let resolvedTagNames: [String]
    let runtimeSnapshot: [String: String]
}

extension AppModel {
    /// Start a panel tagging run using replace-on-reopen scheduling policy.
    /// Any in-flight panel task for the same entry is cancelled before the new run is submitted.
    func startTaggingPanelRun(
        request: TaggingPanelRequest,
        onEvent: @escaping @Sendable (TaggingPanelEvent) async -> Void
    ) async -> UUID {
        // Replace-on-reopen: cancel any in-flight panel task for this entry.
        if let existingId = activeTaggingPanelTaskIds[request.entryId] {
            await cancelTask(existingId)
        }

        let taggingDefaults = loadTaggingAgentDefaults()
        let resolvedTaskID = makeTaskID()
        activeTaggingPanelTaskIds[request.entryId] = resolvedTaskID

        _ = await enqueueTask(
            taskId: resolvedTaskID,
            kind: .tagging,
            title: "Tagging",
            priority: .userInitiated,
            executionTimeout: TaskTimeoutPolicy.executionTimeout(for: AppTaskKind.tagging)
        ) { [self, database, credentialStore] executionContext in
            let report = executionContext.reportProgress
            try Task.checkCancellation()
            await report(0, "Preparing tag suggestions")

            let startedAt = Date()
            do {
                let success = try await runTaggingPanelExecution(
                    request: request,
                    defaults: taggingDefaults,
                    database: database,
                    credentialStore: credentialStore,
                    cancellationReasonProvider: executionContext.terminationReason
                )

                let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                var runtimeSnapshot = success.runtimeSnapshot
                runtimeSnapshot["taskId"] = resolvedTaskID.uuidString

                let runID = try await recordAgentTerminalRun(
                    database: database,
                    entryId: request.entryId,
                    taskType: .tagging,
                    status: .succeeded,
                    context: AgentTerminalRunContext(
                        providerProfileId: success.providerProfileId,
                        modelProfileId: success.modelProfileId,
                        templateId: success.templateId,
                        templateVersion: success.templateVersion,
                        runtimeSnapshot: runtimeSnapshot
                    ),
                    targetLanguage: "",
                    durationMs: durationMs
                )

                try? await linkRecentUsageEventsToTaskRun(
                    database: database,
                    taskRunId: runID,
                    entryId: request.entryId,
                    taskType: .tagging,
                    startedAt: startedAt,
                    finishedAt: Date()
                )

                await report(1, "Tagging completed")
                await onEvent(.completed(success.resolvedTagNames))
                await onEvent(.terminal(.succeeded))
            } catch {
                if isCancellationLikeError(error) {
                    let terminationReason = await executionContext.terminationReason()
                    try await handleAgentCancellation(
                        database: database,
                        startedAt: startedAt,
                        entryId: request.entryId,
                        taskType: .tagging,
                        taskKind: .tagging,
                        targetLanguage: "",
                        templateId: TaggingPromptCustomization.templateID,
                        templateVersion: "v1",
                        runtimeSnapshotBase: ["taskId": resolvedTaskID.uuidString],
                        failedDebugTitle: "Tagging Failed",
                        cancelledDebugTitle: "Tagging Cancelled",
                        cancelledDebugDetail: "entryId=\(request.entryId)",
                        reportFailureMessage: "Tagging failed",
                        report: report,
                        terminationReason: terminationReason,
                        onTerminal: { outcome in
                            await onEvent(.terminal(outcome))
                        }
                    )
                } else {
                    await handleAgentFailure(
                        database: database,
                        startedAt: startedAt,
                        entryId: request.entryId,
                        taskType: .tagging,
                        taskKind: .tagging,
                        targetLanguage: "",
                        templateId: TaggingPromptCustomization.templateID,
                        templateVersion: "v1",
                        runtimeSnapshotBase: ["taskId": resolvedTaskID.uuidString],
                        failedDebugTitle: "Tagging Failed",
                        reportFailureMessage: "Tagging failed",
                        report: report,
                        error: error,
                        onTerminal: { outcome in
                            await onEvent(.terminal(outcome))
                        }
                    )
                    throw error
                }
            }
        }

        await onEvent(.started(resolvedTaskID))
        return resolvedTaskID
    }

    /// Cancel any in-flight panel tagging task for the given entry.
    func cancelTaggingPanelRun(entryId: Int64) async {
        guard let existingId = activeTaggingPanelTaskIds[entryId] else { return }
        await cancelTask(existingId)
        activeTaggingPanelTaskIds.removeValue(forKey: entryId)
    }
}

private func runTaggingPanelExecution(
    request: TaggingPanelRequest,
    defaults: TaggingAgentDefaults,
    database: DatabaseManager,
    credentialStore: CredentialStore,
    cancellationReasonProvider: @escaping AppTaskTerminationReasonProvider
) async throws -> TaggingExecutionSuccess {
    let template = try TaggingPromptCustomization.loadTaggingTemplate()

    // Fetch top vocabulary tags for prompt injection (non-provisional, ordered by usage).
    let vocabularyTags = try await database.read { db in
        try Tag
            .filter(Column("isProvisional") == false)
            .order(Column("usageCount").desc)
            .limit(TaggingPolicy.maxVocabularyInjection)
            .fetchAll(db)
    }
    let vocabularyNames = vocabularyTags.map { $0.name }
    let vocabularyJson: String
    if let encoded = try? JSONEncoder().encode(vocabularyNames),
       let str = String(data: encoded, encoding: .utf8) {
        vocabularyJson = str
    } else {
        vocabularyJson = "[]"
    }

    let renderParameters: [String: String] = [
        "existingTagsJson": vocabularyJson,
        "maxTagCount": String(TaggingPolicy.maxAIRecommendations),
        "maxNewTagCount": String(TaggingPolicy.maxNewTagProposalsPerEntry),
        "title": request.title,
        "body": String(request.body.prefix(800))
    ]

    let renderedSystemPrompt = try template.renderSystem(parameters: renderParameters) ?? ""
    let renderedPrompt = try template.render(parameters: renderParameters)

    let candidates = try await resolveAgentRouteCandidates(
        taskType: .tagging,
        primaryModelId: defaults.primaryModelId,
        fallbackModelId: defaults.fallbackModelId,
        database: database,
        credentialStore: credentialStore
    )
    guard candidates.isEmpty == false else {
        throw TaggingExecutionError.noUsableModelRoute
    }

    var lastError: Error?
    for (index, candidate) in candidates.enumerated() {
        let requestStartedAt = Date()
        do {
            try Task.checkCancellation()

            guard let baseURL = URL(string: candidate.provider.baseURL) else {
                throw LLMProviderError.invalidConfiguration(
                    "Invalid provider base URL: \(candidate.provider.baseURL)"
                )
            }
            guard let providerProfileId = candidate.provider.id,
                  let modelProfileId = candidate.model.id else {
                throw TaggingExecutionError.noUsableModelRoute
            }

            let llmRequest = LLMRequest(
                baseURL: baseURL,
                apiKey: candidate.apiKey,
                model: candidate.model.modelName,
                messages: [
                    LLMMessage(role: "system", content: renderedSystemPrompt),
                    LLMMessage(role: "user", content: renderedPrompt)
                ],
                temperature: candidate.model.temperature,
                topP: candidate.model.topP,
                maxTokens: candidate.model.maxTokens,
                stream: false,
                networkTimeoutProfile: LLMNetworkTimeoutProfile(
                    policy: TaskTimeoutPolicy.networkTimeout(for: AgentTaskKind.tagging)
                )
            )

            let provider = AgentLLMProvider()
            let response = try await provider.complete(request: llmRequest)

            try? await recordLLMUsageEvent(
                database: database,
                context: LLMUsageEventContext(
                    taskRunId: nil,
                    entryId: request.entryId,
                    taskType: .tagging,
                    providerProfileId: providerProfileId,
                    modelProfileId: modelProfileId,
                    providerBaseURLSnapshot: candidate.provider.baseURL,
                    providerResolvedURLSnapshot: response.resolvedEndpoint?.url,
                    providerResolvedHostSnapshot: response.resolvedEndpoint?.host,
                    providerResolvedPathSnapshot: response.resolvedEndpoint?.path,
                    providerNameSnapshot: candidate.provider.name,
                    modelNameSnapshot: candidate.model.modelName,
                    requestPhase: .normal,
                    requestStatus: .succeeded,
                    promptTokens: response.usagePromptTokens,
                    completionTokens: response.usageCompletionTokens,
                    startedAt: requestStartedAt,
                    finishedAt: Date()
                )
            )

            // Parse flat JSON array from LLM response text.
            let rawNames = parseTagsFromLLMResponse(response.text)
            // Resolve names through alias resolver + strict DB match.
            let resolvedNames = try await resolveTagNamesFromDB(rawNames, database: database)

            return TaggingExecutionSuccess(
                providerProfileId: providerProfileId,
                modelProfileId: modelProfileId,
                templateId: template.id,
                templateVersion: template.version,
                resolvedTagNames: resolvedNames,
                runtimeSnapshot: [
                    "providerProfileId": String(providerProfileId),
                    "modelProfileId": String(modelProfileId),
                    "routeIndex": String(index),
                    "rawTagCount": String(rawNames.count),
                    "resolvedTagCount": String(resolvedNames.count)
                ]
            )
        } catch {
            if isCancellationLikeError(error) {
                let cancellationStatus = usageStatusForCancellation(
                    taskKind: .tagging,
                    terminationReason: await cancellationReasonProvider()
                )
                try? await recordLLMUsageEvent(
                    database: database,
                    context: LLMUsageEventContext(
                        taskRunId: nil,
                        entryId: request.entryId,
                        taskType: .tagging,
                        providerProfileId: candidate.provider.id,
                        modelProfileId: candidate.model.id,
                        providerBaseURLSnapshot: candidate.provider.baseURL,
                        providerResolvedURLSnapshot: nil,
                        providerResolvedHostSnapshot: nil,
                        providerResolvedPathSnapshot: nil,
                        providerNameSnapshot: candidate.provider.name,
                        modelNameSnapshot: candidate.model.modelName,
                        requestPhase: .normal,
                        requestStatus: cancellationStatus,
                        promptTokens: nil,
                        completionTokens: nil,
                        startedAt: requestStartedAt,
                        finishedAt: Date()
                    )
                )
                throw CancellationError()
            }

            try? await recordLLMUsageEvent(
                database: database,
                context: LLMUsageEventContext(
                    taskRunId: nil,
                    entryId: request.entryId,
                    taskType: .tagging,
                    providerProfileId: candidate.provider.id,
                    modelProfileId: candidate.model.id,
                    providerBaseURLSnapshot: candidate.provider.baseURL,
                    providerResolvedURLSnapshot: nil,
                    providerResolvedHostSnapshot: nil,
                    providerResolvedPathSnapshot: nil,
                    providerNameSnapshot: candidate.provider.name,
                    modelNameSnapshot: candidate.model.modelName,
                    requestPhase: .normal,
                    requestStatus: usageStatusForFailure(error: error, taskKind: .tagging),
                    promptTokens: nil,
                    completionTokens: nil,
                    startedAt: requestStartedAt,
                    finishedAt: Date()
                )
            )
            lastError = error
            if index < candidates.count - 1 {
                continue
            }
        }
    }

    throw lastError ?? TaggingExecutionError.noUsableModelRoute
}

/// Parse a flat JSON array of strings from LLM response text, stripping markdown fences if present.
func parseTagsFromLLMResponse(_ text: String) -> [String] {
    let cleaned = text
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "```json", with: "")
        .replacingOccurrences(of: "```", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = cleaned.data(using: .utf8),
          let names = try? JSONDecoder().decode([String].self, from: data) else {
        return []
    }
    return names
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { $0.isEmpty == false }
}

/// Resolve raw LLM-proposed tag names through the DB vocabulary.
/// Each name is normalized, then matched via strict normalizedName lookup or alias lookup.
/// Unmatched names are returned as normalized new proposals.
/// Result preserves the order of first occurrence and deduplicates.
func resolveTagNamesFromDB(
    _ rawNames: [String],
    database: DatabaseManager
) async throws -> [String] {
    let allTags = try await database.read { db in
        try Tag.fetchAll(db)
    }
    let allAliases = try await database.read { db in
        try TagAlias.fetchAll(db)
    }

    let tagByNormalized: [String: Tag] = Dictionary(
        uniqueKeysWithValues: allTags.compactMap { tag -> (String, Tag)? in
            guard tag.id != nil else { return nil }
            return (tag.normalizedName, tag)
        }
    )
    let tagByAlias: [String: Tag] = {
        var mapping: [String: Tag] = [:]
        for alias in allAliases {
            if let tag = allTags.first(where: { $0.id == alias.tagId }) {
                mapping[alias.normalizedAlias] = tag
            }
        }
        return mapping
    }()

    var result: [String] = []
    var seen: Set<String> = []

    for rawName in rawNames {
        let normed = TagNormalization.normalize(rawName)
        guard normed.isEmpty == false else { continue }
        if let matchedTag = tagByNormalized[normed] {
            // Exact DB match — use canonical display name.
            guard seen.insert(matchedTag.name).inserted else { continue }
            result.append(matchedTag.name)
        } else if let aliasTag = tagByAlias[normed] {
            // Alias resolution — use canonical display name.
            guard seen.insert(aliasTag.name).inserted else { continue }
            result.append(aliasTag.name)
        } else {
            // New proposal — title-case for display consistency (e.g. "finance" → "Finance").
            let titleCased = normed
                .split(separator: " ")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
            guard seen.insert(normed).inserted else { continue }
            result.append(titleCased)
        }
    }
    return result
}
