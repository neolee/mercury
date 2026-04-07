import Foundation
import GRDB

struct TaggingLLMRequestProfile: Sendable {
    let templateID: String
    let templateVersion: String
    let maxTagCount: Int
    let maxNewTagCount: Int
    let bodyStrategy: TaggingBodyStrategy
    let timeoutSeconds: TimeInterval
    let temperatureOverride: Double?
    let topPOverride: Double?
}

enum TaggingBodyStrategy: Sendable {
    case readabilityPrefix(Int)
    case summaryOnly
}

struct TaggingPerEntryResult: Sendable {
    let entryId: Int64
    let rawResponse: String
    let parsedNames: [String]
    let normalizedNames: [String]
    let resolvedExistingTagIDs: [Int64]
    let newProposals: [String]
    let providerProfileId: Int64?
    let modelProfileId: Int64?
    let promptTokens: Int?
    let completionTokens: Int?
    let durationMs: Int
    let errorMessage: String?
    let resolvedDisplayNames: [String]
    let resolvedItems: [TaggingResolvedNameItem]
}

struct TaggingResolvedNames: Sendable {
    let resolvedDisplayNames: [String]
    let normalizedNames: [String]
    let resolvedExistingTagIDs: [Int64]
    let newProposals: [String]
    let resolvedItems: [TaggingResolvedNameItem]
}

struct TaggingResolvedNameItem: Sendable {
    let normalizedName: String
    let displayName: String
    let resolvedTagID: Int64?
}

private func normalizedDisplayNamePreservingCase(_ rawName: String) -> String {
    rawName
        .split(whereSeparator: { $0.isWhitespace })
        .joined(separator: " ")
}

