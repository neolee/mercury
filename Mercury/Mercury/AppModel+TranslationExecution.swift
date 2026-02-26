import Foundation
import GRDB

struct TranslationRunRequest: Sendable {
    let entryId: Int64
    let targetLanguage: String
    let sourceSnapshot: ReaderSourceSegmentsSnapshot
}

enum TranslationRunEvent: Sendable {
    case started(UUID)
    case notice(String)
    case segmentCompleted(sourceSegmentId: String, translatedText: String)
    case token(String)
    case persisting
    case terminal(TaskTerminalOutcome)
}

private struct TranslationExecutionSuccess: Sendable {
    let providerProfileId: Int64
    let modelProfileId: Int64
    let templateId: String
    let templateVersion: String
    let translatedSegments: [TranslationPersistedSegmentInput]
    let failedSegmentIDs: [String]
    let runtimeSnapshot: [String: String]
}

private struct TranslationExecutionCancelledWithPartialError: Error {
    let success: TranslationExecutionSuccess
}

private struct TranslationResolvedRoute: Sendable {
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
        sourceSegments: [ReaderSourceSegment],
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
        if raw <= 0 {
            return TranslationSettingsKey.defaultConcurrencyDegree
        }
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
            var loadedTemplateId = TranslationPromptCustomization.templateID
            var loadedTemplateVersion = "unknown"
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
                    durationMs: durationMs
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
                        durationMs: durationMs
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
}

private enum TranslationInternalRunEvent: Sendable {
    case segmentCompleted(sourceSegmentId: String, translatedText: String)
    case token(String)
}

private enum TranslationSegmentProviderFailureKind: Sendable {
    case invalidConfiguration
    case network
    case timedOut
    case unauthorized
    case unknown
}

private enum TranslationSegmentFailure: Sendable {
    case cancelled
    case rateLimited(details: String)
    case translation(TranslationExecutionError)
    case provider(kind: TranslationSegmentProviderFailureKind, message: String)
    case unknown(message: String)
}

private struct TranslationSegmentExecutionResult: Sendable {
    let sourceSegmentId: String
    let translatedText: String?
    let route: TranslationResolvedRoute?
    let requestCount: Int
    let failure: TranslationSegmentFailure?
    let wasCancelled: Bool
}

