//
//  AppModel+SummaryExecution.swift
//  Mercury
//
//  Created by Codex on 2026/2/18.
//

import Foundation
import GRDB

private let summaryFallbackSystemPrompt = "You are a concise agent."

struct SummaryRunRequest: Sendable {
    let entryId: Int64
    let sourceText: String
    let targetLanguage: String
    let detailLevel: SummaryDetailLevel
}

enum SummaryRunEvent: Sendable {
    case started(UUID)
    case token(String)
    case terminal(TaskTerminalOutcome)
}

private struct SummaryExecutionSuccess: Sendable {
    let providerProfileId: Int64
    let modelProfileId: Int64
    let templateId: String
    let templateVersion: String
    let outputText: String
    let runtimeSnapshot: [String: String]
}

enum SummaryExecutionError: LocalizedError {
    case sourceTextRequired
    case targetLanguageRequired
    case noUsableModelRoute

    var errorDescription: String? {
        switch self {
        case .sourceTextRequired:
            return "Summary source text is required."
        case .targetLanguageRequired:
            return "Target language is required."
        case .noUsableModelRoute:
            return "No usable summary model route is configured. Please check model/provider settings."
        }
    }
}

extension AppModel {
    func startSummaryRun(
        request: SummaryRunRequest,
        requestedTaskId: UUID? = nil,
        onEvent: @escaping @Sendable (SummaryRunEvent) async -> Void
    ) async -> UUID {
        let sourceText = request.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetLanguage = request.targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        let summaryDefaults = loadSummaryAgentDefaults()

        let resolvedTaskID = requestedTaskId ?? makeTaskID()
        let taskId = await enqueueTask(
            taskId: resolvedTaskID,
            kind: .summary,
            title: "Summary",
            priority: .userInitiated,
            executionTimeout: TaskTimeoutPolicy.executionTimeout(for: AppTaskKind.summary)
        ) { [self, database, credentialStore] executionContext in
            let report = executionContext.reportProgress
            try Task.checkCancellation()
            await report(0, "Preparing summary")

            let startedAt = Date()
            do {
                let success = try await runSummaryExecution(
                    request: SummaryRunRequest(
                        entryId: request.entryId,
                        sourceText: sourceText,
                        targetLanguage: targetLanguage,
                        detailLevel: request.detailLevel
                    ),
                    defaults: summaryDefaults,
                    database: database,
                    credentialStore: credentialStore,
                    cancellationReasonProvider: executionContext.terminationReason
                ) { token in
                    await onEvent(.token(token))
                }

                let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                var runtimeSnapshot = success.runtimeSnapshot
                runtimeSnapshot["taskId"] = resolvedTaskID.uuidString
                let stored = try await self.persistSuccessfulSummaryResult(
                    entryId: request.entryId,
                    agentProfileId: nil,
                    providerProfileId: success.providerProfileId,
                    modelProfileId: success.modelProfileId,
                    promptVersion: "\(success.templateId)@\(success.templateVersion)",
                    targetLanguage: targetLanguage,
                    detailLevel: request.detailLevel,
                    outputLanguage: targetLanguage,
                    outputText: success.outputText,
                    templateId: success.templateId,
                    templateVersion: success.templateVersion,
                    runtimeParameterSnapshot: runtimeSnapshot,
                    durationMs: durationMs
                )
                if let runID = stored.run.id {
                    try? await linkRecentUsageEventsToTaskRun(
                        database: database,
                        taskRunId: runID,
                        entryId: request.entryId,
                        taskType: .summary,
                        startedAt: startedAt,
                        finishedAt: Date()
                    )
                }

                await report(1, "Summary completed")
                await onEvent(.terminal(.succeeded))
            } catch {
                if isCancellationLikeError(error) {
                    let terminationReason = await executionContext.terminationReason()
                    try await handleAgentCancellation(
                        database: database,
                        startedAt: startedAt,
                        entryId: request.entryId,
                        taskType: .summary,
                        taskKind: .summary,
                        targetLanguage: targetLanguage,
                        templateId: "summary.default",
                        templateVersion: "v1",
                        runtimeSnapshotBase: [
                            "taskId": resolvedTaskID.uuidString,
                            "targetLanguage": targetLanguage,
                            "detailLevel": request.detailLevel.rawValue
                        ],
                        failedDebugTitle: "Summary Failed",
                        cancelledDebugTitle: "Summary Cancelled",
                        cancelledDebugDetail: "entryId=\(request.entryId)\ntargetLanguage=\(targetLanguage)\ndetailLevel=\(request.detailLevel.rawValue)",
                        reportFailureMessage: "Summary failed",
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
                        taskType: .summary,
                        taskKind: .summary,
                        targetLanguage: targetLanguage,
                        templateId: "summary.default",
                        templateVersion: "v1",
                        runtimeSnapshotBase: [
                            "taskId": resolvedTaskID.uuidString,
                            "targetLanguage": targetLanguage,
                            "detailLevel": request.detailLevel.rawValue
                        ],
                        failedDebugTitle: "Summary Failed",
                        reportFailureMessage: "Summary failed",
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

        await onEvent(.started(taskId))
        return taskId
    }
}

private func runSummaryExecution(
    request: SummaryRunRequest,
    defaults: SummaryAgentDefaults,
    database: DatabaseManager,
    credentialStore: CredentialStore,
    cancellationReasonProvider: @escaping AppTaskTerminationReasonProvider,
    onToken: @escaping @Sendable (String) async -> Void
) async throws -> SummaryExecutionSuccess {
    let sourceText = request.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard sourceText.isEmpty == false else {
        throw SummaryExecutionError.sourceTextRequired
    }

    let targetLanguage = request.targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
    guard targetLanguage.isEmpty == false else {
        throw SummaryExecutionError.targetLanguageRequired
    }

    let template = try SummaryPromptCustomization.loadSummaryTemplate()
    let renderParameters = [
        "targetLanguage": targetLanguage,
        "targetLanguageDisplayName": AgentExecutionShared.languageDisplayName(for: targetLanguage),
        "detailLevel": request.detailLevel.rawValue,
        "sourceText": sourceText
    ]
    let renderedSystemPrompt = try template.renderSystem(parameters: renderParameters) ?? summaryFallbackSystemPrompt
    let renderedPrompt = try template.render(parameters: renderParameters)

    let candidates = try await resolveAgentRouteCandidates(
        taskType: .summary,
        primaryModelId: defaults.primaryModelId,
        fallbackModelId: defaults.fallbackModelId,
        database: database,
        credentialStore: credentialStore
    )
    guard candidates.isEmpty == false else {
        throw SummaryExecutionError.noUsableModelRoute
    }

    var lastError: Error?
    for (index, candidate) in candidates.enumerated() {
        let requestStartedAt = Date()
        do {
            try Task.checkCancellation()

            guard let baseURL = URL(string: candidate.provider.baseURL) else {
                throw LLMProviderError.invalidConfiguration("Invalid provider base URL: \(candidate.provider.baseURL)")
            }
            guard let providerProfileId = candidate.provider.id,
                  let modelProfileId = candidate.model.id else {
                throw SummaryExecutionError.noUsableModelRoute
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
                stream: candidate.model.isStreaming,
                networkTimeoutProfile: LLMNetworkTimeoutProfile(
                    policy: TaskTimeoutPolicy.networkTimeout(for: AgentTaskKind.summary)
                )
            )

            let provider = AgentLLMProvider()
            let response: LLMResponse
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
                    entryId: request.entryId,
                    taskType: .summary,
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

            return SummaryExecutionSuccess(
                providerProfileId: providerProfileId,
                modelProfileId: modelProfileId,
                templateId: template.id,
                templateVersion: template.version,
                outputText: response.text,
                runtimeSnapshot: [
                    "targetLanguage": targetLanguage,
                    "detailLevel": request.detailLevel.rawValue,
                    "providerProfileId": String(providerProfileId),
                    "modelProfileId": String(modelProfileId),
                    "routeIndex": String(index)
                ]
            )
        } catch {
            if isCancellationLikeError(error) {
                let cancellationStatus = usageStatusForCancellation(
                    terminationReason: await cancellationReasonProvider()
                )
                try? await recordLLMUsageEvent(
                    database: database,
                    context: LLMUsageEventContext(
                        taskRunId: nil,
                        entryId: request.entryId,
                        taskType: .summary,
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
                    taskType: .summary,
                    providerProfileId: candidate.provider.id,
                    modelProfileId: candidate.model.id,
                    providerBaseURLSnapshot: candidate.provider.baseURL,
                    providerResolvedURLSnapshot: nil,
                    providerResolvedHostSnapshot: nil,
                    providerResolvedPathSnapshot: nil,
                    providerNameSnapshot: candidate.provider.name,
                    modelNameSnapshot: candidate.model.modelName,
                    requestPhase: .normal,
                    requestStatus: .failed,
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

    throw lastError ?? SummaryExecutionError.noUsableModelRoute
}
