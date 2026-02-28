import Foundation
import GRDB

struct TranslationRunRequest: Sendable {
    let entryId: Int64
    let targetLanguage: String
    let sourceSnapshot: TranslationSourceSegmentsSnapshot
}

enum TranslationRunEvent: Sendable {
    case started(UUID)
    case notice(String)
    case segmentCompleted(sourceSegmentId: String, translatedText: String)
    case token(String)
    case persisting
    case terminal(TaskTerminalOutcome)
}

struct TranslationExecutionSuccess: Sendable {
    let providerProfileId: Int64
    let modelProfileId: Int64
    let templateId: String
    let templateVersion: String
    let translatedSegments: [TranslationPersistedSegmentInput]
    let failedSegmentIDs: [String]
    let runtimeSnapshot: [String: String]
}

struct TranslationExecutionCancelledWithPartialError: Error {
    let success: TranslationExecutionSuccess
}

struct TranslationResolvedRoute: Sendable {
    let providerProfileId: Int64
    let modelProfileId: Int64
    let routeIndex: Int
}

enum TranslationExecutionError: LocalizedError, Sendable {
    case sourceSegmentsRequired
    case targetLanguageRequired
    case noUsableModelRoute
    case invalidBaseURL(String)
    case invalidModelResponse
    case executionTimedOut(seconds: Int)
    case missingTranslatedSegment(sourceSegmentId: String)
    case emptyTranslatedSegment(sourceSegmentId: String)
    case duplicateTranslatedSegment(sourceSegmentId: String)
    case rateLimited(details: String)

    var errorDescription: String? {
        switch self {
        case .sourceSegmentsRequired:
            return "Translation source segments are required."
        case .targetLanguageRequired:
            return "Target language is required."
        case .noUsableModelRoute:
            return "No usable translation model route is configured. Please check model/provider settings."
        case .invalidBaseURL(let raw):
            return "Invalid provider base URL: \(raw)"
        case .invalidModelResponse:
            return "Model response cannot be parsed into translation segments."
        case .executionTimedOut(let seconds):
            return "Translation request timed out after \(seconds) seconds."
        case .missingTranslatedSegment(let sourceSegmentId):
            return "Missing translated segment for \(sourceSegmentId)."
        case .emptyTranslatedSegment(let sourceSegmentId):
            return "Translated segment is empty for \(sourceSegmentId)."
        case .duplicateTranslatedSegment(let sourceSegmentId):
            return "Duplicate translated segment in model output for \(sourceSegmentId)."
        case .rateLimited(let details):
            return "Rate limit reached (HTTP 429). \(details)"
        }
    }
}

enum TranslationExecutionSupport {
    static func buildPersistedSegments(
        sourceSegments: [TranslationSourceSegment],
        translatedBySegmentID: [String: String]
    ) throws -> [TranslationPersistedSegmentInput] {
        let orderedSource = sourceSegments.sorted { lhs, rhs in lhs.orderIndex < rhs.orderIndex }
        var persisted: [TranslationPersistedSegmentInput] = []
        persisted.reserveCapacity(orderedSource.count)

        for source in orderedSource {
            guard let translatedText = translatedBySegmentID[source.sourceSegmentId] else {
                continue
            }
            let normalized = translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalized.isEmpty == false else {
                continue
            }
            persisted.append(
                TranslationPersistedSegmentInput(
                    sourceSegmentId: source.sourceSegmentId,
                    orderIndex: source.orderIndex,
                    sourceTextSnapshot: source.sourceText,
                    translatedText: normalized
                )
            )
        }

        return persisted
    }

    static func normalizeTargetLanguage(_ raw: String) -> String {
        AgentLanguageOption.normalizeCode(raw)
    }

    static func normalizeConcurrencyDegree(_ raw: Int) -> Int {
        return min(
            max(raw, TranslationSettingsKey.concurrencyRange.lowerBound),
            TranslationSettingsKey.concurrencyRange.upperBound
        )
    }

    static func perSegmentAttemptRouteIndices(candidateCount: Int) -> [Int] {
        guard candidateCount > 0 else { return [] }
        if candidateCount == 1 {
            return [0]
        }
        return [0, 1]
    }

    static func normalizedModelTranslationOutput(_ rawOutput: String) -> String? {
        let normalized = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else {
            return nil
        }
        return normalized
    }

