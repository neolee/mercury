//
//  AppModel+AISummaryExecution.swift
//  Mercury
//
//  Created by Codex on 2026/2/18.
//

import Foundation
import GRDB

private let summaryFallbackSystemPrompt = "You are a concise assistant."

struct AISummaryRunRequest: Sendable {
    let entryId: Int64
    let sourceText: String
    let targetLanguage: String
    let detailLevel: AISummaryDetailLevel
}

enum AISummaryRunEvent: Sendable {
    case started(UUID)
    case token(String)
    case completed
    case failed(String, AgentFailureReason)
    case cancelled
}

private struct SummaryRouteCandidate: Sendable {
    let provider: AIProviderProfile
    let model: AIModelProfile
    let apiKey: String
}

private struct SummaryExecutionSuccess: Sendable {
    let providerProfileId: Int64
    let modelProfileId: Int64
    let templateId: String
    let templateVersion: String
    let outputText: String
    let runtimeSnapshot: [String: String]
}

private struct SummaryExecutionFailureContext: Sendable {
    let providerProfileId: Int64?
    let modelProfileId: Int64?
    let templateId: String?
    let templateVersion: String?
    let runtimeSnapshot: [String: String]
}

enum AISummaryExecutionError: LocalizedError {
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
        request: AISummaryRunRequest,
        onEvent: @escaping @Sendable (AISummaryRunEvent) async -> Void
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
                    request: AISummaryRunRequest(
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
                    assistantProfileId: nil,
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
                let context = SummaryExecutionFailureContext(
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
                try? await self.recordSummaryTerminalRun(
                    entryId: request.entryId,
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
                let context = SummaryExecutionFailureContext(
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
                try? await self.recordSummaryTerminalRun(
                    entryId: request.entryId,
                    status: .failed,
                    context: context,
                    targetLanguage: targetLanguage,
                    durationMs: durationMs
                )
                await MainActor.run {
                    self.reportDebugIssue(
                        title: "Summary Failed",
                        detail: "entryId=\(request.entryId)\nfailureReason=\(failureReason.rawValue)\nerror=\(error.localizedDescription)",
                        category: .task
                    )
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
    request: AISummaryRunRequest,
    defaults: SummaryAgentDefaults,
    database: DatabaseManager,
    credentialStore: CredentialStore,
    onToken: @escaping @Sendable (String) async -> Void
) async throws -> SummaryExecutionSuccess {
    let sourceText = request.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard sourceText.isEmpty == false else {
        throw AISummaryExecutionError.sourceTextRequired
    }

    let targetLanguage = request.targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
    guard targetLanguage.isEmpty == false else {
        throw AISummaryExecutionError.targetLanguageRequired
    }

    let template = try SummaryPromptCustomization.loadSummaryTemplate()
    let renderParameters = [
        "targetLanguage": targetLanguage,
        "targetLanguageDisplayName": summaryLanguageDisplayName(for: targetLanguage),
        "detailLevel": request.detailLevel.rawValue,
        "sourceText": sourceText
    ]
    let renderedSystemPrompt = try template.renderSystem(parameters: renderParameters) ?? summaryFallbackSystemPrompt
    let renderedPrompt = try template.render(parameters: renderParameters)

    let candidates = try await resolveSummaryRouteCandidates(
        defaults: defaults,
        database: database,
        credentialStore: credentialStore
    )

    var lastError: Error?
    for (index, candidate) in candidates.enumerated() {
        do {
            try Task.checkCancellation()

            guard let baseURL = URL(string: candidate.provider.baseURL) else {
                throw LLMProviderError.invalidConfiguration("Invalid provider base URL: \(candidate.provider.baseURL)")
            }
            guard let providerProfileId = candidate.provider.id,
                  let modelProfileId = candidate.model.id else {
                throw AISummaryExecutionError.noUsableModelRoute
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

    throw lastError ?? AISummaryExecutionError.noUsableModelRoute
}

private func summaryLanguageDisplayName(for identifier: String) -> String {
    let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.isEmpty == false else {
        return "English (en)"
    }
    if let localized = Locale.current.localizedString(forIdentifier: trimmed) {
        return "\(localized) (\(trimmed))"
    }
    return trimmed
}

private func resolveSummaryRouteCandidates(
    defaults: SummaryAgentDefaults,
    database: DatabaseManager,
    credentialStore: CredentialStore
) async throws -> [SummaryRouteCandidate] {
    let (models, providers) = try await database.read { db in
        let models = try AIModelProfile
            .filter(Column("supportsSummary") == true)
            .filter(Column("isEnabled") == true)
            .fetchAll(db)
        let providers = try AIProviderProfile
            .filter(Column("isEnabled") == true)
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
    if let primaryModelId = defaults.primaryModelId {
        routeModelIDs.append(primaryModelId)
    } else if let defaultModel = models.first(where: { $0.isDefault }), let defaultModelId = defaultModel.id {
        routeModelIDs.append(defaultModelId)
    } else if let newest = models.sorted(by: { $0.updatedAt > $1.updatedAt }).first, let modelId = newest.id {
        routeModelIDs.append(modelId)
    }

    if let fallbackModelId = defaults.fallbackModelId, routeModelIDs.contains(fallbackModelId) == false {
        routeModelIDs.append(fallbackModelId)
    }

    var candidates: [SummaryRouteCandidate] = []
    for modelID in routeModelIDs {
        guard let model = modelsByID[modelID] else { continue }
        guard let provider = providersByID[model.providerProfileId] else { continue }
        let apiKey = try credentialStore.readSecret(for: provider.apiKeyRef)
        candidates.append(SummaryRouteCandidate(provider: provider, model: model, apiKey: apiKey))
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
            candidates.append(SummaryRouteCandidate(provider: provider, model: fallbackModel, apiKey: apiKey))
        }
    }

    guard candidates.isEmpty == false else {
        throw AISummaryExecutionError.noUsableModelRoute
    }
    return candidates
}

private extension AppModel {
    func recordSummaryTerminalRun(
        entryId: Int64,
        status: AITaskRunStatus,
        context: SummaryExecutionFailureContext,
        targetLanguage: String,
        durationMs: Int
    ) async throws {
        let snapshot = try encodeSummaryRuntimeSnapshot(context.runtimeSnapshot)
        let now = Date()
        try await database.write { db in
            var run = AITaskRun(
                id: nil,
                entryId: entryId,
                taskType: .summary,
                status: status,
                assistantProfileId: nil,
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
}

private func encodeSummaryRuntimeSnapshot(_ snapshot: [String: String]) throws -> String? {
    guard snapshot.isEmpty == false else {
        return nil
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(snapshot)
    return String(data: data, encoding: .utf8)
}
