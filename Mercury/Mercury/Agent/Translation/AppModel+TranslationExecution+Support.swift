import Foundation

func translationSegmentFailure(from error: Error) -> TranslationSegmentFailure {
    if isCancellationLikeError(error) {
        return .cancelled
    }
    if isRateLimitError(error) {
        return .rateLimited(details: TranslationExecutionSupport.rateLimitGuidance(from: error))
    }
    if let translationError = error as? TranslationExecutionError {
        return .translation(translationError)
    }
    if let providerError = error as? LLMProviderError {
        switch providerError {
        case .invalidConfiguration(let message):
            return .provider(kind: .invalidConfiguration, message: message)
        case .network(let message):
            return .provider(kind: .network, message: message)
        case .timedOut(_, let message):
            return .provider(kind: .timedOut, message: message ?? "Request timed out.")
        case .unauthorized:
            return .provider(kind: .unauthorized, message: "")
        case .cancelled:
            return .cancelled
        case .unknown(let message):
            return .provider(kind: .unknown, message: message)
        }
    }
    if let urlError = error as? URLError {
        switch urlError.code {
        case .timedOut:
            return .provider(kind: .timedOut, message: urlError.localizedDescription)
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost:
            return .provider(kind: .network, message: urlError.localizedDescription)
        default:
            break
        }
    }
    let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    if message.isEmpty {
        return .unknown(message: "Unknown translation segment error.")
    }
    return .unknown(message: message)
}

func translationError(from failure: TranslationSegmentFailure) -> Error {
    switch failure {
    case .cancelled:
        return CancellationError()
    case .rateLimited(let details):
        return TranslationExecutionError.rateLimited(details: details)
    case .translation(let error):
        return error
    case .provider(let kind, let message):
        switch kind {
        case .invalidConfiguration:
            return LLMProviderError.invalidConfiguration(message)
        case .network:
            return LLMProviderError.network(message)
        case .timedOut:
            return LLMProviderError.timedOut(kind: .request, message: message)
        case .unauthorized:
            return LLMProviderError.unauthorized
        case .unknown:
            return LLMProviderError.unknown(message)
        }
    case .unknown(let message):
        return LLMProviderError.unknown(message)
    }
}

func resolveRoute(candidate: AgentRouteCandidate, routeIndex: Int) throws -> TranslationResolvedRoute {
    guard let baseURL = URL(string: candidate.provider.baseURL) else {
        throw TranslationExecutionError.invalidBaseURL(candidate.provider.baseURL)
    }
    _ = baseURL

    guard let providerProfileId = candidate.provider.id,
          let modelProfileId = candidate.model.id else {
        throw TranslationExecutionError.noUsableModelRoute
    }

    return TranslationResolvedRoute(
        providerProfileId: providerProfileId,
        modelProfileId: modelProfileId,
        routeIndex: routeIndex
    )
}

func performTranslationModelRequest(
    entryId: Int64,
    targetLanguage: String,
    sourceText: String,
    previousSourceText: String? = nil,
    candidate: AgentRouteCandidate,
    template: AgentPromptTemplate,
    database: DatabaseManager,
    cancellationReasonProvider: @escaping AppTaskTerminationReasonProvider,
    onToken: @escaping @Sendable (String) async -> Void
) async throws -> String {
    let normalizedSourceText = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalizedSourceText.isEmpty == false else {
        throw TranslationExecutionError.invalidModelResponse
    }
    let parameters = [
        "targetLanguageDisplayName": AgentExecutionShared.languageDisplayName(for: targetLanguage),
        "sourceText": normalizedSourceText
    ]

    let systemPrompt = try template.renderSystem(parameters: parameters) ?? ""
    let userPromptTemplate = try template.render(parameters: parameters)
    let userPrompt = TranslationExecutionSupport.promptWithOptionalPreviousContext(
        basePrompt: userPromptTemplate,
        previousSourceText: previousSourceText
    )

    guard let baseURL = URL(string: candidate.provider.baseURL) else {
        throw TranslationExecutionError.invalidBaseURL(candidate.provider.baseURL)
    }

    let llmRequest = LLMRequest(
        baseURL: baseURL,
        apiKey: candidate.apiKey,
        model: candidate.model.modelName,
        messages: [
            LLMMessage(role: "system", content: systemPrompt),
            LLMMessage(role: "user", content: userPrompt)
        ],
        temperature: candidate.model.temperature,
        topP: candidate.model.topP,
        maxTokens: candidate.model.maxTokens,
        stream: candidate.model.isStreaming,
        networkTimeoutProfile: LLMNetworkTimeoutProfile(
            policy: TaskTimeoutPolicy.networkTimeout(for: AgentTaskKind.translation)
        )
    )

    let provider = AgentLLMProvider()
    let response: LLMResponse
    let requestStartedAt = Date()
    do {
        if candidate.model.isStreaming {
            response = try await provider.stream(request: llmRequest) { event in
                if case .token(let token) = event {
                    await onToken(token)
                }
            }
        } else {
            response = try await provider.complete(request: llmRequest)
            if response.text.isEmpty == false {
                await onToken(response.text)
            }
        }
        try? await recordLLMUsageEvent(
            database: database,
            context: LLMUsageEventContext(
                taskRunId: nil,
                entryId: entryId,
                taskType: .translation,
                providerProfileId: candidate.provider.id,
                modelProfileId: candidate.model.id,
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
    } catch {
        if isCancellationLikeError(error) {
            let cancellationStatus = usageStatusForCancellation(
                taskKind: .translation,
                terminationReason: await cancellationReasonProvider()
            )
            try? await recordLLMUsageEvent(
                database: database,
                context: LLMUsageEventContext(
                    taskRunId: nil,
                    entryId: entryId,
                    taskType: .translation,
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
                taskType: .translation,
                providerProfileId: candidate.provider.id,
                modelProfileId: candidate.model.id,
                providerBaseURLSnapshot: candidate.provider.baseURL,
                providerResolvedURLSnapshot: nil,
                providerResolvedHostSnapshot: nil,
                providerResolvedPathSnapshot: nil,
                providerNameSnapshot: candidate.provider.name,
                modelNameSnapshot: candidate.model.modelName,
                requestPhase: .normal,
                requestStatus: usageStatusForFailure(error: error, taskKind: .translation),
                promptTokens: nil,
                completionTokens: nil,
                startedAt: requestStartedAt,
                finishedAt: Date()
            )
        )
        throw error
    }
    return response.text
}