func executeTaggingPerEntry(
    entryId: Int64,
    title: String,
    body: String,
    template: AgentPromptTemplate,
    profile: TaggingLLMRequestProfile,
    defaults: TaggingAgentDefaults,
    availableModels: [AgentModelProfile],
    availableProviders: [AgentProviderProfile],
    taskKind: AgentTaskKind,
    database: DatabaseManager,
    credentialStore: CredentialStore,
    cancellationReasonProvider: @escaping AppTaskTerminationReasonProvider
) async throws -> TaggingPerEntryResult {
    let effectiveBody: String
    switch profile.bodyStrategy {
    case .readabilityPrefix(let limit):
        effectiveBody = String(body.prefix(max(1, limit)))
    case .summaryOnly:
        effectiveBody = body
    }

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
    let bodyKind: String
    switch profile.bodyStrategy {
    case .readabilityPrefix:
        bodyKind = "article excerpt"
    case .summaryOnly:
        bodyKind = "summary"
    }

    let renderParameters: [String: String] = [
        "existingTagsJson": vocabularyJson,
        "maxTagCount": String(profile.maxTagCount),
        "maxNewTagCount": String(profile.maxNewTagCount),
        "bodyKind": bodyKind,
        "title": title,
        "body": effectiveBody
    ]

    let promptMessages = try buildTaggingPromptMessages(
        template: template,
        renderParameters: renderParameters
    )

    let candidates = try await resolveAgentRouteCandidates(
        taskType: .tagging,
        primaryModelId: defaults.primaryModelId,
        fallbackModelId: defaults.fallbackModelId,
        models: availableModels,
        providers: availableProviders,
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
                messages: promptMessages.messages,
                temperature: profile.temperatureOverride ?? candidate.model.temperature,
                topP: profile.topPOverride ?? candidate.model.topP,
                maxTokens: candidate.model.maxTokens,
                stream: false,
                networkTimeoutProfile: LLMNetworkTimeoutProfile(
                    policy: TaskTimeoutPolicy.networkTimeout(for: taskKind)
                )
            )

            let provider = AgentLLMProvider()
            let response = try await provider.complete(request: llmRequest)

            try? await recordLLMUsageEvent(
                database: database,
                context: LLMUsageEventContext(
                    taskRunId: nil,
                    entryId: entryId,
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

            let parsedNames = parseTagsFromLLMResponse(response.text)
            let resolved = try await resolveTagNamesDetailedFromDB(parsedNames, database: database)
            let durationMs = Int(Date().timeIntervalSince(requestStartedAt) * 1000)

            _ = index
            return TaggingPerEntryResult(
                entryId: entryId,
                rawResponse: response.text,
                parsedNames: parsedNames,
                normalizedNames: resolved.normalizedNames,
                resolvedExistingTagIDs: resolved.resolvedExistingTagIDs,
                newProposals: resolved.newProposals,
                providerProfileId: providerProfileId,
                modelProfileId: modelProfileId,
                promptTokens: response.usagePromptTokens,
                completionTokens: response.usageCompletionTokens,
                durationMs: durationMs,
                errorMessage: nil,
                resolvedDisplayNames: resolved.resolvedDisplayNames,
                resolvedItems: resolved.resolvedItems
            )
        } catch {
            if isCancellationLikeError(error) {
                let cancellationStatus = usageStatusForCancellation(
                    taskKind: taskKind,
                    terminationReason: await cancellationReasonProvider()
                )
                try? await recordLLMUsageEvent(
                    database: database,
                    context: LLMUsageEventContext(
                        taskRunId: nil,
                        entryId: entryId,
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
                    entryId: entryId,
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
                    requestStatus: usageStatusForFailure(error: error, taskKind: taskKind),
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

func buildTaggingPromptMessages(
    template: AgentPromptTemplate,
    renderParameters: [String: String]
) throws -> AgentPromptMessages {
    let renderedSystemPrompt = try template.renderSystem(parameters: renderParameters) ?? ""
    let renderedPrompt = try template.render(parameters: renderParameters)
    return AgentPromptMessages(systemPrompt: renderedSystemPrompt, userPrompt: renderedPrompt)
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

/// Resolve raw LLM-proposed tag names through vocabulary and aliases.
func resolveTagNamesDetailedFromDB(
    _ rawNames: [String],
    database: DatabaseManager
) async throws -> TaggingResolvedNames {
    let (allTags, allAliases) = try await database.read { db in
        (try Tag.fetchAll(db), try TagAlias.fetchAll(db))
    }

    let tagByID = Dictionary(uniqueKeysWithValues: allTags.compactMap { tag in
        tag.id.map { ($0, tag) }
    })
    let tagByNormalized = Dictionary(uniqueKeysWithValues: allTags.map { ($0.normalizedName, $0) })
    let tagByAlias: [String: Tag] = {
        var mapping: [String: Tag] = [:]
        for alias in allAliases {
            if let tag = tagByID[alias.tagId] {
                mapping[alias.normalizedAlias] = tag
            }
        }
        return mapping
    }()

    var resolvedDisplayNames: [String] = []
    var normalizedNames: [String] = []
    var resolvedExistingTagIDs: [Int64] = []
    var newProposals: [String] = []
    var resolvedItems: [TaggingResolvedNameItem] = []
    var seenNormalized: Set<String> = []
    var seenDisplay: Set<String> = []

    for rawName in rawNames {
        let normalized = TagNormalization.normalize(rawName)
        guard normalized.isEmpty == false else { continue }

        if let matchedTag = tagByNormalized[normalized],
           let matchedID = matchedTag.id {
            if seenDisplay.insert(matchedTag.name).inserted {
                resolvedDisplayNames.append(matchedTag.name)
            }
            if seenNormalized.insert(normalized).inserted {
                normalizedNames.append(normalized)
            }
            if resolvedExistingTagIDs.contains(matchedID) == false {
                resolvedExistingTagIDs.append(matchedID)
            }
            resolvedItems.append(
                TaggingResolvedNameItem(
                    normalizedName: normalized,
                    displayName: matchedTag.name,
                    resolvedTagID: matchedID
                )
            )
            continue
        }

        if let aliasTag = tagByAlias[normalized],
           let aliasID = aliasTag.id {
            if seenDisplay.insert(aliasTag.name).inserted {
                resolvedDisplayNames.append(aliasTag.name)
            }
            if seenNormalized.insert(normalized).inserted {
                normalizedNames.append(normalized)
            }
            if resolvedExistingTagIDs.contains(aliasID) == false {
                resolvedExistingTagIDs.append(aliasID)
            }
            resolvedItems.append(
                TaggingResolvedNameItem(
                    normalizedName: normalized,
                    displayName: aliasTag.name,
                    resolvedTagID: aliasID
                )
            )
            continue
        }

        let preservedDisplayName = normalizedDisplayNamePreservingCase(rawName)
        guard seenNormalized.insert(normalized).inserted else { continue }

        normalizedNames.append(normalized)
        if seenDisplay.insert(preservedDisplayName).inserted {
            resolvedDisplayNames.append(preservedDisplayName)
        }
        newProposals.append(preservedDisplayName)
        resolvedItems.append(
            TaggingResolvedNameItem(
                normalizedName: normalized,
                displayName: preservedDisplayName,
                resolvedTagID: nil
            )
        )
    }

    return TaggingResolvedNames(
        resolvedDisplayNames: resolvedDisplayNames,
        normalizedNames: normalizedNames,
        resolvedExistingTagIDs: resolvedExistingTagIDs,
        newProposals: newProposals,
        resolvedItems: resolvedItems
    )
}

/// Compatibility wrapper retained for existing tests and call sites.
func resolveTagNamesFromDB(
    _ rawNames: [String],
    database: DatabaseManager
) async throws -> [String] {
    let resolved = try await resolveTagNamesDetailedFromDB(rawNames, database: database)
    return resolved.resolvedDisplayNames
}
