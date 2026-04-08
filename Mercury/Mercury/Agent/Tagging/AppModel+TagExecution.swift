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

enum TaggingPanelNotice: Sendable, Equatable {
    case promptTemplateFallback(TemplateCustomizationFallbackReason)
}

enum TaggingPanelEvent: Sendable {
    case started(UUID)
    case notice(TaggingPanelNotice)
    // Resolved tag names (existing canonical names or preserved-display new proposals).
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
    let providerProfileId: Int64?
    let modelProfileId: Int64?
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

        let taskKind = AppTaskKind.tagging
        let taskTitle = taskKind.displayTitle
        let resolvedTaskID = makeTaskID()
        activeTaggingPanelTaskIds[request.entryId] = resolvedTaskID

        _ = await enqueueTask(
            taskId: resolvedTaskID,
            kind: taskKind,
            title: taskTitle,
            priority: .userInitiated,
            executionTimeout: TaskTimeoutPolicy.executionTimeout(for: taskKind)
        ) { [self, database, credentialStore] executionContext in
            let report = executionContext.reportProgress
            try Task.checkCancellation()

            let startedAt = Date()
            do {
                let configuration = try await self.refreshAgentConfigurationSnapshot()
                let taggingDefaults = configuration.taggingDefaults
                let template = try await loadResolvedPromptTemplate(context: .tagging) { reason in
                    await onEvent(.notice(.promptTemplateFallback(reason)))
                }

                let success = try await runTaggingPanelExecution(
                    request: request,
                    template: template,
                    defaults: taggingDefaults,
                    availableModels: configuration.models,
                    availableProviders: configuration.providers,
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
                        templateId: AgentPromptCustomizationConfig.tagging.templateID,
                        templateVersion: "v2",
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
                        templateId: AgentPromptCustomizationConfig.tagging.templateID,
                        templateVersion: "v2",
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
    template: AgentPromptTemplate,
    defaults: TaggingAgentDefaults,
    availableModels: [AgentModelProfile],
    availableProviders: [AgentProviderProfile],
    database: DatabaseManager,
    credentialStore: CredentialStore,
    cancellationReasonProvider: @escaping AppTaskTerminationReasonProvider
) async throws -> TaggingExecutionSuccess {
    let profile = TaggingLLMRequestProfile(
        templateID: template.id,
        templateVersion: template.version,
        maxTagCount: TaggingPolicy.maxAIRecommendations,
        maxNewTagCount: TaggingPolicy.maxNewTagProposalsPerEntry,
        bodyStrategy: .readabilityPrefix(800),
        timeoutSeconds: TaskTimeoutPolicy.executionTimeout(for: AppTaskKind.tagging) ?? 60,
        temperatureOverride: nil,
        topPOverride: nil
    )

    let result = try await executeTaggingPerEntry(
        entryId: request.entryId,
        title: request.title,
        body: request.body,
        template: template,
        profile: profile,
        defaults: defaults,
        availableModels: availableModels,
        availableProviders: availableProviders,
        taskKind: .tagging,
        database: database,
        credentialStore: credentialStore,
        cancellationReasonProvider: cancellationReasonProvider
    )

    return TaggingExecutionSuccess(
        providerProfileId: result.providerProfileId,
        modelProfileId: result.modelProfileId,
        templateId: template.id,
        templateVersion: template.version,
        resolvedTagNames: result.resolvedDisplayNames,
        runtimeSnapshot: [
            "providerProfileId": String(result.providerProfileId ?? 0),
            "modelProfileId": String(result.modelProfileId ?? 0),
            "rawTagCount": String(result.parsedNames.count),
            "resolvedTagCount": String(result.resolvedDisplayNames.count),
            "durationMs": String(result.durationMs)
        ]
    )
}
