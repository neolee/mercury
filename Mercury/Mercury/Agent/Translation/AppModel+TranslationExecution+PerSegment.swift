import Foundation

enum TranslationInternalRunEvent: Sendable {
    case segmentCompleted(sourceSegmentId: String, translatedText: String)
    case token(String)
}

enum TranslationSegmentProviderFailureKind: Sendable {
    case invalidConfiguration
    case network
    case timedOut
    case unauthorized
    case unknown
}

enum TranslationSegmentFailure: Sendable {
    case cancelled
    case rateLimited(details: String)
    case translation(TranslationExecutionError)
    case provider(kind: TranslationSegmentProviderFailureKind, message: String)
    case unknown(message: String)
}

struct TranslationSegmentExecutionResult: Sendable {
    let sourceSegmentId: String
    let translatedText: String?
    let route: TranslationResolvedRoute?
    let requestCount: Int
    let failure: TranslationSegmentFailure?
    let wasCancelled: Bool
}

func runPerSegmentExecution(
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
    guard orderedSegments.isEmpty == false else {
        throw TranslationExecutionError.sourceSegmentsRequired
    }
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
    orderedSegments: [TranslationSourceSegment],
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
    segment: TranslationSourceSegment,
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
