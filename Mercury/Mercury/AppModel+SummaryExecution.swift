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
    case completed
    case failed(String, AgentFailureReason)
    case cancelled
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
        onEvent: @escaping @Sendable (SummaryRunEvent) async -> Void
    ) async -> UUID {
        let sourceText = request.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetLanguage = request.targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        let summaryDefaults = loadSummaryAgentDefaults()

        let taskId = await enqueueTask(
            kind: .summary,
            title: "Summary",
            priority: .userInitiated
        ) { [self, database, credentialStore] report in
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
                    credentialStore: credentialStore
                ) { token in
                    await onEvent(.token(token))
                }

                let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                _ = try await self.persistSuccessfulSummaryResult(
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
                    runtimeParameterSnapshot: success.runtimeSnapshot,
                    durationMs: durationMs
                )

                await report(1, "Summary completed")
                await onEvent(.completed)
            } catch is CancellationError {
                let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                let failureReason = AgentFailureClassifier.classify(error: CancellationError(), taskKind: .summary)
                let context = AgentTerminalRunContext(
                    providerProfileId: nil,
                    modelProfileId: nil,
                    templateId: "summary.default",
                    templateVersion: "v1",
                    runtimeSnapshot: [
                        "reason": "cancelled",
                        "failureReason": failureReason.rawValue,
                        "targetLanguage": targetLanguage,
                        "detailLevel": request.detailLevel.rawValue
                    ]
                )
                try? await recordAgentTerminalRun(
                    database: database,
                    entryId: request.entryId,
                    taskType: .summary,
                    status: .cancelled,
                    context: context,
                    targetLanguage: targetLanguage,
                    durationMs: durationMs
                )
                await MainActor.run {
                    self.reportDebugIssue(
                        title: "Summary Cancelled",
                        detail: "entryId=\(request.entryId)\nfailureReason=\(failureReason.rawValue)\ntargetLanguage=\(targetLanguage)\ndetailLevel=\(request.detailLevel.rawValue)",
                        category: .task
                    )
                }
                await onEvent(.cancelled)
                throw CancellationError()
            } catch {
                let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                let failureReason = AgentFailureClassifier.classify(error: error, taskKind: .summary)
                let context = AgentTerminalRunContext(
                    providerProfileId: nil,
                    modelProfileId: nil,
                    templateId: "summary.default",
                    templateVersion: "v1",
                    runtimeSnapshot: [
                        "reason": "failed",
                        "failureReason": failureReason.rawValue,
                        "targetLanguage": targetLanguage,
                        "detailLevel": request.detailLevel.rawValue,
                        "error": error.localizedDescription
                    ]
                )
                try? await recordAgentTerminalRun(
                    database: database,
                    entryId: request.entryId,
                    taskType: .summary,
                    status: .failed,
                    context: context,
                    targetLanguage: targetLanguage,
                    durationMs: durationMs
                )
                await MainActor.run {
                    // noModelRoute and invalidConfiguration are user-configurable states, not
                    // diagnostic anomalies. Skip debug issue writes for those; the Reader banner
                    // surfaces them to the user.
                    if failureReason != .noModelRoute && failureReason != .invalidConfiguration {
                        self.reportDebugIssue(
                            title: "Summary Failed",
                            detail: "entryId=\(request.entryId)\nfailureReason=\(failureReason.rawValue)\nerror=\(error.localizedDescription)",
                            category: .task
                        )
                    }
                }
                await report(nil, "Summary failed")
                await onEvent(.failed(error.localizedDescription, failureReason))
                throw error
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
                stream: candidate.model.isStreaming
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
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            lastError = error
            if index < candidates.count - 1 {
                continue
            }
        }
    }

    throw lastError ?? SummaryExecutionError.noUsableModelRoute
}