private func runPerSegmentExecution(
    request: TranslationRunRequest,
    template: AgentPromptTemplate,
    defaults: TranslationAgentDefaults,
    database: DatabaseManager,
    credentialStore: CredentialStore,
    cancellationReasonProvider: @escaping AppTaskTerminationReasonProvider,
    onEvent: @escaping @Sendable (TranslationInternalRunEvent) async -> Void
) async throws -> TranslationExecutionSuccess {
    let targetLanguage = TranslationExecutionSupport.normalizeTargetLanguage(request.targetLanguage)
    guard targetLanguage.isEmpty == false else {
        throw TranslationExecutionError.targetLanguageRequired
    }
    guard request.sourceSnapshot.segments.isEmpty == false else {
        throw TranslationExecutionError.sourceSegmentsRequired
    }

    let candidates = try await resolveAgentRouteCandidates(
        taskType: .translation,
        primaryModelId: defaults.primaryModelId,
        fallbackModelId: defaults.fallbackModelId,
        database: database,
        credentialStore: credentialStore
    )
    let attemptRouteIndices = TranslationExecutionSupport.perSegmentAttemptRouteIndices(
        candidateCount: candidates.count
    )
    guard attemptRouteIndices.isEmpty == false else {
        throw TranslationExecutionError.noUsableModelRoute
    }

    let orderedSegments = request.sourceSnapshot.segments
        .sorted(by: { $0.orderIndex < $1.orderIndex })
    let concurrencyDegree = TranslationExecutionSupport.normalizeConcurrencyDegree(defaults.concurrencyDegree)

    var translatedBySegmentID: [String: String] = [:]
    var failedSegmentIDs = Set<String>()
    var totalRequestCount = 0
    var firstSuccessfulRoute: TranslationResolvedRoute?
    var lastFailure: TranslationSegmentFailure?
    var cancellationObserved = false
    var nextIndex = 0

    await withTaskGroup(of: TranslationSegmentExecutionResult.self) { group in
        let initialCount = min(concurrencyDegree, orderedSegments.count)
        for _ in 0..<initialCount {
            let index = nextIndex
            nextIndex += 1
            enqueueSegmentTask(
                group: &group,
                index: index,
                orderedSegments: orderedSegments,
                entryId: request.entryId,
                targetLanguage: targetLanguage,
                candidates: candidates,
                attemptRouteIndices: attemptRouteIndices,
                template: template,
                database: database,
                cancellationReasonProvider: cancellationReasonProvider,
                onEvent: onEvent
            )
        }

        while let result = await group.next() {
            totalRequestCount += result.requestCount

            if let translatedText = result.translatedText {
                translatedBySegmentID[result.sourceSegmentId] = translatedText
                failedSegmentIDs.remove(result.sourceSegmentId)
                if firstSuccessfulRoute == nil, let route = result.route {
                    firstSuccessfulRoute = route
                }
            } else {
                failedSegmentIDs.insert(result.sourceSegmentId)
                if let failure = result.failure {
                    lastFailure = failure
                }
                if result.wasCancelled {
                    cancellationObserved = true
                }
            }

            if Task.isCancelled {
                cancellationObserved = true
                group.cancelAll()
            }

            if nextIndex < orderedSegments.count {
                let index = nextIndex
                nextIndex += 1
                enqueueSegmentTask(
                    group: &group,
                    index: index,
                    orderedSegments: orderedSegments,
                    entryId: request.entryId,
                    targetLanguage: targetLanguage,
                    candidates: candidates,
                    attemptRouteIndices: attemptRouteIndices,
                    template: template,
                    database: database,
                    cancellationReasonProvider: cancellationReasonProvider,
                    onEvent: onEvent
                )
            }
        }
    }

    let translatedSegmentIDs = Set(translatedBySegmentID.keys)
    let allSegmentIDs = Set(orderedSegments.map(\.sourceSegmentId))
    failedSegmentIDs.formUnion(allSegmentIDs.subtracting(translatedSegmentIDs))

    if cancellationObserved {
        guard translatedBySegmentID.isEmpty == false else {
            throw CancellationError()
        }
        let translatedSegments = try TranslationExecutionSupport.buildPersistedSegments(
            sourceSegments: orderedSegments,
            translatedBySegmentID: translatedBySegmentID
        )
        guard translatedSegments.isEmpty == false else {
            throw CancellationError()
        }
        guard let route = firstSuccessfulRoute else {
            throw CancellationError()
        }
        let success = TranslationExecutionSuccess(
            providerProfileId: route.providerProfileId,
            modelProfileId: route.modelProfileId,
            templateId: template.id,
            templateVersion: template.version,
            translatedSegments: translatedSegments,
            failedSegmentIDs: Array(failedSegmentIDs).sorted(),
            runtimeSnapshot: [
                "targetLanguage": targetLanguage,
                "routeIndex": String(route.routeIndex),
                "providerProfileId": String(route.providerProfileId),
                "modelProfileId": String(route.modelProfileId),
                "concurrencyDegree": String(concurrencyDegree),
                "requestCount": String(totalRequestCount),
                "segmentCount": String(orderedSegments.count),
                "translatedSegmentCount": String(translatedSegments.count),
                "failedSegmentCount": String(failedSegmentIDs.count),
                "sourceContentHash": request.sourceSnapshot.sourceContentHash,
                "segmenterVersion": request.sourceSnapshot.segmenterVersion
            ]
        )
        throw TranslationExecutionCancelledWithPartialError(success: success)
    }

    let translatedSegments = try TranslationExecutionSupport.buildPersistedSegments(
        sourceSegments: orderedSegments,
        translatedBySegmentID: translatedBySegmentID
    )
    guard translatedSegments.isEmpty == false else {
        if let lastFailure {
            throw translationError(from: lastFailure)
        }
        throw TranslationExecutionError.invalidModelResponse
    }
    guard let route = firstSuccessfulRoute else {
        throw TranslationExecutionError.invalidModelResponse
    }

    return TranslationExecutionSuccess(
        providerProfileId: route.providerProfileId,
        modelProfileId: route.modelProfileId,
        templateId: template.id,
        templateVersion: template.version,
        translatedSegments: translatedSegments,
        failedSegmentIDs: Array(failedSegmentIDs).sorted(),
        runtimeSnapshot: [
            "targetLanguage": targetLanguage,
            "routeIndex": String(route.routeIndex),
            "providerProfileId": String(route.providerProfileId),
            "modelProfileId": String(route.modelProfileId),
            "concurrencyDegree": String(concurrencyDegree),
            "requestCount": String(totalRequestCount),
            "segmentCount": String(orderedSegments.count),
            "translatedSegmentCount": String(translatedSegments.count),
            "failedSegmentCount": String(failedSegmentIDs.count),
            "sourceContentHash": request.sourceSnapshot.sourceContentHash,
            "segmenterVersion": request.sourceSnapshot.segmenterVersion
        ]
    )
}