    static func rateLimitGuidance(from error: Error) -> String {
        let message = error.localizedDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if message.isEmpty {
            return "Reduce translation concurrency, switch model/provider tier, then retry later."
        }
        return "\(message) Reduce translation concurrency, switch model/provider tier, then retry later."
    }

    static func promptWithOptionalPreviousContext(
        basePrompt: String,
        previousSourceText: String?
    ) -> String {
        let normalizedBase = basePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let previousSourceText else {
            return normalizedBase
        }
        let normalizedPrevious = previousSourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedPrevious.isEmpty == false else {
            return normalizedBase
        }
        return """
        Context (preceding paragraph, do not translate):
        \(normalizedPrevious)

        \(normalizedBase)
        """
    }
}

extension AppModel {
    func startTranslationRun(
        request: TranslationRunRequest,
        requestedTaskId: UUID? = nil,
        onEvent: @escaping @Sendable (TranslationRunEvent) async -> Void
    ) async -> UUID {
        let normalizedTargetLanguage = TranslationExecutionSupport.normalizeTargetLanguage(request.targetLanguage)
        let defaults = loadTranslationAgentDefaults()
        let resolvedTaskID = requestedTaskId ?? makeTaskID()

        let taskId = await enqueueTask(
            taskId: resolvedTaskID,
            kind: .translation,
            title: "Translation",
            priority: .userInitiated,
            executionTimeout: TaskTimeoutPolicy.executionTimeout(for: AppTaskKind.translation)
        ) { [self, database, credentialStore] (executionContext: AppTaskExecutionContext) in
            let report = executionContext.reportProgress
            try Task.checkCancellation()
            await report(0, "Preparing translation")

            let startedAt = Date()
            let sourceSegmentsByID = Dictionary(
                request.sourceSnapshot.segments.map { ($0.sourceSegmentId, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            var loadedTemplateId = TranslationPromptCustomization.templateID
            var loadedTemplateVersion = "unknown"
            var checkpointTaskRunIdForFailureHandling: Int64?
            do {
                var invalidCustomTemplateDetail: String?
                let template = try TranslationPromptCustomization.loadTranslationTemplate(
                    onInvalidCustomTemplate: { customURL, error in
                        invalidCustomTemplateDetail = [
                            "path=\(customURL.path)",
                            "error=\(error.localizedDescription)",
                            "action=fallback_to_built_in_template"
                        ].joined(separator: "\n")
                    }
                )
                loadedTemplateId = template.id
                loadedTemplateVersion = template.version
                if let invalidCustomTemplateDetail {
                    let fallbackMessage = await MainActor.run {
                        AgentRuntimeProjection.translationInvalidCustomPromptFallbackStatus()
                    }
                    await MainActor.run {
                        self.reportDebugIssue(
                            title: "Translation Prompt Customization Invalid",
                            detail: invalidCustomTemplateDetail,
                            category: .task
                        )
                    }
                    await onEvent(.notice(fallbackMessage))
                }

                checkpointTaskRunIdForFailureHandling = await self.startTranslationCheckpointRunSafely(
                    entryId: request.entryId,
                    normalizedTargetLanguage: normalizedTargetLanguage,
                    sourceSnapshot: request.sourceSnapshot,
                    template: template,
                    taskId: resolvedTaskID
                )
                let checkpointTaskRunId = checkpointTaskRunIdForFailureHandling

                let success = try await runPerSegmentExecution(
                    request: TranslationRunRequest(
                        entryId: request.entryId,
                        targetLanguage: normalizedTargetLanguage,
                        sourceSnapshot: request.sourceSnapshot
                    ),
                    template: template,
                    defaults: defaults,
                    database: database,
                    credentialStore: credentialStore,
                    cancellationReasonProvider: executionContext.terminationReason
                ) { event in
                    switch event {
                    case .segmentCompleted(let sourceSegmentId, let translatedText):
                        await onEvent(
                            .segmentCompleted(
                                sourceSegmentId: sourceSegmentId,
                                translatedText: translatedText
                            )
                        )
                        if let checkpointTaskRunId,
                           let sourceSegment = sourceSegmentsByID[sourceSegmentId] {
                            do {
                                try await self.persistTranslationSegmentCheckpoint(
                                    taskRunId: checkpointTaskRunId,
                                    segment: TranslationPersistedSegmentInput(
                                        sourceSegmentId: sourceSegmentId,
                                        orderIndex: sourceSegment.orderIndex,
                                        sourceTextSnapshot: sourceSegment.sourceText,
                                        translatedText: translatedText
                                    )
                                )
                            } catch {
                                await MainActor.run {
                                    self.reportDebugIssue(
                                        title: "Translation Checkpoint Segment Persist Failed",
                                        detail: "entryId=\(request.entryId)\nsegmentId=\(sourceSegmentId)\nreason=\(error.localizedDescription)",
                                        category: .task
                                    )
                                }
                            }
                        }
                    case .token(let token):
                        await onEvent(.token(token))
                    }
                }

                let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                await onEvent(.persisting)
                var runtimeSnapshot = success.runtimeSnapshot
                runtimeSnapshot["taskId"] = resolvedTaskID.uuidString
                let stored = try await persistSuccessfulTranslationResult(
                    entryId: request.entryId,
                    agentProfileId: nil,
                    providerProfileId: success.providerProfileId,
                    modelProfileId: success.modelProfileId,
                    promptVersion: "\(success.templateId)@\(success.templateVersion)",
                    targetLanguage: normalizedTargetLanguage,
                    sourceContentHash: request.sourceSnapshot.sourceContentHash,
                    segmenterVersion: request.sourceSnapshot.segmenterVersion,
                    outputLanguage: normalizedTargetLanguage,
                    segments: success.translatedSegments,
                    templateId: success.templateId,
                    templateVersion: success.templateVersion,
                    runtimeParameterSnapshot: runtimeSnapshot,
                    durationMs: durationMs,
                    checkpointTaskRunId: checkpointTaskRunId
                )
                if let runID = stored.run.id {
                    try? await linkRecentUsageEventsToTaskRun(
                        database: database,
                        taskRunId: runID,
                        entryId: request.entryId,
                        taskType: .translation,
                        startedAt: startedAt,
                        finishedAt: Date()
                    )
                }

                await report(1, "Translation completed")
                await onEvent(.terminal(.succeeded))
            } catch {
                if let partialCancellation = error as? TranslationExecutionCancelledWithPartialError {
                    let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                    await onEvent(.persisting)
                    var runtimeSnapshot = partialCancellation.success.runtimeSnapshot
                    runtimeSnapshot["taskId"] = resolvedTaskID.uuidString
                    runtimeSnapshot["cancelledWithPartialResult"] = "true"
                    runtimeSnapshot["failedSegmentCount"] = String(partialCancellation.success.failedSegmentIDs.count)
                    runtimeSnapshot["translatedSegmentCount"] = String(partialCancellation.success.translatedSegments.count)
                    let stored = try await persistSuccessfulTranslationResult(
                        entryId: request.entryId,
                        agentProfileId: nil,
                        providerProfileId: partialCancellation.success.providerProfileId,
                        modelProfileId: partialCancellation.success.modelProfileId,
                        promptVersion: "\(partialCancellation.success.templateId)@\(partialCancellation.success.templateVersion)",
                        targetLanguage: normalizedTargetLanguage,
                        sourceContentHash: request.sourceSnapshot.sourceContentHash,
                        segmenterVersion: request.sourceSnapshot.segmenterVersion,
                        outputLanguage: normalizedTargetLanguage,
                        segments: partialCancellation.success.translatedSegments,
                        templateId: partialCancellation.success.templateId,
                        templateVersion: partialCancellation.success.templateVersion,
                        runtimeParameterSnapshot: runtimeSnapshot,
                        durationMs: durationMs,
                        checkpointTaskRunId: checkpointTaskRunIdForFailureHandling
                    )
                    if let runID = stored.run.id {
                        try? await linkRecentUsageEventsToTaskRun(
                            database: database,
                            taskRunId: runID,
                            entryId: request.entryId,
                            taskType: .translation,
                            startedAt: startedAt,
                            finishedAt: Date()
                        )
                    }

                    let terminationReason = await executionContext.terminationReason()
                    try await handleAgentCancellation(
                        database: database,
                        startedAt: startedAt,
                        entryId: request.entryId,
                        taskType: .translation,
                        taskKind: .translation,
                        targetLanguage: normalizedTargetLanguage,
                        templateId: partialCancellation.success.templateId,
                        templateVersion: partialCancellation.success.templateVersion,
                        runtimeSnapshotBase: runtimeSnapshot,
                        failedDebugTitle: "Translation Failed",
                        cancelledDebugTitle: "Translation Cancelled",
                        cancelledDebugDetail: "entryId=\(request.entryId)\ntargetLanguage=\(normalizedTargetLanguage)\ntranslatedSegmentCount=\(partialCancellation.success.translatedSegments.count)\nfailedSegmentCount=\(partialCancellation.success.failedSegmentIDs.count)",
                        reportFailureMessage: "Translation failed",
                        report: report,
                        terminationReason: terminationReason,
                        onTerminal: { outcome in
                            await onEvent(.terminal(outcome))
                        }
                    )
                } else if isCancellationLikeError(error) {
                    if let checkpointTaskRunId = checkpointTaskRunIdForFailureHandling {
                        _ = try? await discardRunningTranslationCheckpoint(taskRunId: checkpointTaskRunId)
                    }
                    let terminationReason = await executionContext.terminationReason()
                    try await handleAgentCancellation(
                        database: database,
                        startedAt: startedAt,
                        entryId: request.entryId,
                        taskType: .translation,
                        taskKind: .translation,
                        targetLanguage: normalizedTargetLanguage,
                        templateId: loadedTemplateId,
                        templateVersion: loadedTemplateVersion,
                        runtimeSnapshotBase: [
                            "taskId": resolvedTaskID.uuidString,
                            "targetLanguage": normalizedTargetLanguage,
                            "sourceContentHash": request.sourceSnapshot.sourceContentHash,
                            "segmenterVersion": request.sourceSnapshot.segmenterVersion,
                            "templateId": loadedTemplateId,
                            "templateVersion": loadedTemplateVersion
                        ],
                        failedDebugTitle: "Translation Failed",
                        cancelledDebugTitle: "Translation Cancelled",
                        cancelledDebugDetail: "entryId=\(request.entryId)\ntargetLanguage=\(normalizedTargetLanguage)",
                        reportFailureMessage: "Translation failed",
                        report: report,
                        terminationReason: terminationReason,
                        onTerminal: { outcome in
                            await onEvent(.terminal(outcome))
                        }
                    )
                } else {
                    if let checkpointTaskRunId = checkpointTaskRunIdForFailureHandling {
                        _ = try? await discardRunningTranslationCheckpoint(taskRunId: checkpointTaskRunId)
                    }
                    await handleAgentFailure(
                        database: database,
                        startedAt: startedAt,
                        entryId: request.entryId,
                        taskType: .translation,
                        taskKind: .translation,
                        targetLanguage: normalizedTargetLanguage,
                        templateId: loadedTemplateId,
                        templateVersion: loadedTemplateVersion,
                        runtimeSnapshotBase: [
                            "taskId": resolvedTaskID.uuidString,
                            "targetLanguage": normalizedTargetLanguage,
                            "sourceContentHash": request.sourceSnapshot.sourceContentHash,
                            "segmenterVersion": request.sourceSnapshot.segmenterVersion,
                            "templateId": loadedTemplateId,
                            "templateVersion": loadedTemplateVersion
                        ],
                        failedDebugTitle: "Translation Failed",
                        reportFailureMessage: "Translation failed",
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

    func startTranslationCheckpointRunSafely(
        entryId: Int64,
        normalizedTargetLanguage: String,
        sourceSnapshot: TranslationSourceSegmentsSnapshot,
        template: AgentPromptTemplate,
        taskId: UUID
    ) async -> Int64? {
        let runtimeSnapshot: [String: String] = [
            "taskId": taskId.uuidString,
            "targetLanguage": normalizedTargetLanguage,
            "sourceContentHash": sourceSnapshot.sourceContentHash,
            "segmenterVersion": sourceSnapshot.segmenterVersion,
            "templateId": template.id,
            "templateVersion": template.version
        ]

        do {
            return try await startTranslationRunForCheckpoint(
                entryId: entryId,
                agentProfileId: nil,
                providerProfileId: nil,
                modelProfileId: nil,
                promptVersion: "\(template.id)@\(template.version)",
                targetLanguage: normalizedTargetLanguage,
                sourceContentHash: sourceSnapshot.sourceContentHash,
                segmenterVersion: sourceSnapshot.segmenterVersion,
                outputLanguage: normalizedTargetLanguage,
                templateId: template.id,
                templateVersion: template.version,
                runtimeParameterSnapshot: runtimeSnapshot,
                durationMs: nil
            )
        } catch {
            await MainActor.run {
                self.reportDebugIssue(
                    title: "Translation Checkpoint Start Failed",
                    detail: "entryId=\(entryId)\ntargetLanguage=\(normalizedTargetLanguage)\nreason=\(error.localizedDescription)",
                    category: .task
                )
            }
            return nil
        }
    }
}