private func enqueueSegmentTask(
    group: inout TaskGroup<TranslationSegmentExecutionResult>,
    index: Int,
    orderedSegments: [ReaderSourceSegment],
    entryId: Int64,
    targetLanguage: String,
    candidates: [AgentRouteCandidate],
    attemptRouteIndices: [Int],
    template: AgentPromptTemplate,
    database: DatabaseManager,
    cancellationReasonProvider: @escaping AppTaskTerminationReasonProvider,
    onEvent: @escaping @Sendable (TranslationInternalRunEvent) async -> Void
) {
    let segment = orderedSegments[index]
    let previousSourceText: String?
    if index > 0 {
        previousSourceText = orderedSegments[index - 1].sourceText
    } else {
        previousSourceText = nil
    }

    group.addTask {
        await executeSingleTranslationSegment(
            segment: segment,
            previousSourceText: previousSourceText,
            entryId: entryId,
            targetLanguage: targetLanguage,
            candidates: candidates,
            attemptRouteIndices: attemptRouteIndices,
            template: template,
            database: database,
            cancellationReasonProvider: cancellationReasonProvider,
            onEvent: onEvent
        )
    }
}

private func executeSingleTranslationSegment(
    segment: ReaderSourceSegment,
    previousSourceText: String?,
    entryId: Int64,
    targetLanguage: String,
    candidates: [AgentRouteCandidate],
    attemptRouteIndices: [Int],
    template: AgentPromptTemplate,
    database: DatabaseManager,
    cancellationReasonProvider: @escaping AppTaskTerminationReasonProvider,
    onEvent: @escaping @Sendable (TranslationInternalRunEvent) async -> Void
) async -> TranslationSegmentExecutionResult {
    var requestCount = 0
    var lastFailure: TranslationSegmentFailure?

    for routeIndex in attemptRouteIndices {
        if Task.isCancelled {
            return TranslationSegmentExecutionResult(
                sourceSegmentId: segment.sourceSegmentId,
                translatedText: nil,
                route: nil,
                requestCount: requestCount,
                failure: .cancelled,
                wasCancelled: true
            )
        }

        let candidate = candidates[routeIndex]
        do {
            let route = try resolveRoute(candidate: candidate, routeIndex: routeIndex)
            requestCount += 1
            let responseText = try await performTranslationModelRequest(
                entryId: entryId,
                targetLanguage: targetLanguage,
                sourceText: segment.sourceText,
                previousSourceText: previousSourceText,
                candidate: candidate,
                template: template,
                database: database,
                cancellationReasonProvider: cancellationReasonProvider,
                onToken: { token in
                    await onEvent(.token(token))
                }
            )
            guard let translatedText = TranslationExecutionSupport.normalizedModelTranslationOutput(responseText) else {
                throw TranslationExecutionError.invalidModelResponse
            }
            await onEvent(
                .segmentCompleted(
                    sourceSegmentId: segment.sourceSegmentId,
                    translatedText: translatedText
                )
            )
            return TranslationSegmentExecutionResult(
                sourceSegmentId: segment.sourceSegmentId,
                translatedText: translatedText,
                route: route,
                requestCount: requestCount,
                failure: nil,
                wasCancelled: false
            )
        } catch {
            let failure = translationSegmentFailure(from: error)
            if case .cancelled = failure {
                return TranslationSegmentExecutionResult(
                    sourceSegmentId: segment.sourceSegmentId,
                    translatedText: nil,
                    route: nil,
                    requestCount: requestCount,
                    failure: failure,
                    wasCancelled: true
                )
            }
            lastFailure = failure
        }
    }

    return TranslationSegmentExecutionResult(
        sourceSegmentId: segment.sourceSegmentId,
        translatedText: nil,
        route: nil,
        requestCount: requestCount,
        failure: lastFailure ?? .translation(.invalidModelResponse),
        wasCancelled: false
    )
}

private func translationSegmentFailure(from error: Error) -> TranslationSegmentFailure {
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

private func translationError(from failure: TranslationSegmentFailure) -> Error {
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

private func resolveRoute(candidate: AgentRouteCandidate, routeIndex: Int) throws -> TranslationResolvedRoute {
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

private func performTranslationModelRequest(
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
