import Foundation
import GRDB

struct AITranslationRunRequest: Sendable {
    let entryId: Int64
    let targetLanguage: String
    let sourceSnapshot: ReaderSourceSegmentsSnapshot
}

enum AITranslationRunEvent: Sendable {
    case started(UUID)
    case strategySelected(AITranslationRequestStrategy)
    case token(String)
    case persisting
    case completed
    case failed(String, AgentFailureReason)
    case cancelled
}

private struct TranslationRouteCandidate: Sendable {
    let provider: AIProviderProfile
    let model: AIModelProfile
    let apiKey: String
}

private struct AITranslationExecutionSuccess: Sendable {
    let providerProfileId: Int64
    let modelProfileId: Int64
    let templateId: String
    let templateVersion: String
    let strategy: AITranslationRequestStrategy
    let requestCount: Int
    let translatedSegments: [AITranslationPersistedSegmentInput]
    let runtimeSnapshot: [String: String]
}

private struct AITranslationExecutionFailureContext: Sendable {
    let providerProfileId: Int64?
    let modelProfileId: Int64?
    let templateId: String?
    let templateVersion: String?
    let runtimeSnapshot: [String: String]
}

private struct AITranslationResolvedRoute: Sendable {
    let providerProfileId: Int64
    let modelProfileId: Int64
    let routeIndex: Int
}

private struct AITranslationSegmentPromptPayload: Codable, Sendable {
    let sourceSegmentId: String
    let orderIndex: Int
    let segmentType: String
    let sourceText: String
}

enum AITranslationExecutionError: LocalizedError {
    case sourceSegmentsRequired
    case targetLanguageRequired
    case noUsableModelRoute
    case invalidBaseURL(String)
    case invalidModelResponse
    case executionTimedOut(seconds: Int)
    case missingTranslatedSegment(sourceSegmentId: String)
    case emptyTranslatedSegment(sourceSegmentId: String)
    case duplicateTranslatedSegment(sourceSegmentId: String)

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
        }
    }
}

enum AITranslationExecutionSupport {
    static func estimatedTokenCount(for segment: ReaderSourceSegment) -> Int {
        let normalized = segment.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let textTokens = max(1, normalized.count / 4)
        return textTokens + 12
    }

    static func estimatedTokenCount(for segments: [ReaderSourceSegment]) -> Int {
        segments.reduce(into: 0) { partial, segment in
            partial += estimatedTokenCount(for: segment)
        }
    }

    static func chooseStrategy(
        snapshot: ReaderSourceSegmentsSnapshot,
        thresholds: AITranslationThresholds = .v1
    ) -> AITranslationRequestStrategy {
        let segmentCount = snapshot.segments.count
        if segmentCount > thresholds.maxSegmentsForStrategyA {
            return .chunkedRequests
        }

        let estimatedTokens = estimatedTokenCount(for: snapshot.segments)
        if estimatedTokens > thresholds.maxEstimatedTokenBudgetForStrategyA {
            return .chunkedRequests
        }

        return .wholeArticleSingleRequest
    }

    static func chunks(
        from segments: [ReaderSourceSegment],
        chunkSize: Int
    ) -> [[ReaderSourceSegment]] {
        let safeSize = max(1, chunkSize)
        guard segments.isEmpty == false else {
            return []
        }

        var output: [[ReaderSourceSegment]] = []
        output.reserveCapacity((segments.count + safeSize - 1) / safeSize)

        var currentIndex = 0
        while currentIndex < segments.count {
            let endIndex = min(currentIndex + safeSize, segments.count)
            output.append(Array(segments[currentIndex..<endIndex]))
            currentIndex = endIndex
        }
        return output
    }

    static func tokenAwareChunks(
        from segments: [ReaderSourceSegment],
        minimumChunkSize: Int,
        targetEstimatedTokensPerChunk: Int
    ) -> [[ReaderSourceSegment]] {
        let safeMinimumChunkSize = max(1, minimumChunkSize)
        let safeTargetTokenBudget = max(1_024, targetEstimatedTokensPerChunk)
        let ordered = segments.sorted { lhs, rhs in lhs.orderIndex < rhs.orderIndex }
        guard ordered.isEmpty == false else {
            return []
        }

        var output: [[ReaderSourceSegment]] = []
        var currentChunk: [ReaderSourceSegment] = []
        var currentTokenBudget = 0

        for segment in ordered {
            let segmentTokenBudget = estimatedTokenCount(for: segment)
            let projectedBudget = currentTokenBudget + segmentTokenBudget
            let shouldFlushCurrentChunk = currentChunk.isEmpty == false
                && currentChunk.count >= safeMinimumChunkSize
                && projectedBudget > safeTargetTokenBudget
            if shouldFlushCurrentChunk {
                output.append(currentChunk)
                currentChunk = []
                currentTokenBudget = 0
            }

            currentChunk.append(segment)
            currentTokenBudget += segmentTokenBudget
        }

        if currentChunk.isEmpty == false {
            output.append(currentChunk)
        }

        return output
    }

    static func sourceSegmentsJSON(_ segments: [ReaderSourceSegment]) throws -> String {
        let payload = segments
            .sorted { lhs, rhs in lhs.orderIndex < rhs.orderIndex }
            .map {
                AITranslationSegmentPromptPayload(
                    sourceSegmentId: $0.sourceSegmentId,
                    orderIndex: $0.orderIndex,
                    segmentType: $0.segmentType.rawValue,
                    sourceText: $0.sourceText
                )
            }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        return String(decoding: data, as: UTF8.self)
    }

    static func parseTranslatedSegments(
        from rawText: String
    ) throws -> [String: String] {
        guard let jsonPayload = extractJSONPayload(from: rawText),
              let data = jsonPayload.data(using: .utf8) else {
            throw AITranslationExecutionError.invalidModelResponse
        }

        let json = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        let parsed = try parseSegmentMap(fromJSON: json)
        guard parsed.isEmpty == false else {
            throw AITranslationExecutionError.invalidModelResponse
        }
        return parsed
    }

    static func parseTranslatedSegmentsRecovering(
        from rawText: String,
        expectedSegmentIDs: Set<String>
    ) throws -> [String: String] {
        do {
            return try parseTranslatedSegments(from: rawText)
        } catch {
            let recovered = recoverSegmentMapFromLooseText(
                rawText,
                expectedSegmentIDs: expectedSegmentIDs
            )
            guard recovered.isEmpty == false else {
                throw error
            }
            return recovered
        }
    }

    static func buildPersistedSegments(
        sourceSegments: [ReaderSourceSegment],
        translatedBySegmentID: [String: String]
    ) throws -> [AITranslationPersistedSegmentInput] {
        let orderedSource = sourceSegments.sorted { lhs, rhs in lhs.orderIndex < rhs.orderIndex }
        var persisted: [AITranslationPersistedSegmentInput] = []
        persisted.reserveCapacity(orderedSource.count)

        for source in orderedSource {
            guard let translatedText = translatedBySegmentID[source.sourceSegmentId] else {
                throw AITranslationExecutionError.missingTranslatedSegment(sourceSegmentId: source.sourceSegmentId)
            }
            let normalized = translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalized.isEmpty == false else {
                throw AITranslationExecutionError.emptyTranslatedSegment(sourceSegmentId: source.sourceSegmentId)
            }
            persisted.append(
                AITranslationPersistedSegmentInput(
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
        SummaryLanguageOption.normalizeCode(raw)
    }

    private static func parseSegmentMap(fromJSON json: Any) throws -> [String: String] {
        if let dictionary = json as? [String: Any] {
            if let wrapped = dictionary["segments"] {
                return try parseSegmentMap(fromJSON: wrapped)
            }

            if let wrapped = dictionary["translations"] {
                return try parseSegmentMap(fromJSON: wrapped)
            }

            let nestedValueMap = dictionary.reduce(into: [String: String]()) { partial, pair in
                let key = pair.key.trimmingCharacters(in: .whitespacesAndNewlines)
                guard key.isEmpty == false else { return }
                if let value = pair.value as? String {
                    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard normalized.isEmpty == false else { return }
                    partial[key] = normalized
                    return
                }
                if let value = pair.value as? [String: Any],
                   let extracted = extractString(value, keys: ["translatedText", "translation", "text", "value"]) {
                    partial[key] = extracted
                }
            }
            if nestedValueMap.isEmpty == false {
                return nestedValueMap
            }

            let allStringValues = dictionary.values.allSatisfy { $0 is String }
            if allStringValues {
                return dictionary.reduce(into: [String: String]()) { partial, pair in
                    let key = pair.key.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard key.isEmpty == false else { return }
                    let value = (pair.value as? String ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard value.isEmpty == false else { return }
                    partial[key] = value
                }
            }
        }

        guard let array = json as? [Any] else {
            throw AITranslationExecutionError.invalidModelResponse
        }

        var result: [String: String] = [:]
        for item in array {
            guard let record = item as? [String: Any] else {
                throw AITranslationExecutionError.invalidModelResponse
            }
            guard let sourceSegmentId = extractString(
                record,
                keys: ["sourceSegmentId", "segmentId", "id"]
            ) else {
                throw AITranslationExecutionError.invalidModelResponse
            }
            guard let translatedText = extractString(
                record,
                keys: ["translatedText", "translation", "text", "value"]
            ) else {
                throw AITranslationExecutionError.invalidModelResponse
            }

            if result[sourceSegmentId] != nil {
                throw AITranslationExecutionError.duplicateTranslatedSegment(sourceSegmentId: sourceSegmentId)
            }
            result[sourceSegmentId] = translatedText
        }
        return result
    }

    private static func extractString(_ dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let raw = dictionary[key] as? String else { continue }
            let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalized.isEmpty == false {
                return normalized
            }
        }
        return nil
    }

    private static func recoverSegmentMapFromLooseText(
        _ rawText: String,
        expectedSegmentIDs: Set<String>
    ) -> [String: String] {
        guard expectedSegmentIDs.isEmpty == false else {
            return [:]
        }

        var recovered: [String: String] = [:]
        let lines = rawText.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else {
                continue
            }

            guard let separatorRange = firstLooseSeparatorRange(in: trimmed) else {
                continue
            }

            var rawKey = String(trimmed[..<separatorRange.lowerBound])
            var rawValue = String(trimmed[separatorRange.upperBound...])

            rawKey = stripLooseLinePrefix(rawKey)
            rawValue = normalizeLooseValue(rawValue)
            guard rawValue.isEmpty == false else {
                continue
            }

            if expectedSegmentIDs.contains(rawKey), recovered[rawKey] == nil {
                recovered[rawKey] = rawValue
            }
        }

        return recovered
    }

    private static func firstLooseSeparatorRange(in line: String) -> Range<String.Index>? {
        for separator in ["=>", "->", ":", "=", "|"] {
            if let range = line.range(of: separator) {
                return range
            }
        }
        return nil
    }

    private static func stripLooseLinePrefix(_ raw: String) -> String {
        let pattern = #"^\s*(?:[-*]\s*)?(?:\d+[\.)]\s*)?"#
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        let regex = try? NSRegularExpression(pattern: pattern, options: [])
        let stripped = regex?.stringByReplacingMatches(in: raw, options: [], range: range, withTemplate: "") ?? raw
        return stripped
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "`\"'"))
    }

    private static func normalizeLooseValue(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ","))
            .trimmingCharacters(in: CharacterSet(charactersIn: "`\"'[]*"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractJSONPayload(from rawText: String) -> String? {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return nil
        }

        if isJSONLike(trimmed) {
            return trimmed
        }

        if let stringDecoded = decodeJSONStringPayload(trimmed), isJSONLike(stringDecoded) {
            return stringDecoded
        }

        if let fenced = extractCodeFenceJSON(from: trimmed) {
            if isJSONLike(fenced) {
                return fenced
            }
            if let decodedFenced = decodeJSONStringPayload(fenced), isJSONLike(decodedFenced) {
                return decodedFenced
            }
        }

        if let extracted = extractFirstBalancedJSON(from: trimmed), isJSONLike(extracted) {
            return extracted
        }

        return nil
    }

    private static func extractCodeFenceJSON(from text: String) -> String? {
        let pattern = #"```(?:json|jsonc|javascript|js|text)?\s*([\s\S]*?)\s*```"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let bodyRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[bodyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeJSONStringPayload(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "\"", trimmed.last == "\"",
              let data = trimmed.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(String.self, from: data) else {
            return nil
        }
        let normalized = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private static func extractFirstBalancedJSON(from text: String) -> String? {
        let chars = Array(text)
        guard chars.isEmpty == false else {
            return nil
        }

        var startIndices: [Int] = []
        for (index, character) in chars.enumerated() where character == "{" || character == "[" {
            startIndices.append(index)
        }

        for start in startIndices {
            var stack: [Character] = []
            var inString = false
            var isEscaped = false

            for index in start..<chars.count {
                let character = chars[index]
                if inString {
                    if isEscaped {
                        isEscaped = false
                    } else if character == "\\" {
                        isEscaped = true
                    } else if character == "\"" {
                        inString = false
                    }
                    continue
                }

                if character == "\"" {
                    inString = true
                    continue
                }

                if character == "{" || character == "[" {
                    stack.append(character)
                    continue
                }

                if character == "}" || character == "]" {
                    guard let last = stack.last else {
                        break
                    }
                    if (last == "{" && character == "}") || (last == "[" && character == "]") {
                        stack.removeLast()
                        if stack.isEmpty {
                            return String(chars[start...index]).trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                        continue
                    }
                    break
                }
            }
        }

        return nil
    }

    private static func isJSONLike(_ text: String) -> Bool {
        guard let first = text.first, let last = text.last else {
            return false
        }
        return (first == "{" && last == "}") || (first == "[" && last == "]")
    }
}

extension AppModel {
    func startTranslationRun(
        request: AITranslationRunRequest,
        onEvent: @escaping @Sendable (AITranslationRunEvent) async -> Void
    ) async -> UUID {
        let normalizedTargetLanguage = AITranslationExecutionSupport.normalizeTargetLanguage(request.targetLanguage)
        let defaults = loadTranslationAgentDefaults()

        let taskId = await enqueueTask(
            kind: .translation,
            title: "Translation",
            priority: .userInitiated
        ) { [self, database, credentialStore] report in
            try Task.checkCancellation()
            await report(0, "Preparing translation")

            let startedAt = Date()
            do {
                let success = try await withTranslationExecutionWatchdog(seconds: AITranslationPolicy.runWatchdogTimeoutSeconds) {
                    try await runTranslationExecution(
                        request: AITranslationRunRequest(
                            entryId: request.entryId,
                            targetLanguage: normalizedTargetLanguage,
                            sourceSnapshot: request.sourceSnapshot
                        ),
                        defaults: defaults,
                        database: database,
                        credentialStore: credentialStore
                    ) { event in
                        switch event {
                        case .strategySelected(let strategy):
                            await onEvent(.strategySelected(strategy))
                        case .token(let token):
                            await onEvent(.token(token))
                        }
                    }
                }

                let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                await onEvent(.persisting)
                _ = try await persistSuccessfulTranslationResult(
                    entryId: request.entryId,
                    assistantProfileId: nil,
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
                    runtimeParameterSnapshot: success.runtimeSnapshot,
                    durationMs: durationMs
                )

                await report(1, "Translation completed")
                await onEvent(.completed)
            } catch is CancellationError {
                let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                let failureReason = AgentFailureClassifier.classify(error: CancellationError(), taskKind: .translation)
                let context = AITranslationExecutionFailureContext(
                    providerProfileId: nil,
                    modelProfileId: nil,
                    templateId: "translation.default",
                    templateVersion: "v1",
                    runtimeSnapshot: [
                        "reason": "cancelled",
                        "failureReason": failureReason.rawValue,
                        "targetLanguage": normalizedTargetLanguage,
                        "sourceContentHash": request.sourceSnapshot.sourceContentHash,
                        "segmenterVersion": request.sourceSnapshot.segmenterVersion
                    ]
                )
                try? await recordTranslationTerminalRun(
                    entryId: request.entryId,
                    status: .cancelled,
                    context: context,
                    targetLanguage: normalizedTargetLanguage,
                    durationMs: durationMs
                )
                await MainActor.run {
                    self.reportDebugIssue(
                        title: "Translation Cancelled",
                        detail: "entryId=\(request.entryId)\nfailureReason=\(failureReason.rawValue)\ntargetLanguage=\(normalizedTargetLanguage)",
                        category: .task
                    )
                }
                await onEvent(.cancelled)
                throw CancellationError()
            } catch {
                let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                let failureReason = AgentFailureClassifier.classify(error: error, taskKind: .translation)
                let context = AITranslationExecutionFailureContext(
                    providerProfileId: nil,
                    modelProfileId: nil,
                    templateId: "translation.default",
                    templateVersion: "v1",
                    runtimeSnapshot: [
                        "reason": "failed",
                        "failureReason": failureReason.rawValue,
                        "targetLanguage": normalizedTargetLanguage,
                        "sourceContentHash": request.sourceSnapshot.sourceContentHash,
                        "segmenterVersion": request.sourceSnapshot.segmenterVersion,
                        "error": error.localizedDescription
                    ]
                )
                try? await recordTranslationTerminalRun(
                    entryId: request.entryId,
                    status: .failed,
                    context: context,
                    targetLanguage: normalizedTargetLanguage,
                    durationMs: durationMs
                )
                await MainActor.run {
                    self.reportDebugIssue(
                        title: "Translation Failed",
                        detail: "entryId=\(request.entryId)\nfailureReason=\(failureReason.rawValue)\nerror=\(error.localizedDescription)",
                        category: .task
                    )
                }
                await report(nil, "Translation failed")
                await onEvent(.failed(error.localizedDescription, failureReason))
                throw error
            }
        }

        await onEvent(.started(taskId))
        return taskId
    }
}

private enum AITranslationInternalRunEvent: Sendable {
    case strategySelected(AITranslationRequestStrategy)
    case token(String)
}

private func runTranslationExecution(
    request: AITranslationRunRequest,
    defaults: TranslationAgentDefaults,
    database: DatabaseManager,
    credentialStore: CredentialStore,
    onEvent: @escaping @Sendable (AITranslationInternalRunEvent) async -> Void
) async throws -> AITranslationExecutionSuccess {
    let targetLanguage = AITranslationExecutionSupport.normalizeTargetLanguage(request.targetLanguage)
    guard targetLanguage.isEmpty == false else {
        throw AITranslationExecutionError.targetLanguageRequired
    }
    guard request.sourceSnapshot.segments.isEmpty == false else {
        throw AITranslationExecutionError.sourceSegmentsRequired
    }

    let strategy = AITranslationExecutionSupport.chooseStrategy(snapshot: request.sourceSnapshot)
    await onEvent(.strategySelected(strategy))

    let template = try TranslationPromptCustomization.loadTranslationTemplate()
    let candidates = try await resolveTranslationRouteCandidates(
        defaults: defaults,
        database: database,
        credentialStore: credentialStore
    )

    let estimatedTokens = AITranslationExecutionSupport.estimatedTokenCount(for: request.sourceSnapshot.segments)
    let thresholds = AITranslationThresholds.v1
    var lastError: Error?

    for candidateWithIndex in candidates.enumerated() {
        do {
            try Task.checkCancellation()

            let route = try resolveRoute(from: candidateWithIndex)
            let translatedBySegmentID: [String: String]
            let requestCount: Int
            switch strategy {
            case .wholeArticleSingleRequest:
                translatedBySegmentID = try await executeStrategyA(
                    request: request,
                    targetLanguage: targetLanguage,
                    candidate: candidateWithIndex.element,
                    template: template,
                    onToken: { token in
                        await onEvent(.token(token))
                    }
                )
                requestCount = 1
            case .chunkedRequests:
                let chunkTokenBudget = max(
                    thresholds.maxEstimatedTokenBudgetForStrategyA * 3 / 4,
                    6_000
                )
                let chunks = AITranslationExecutionSupport.tokenAwareChunks(
                    from: request.sourceSnapshot.segments,
                    minimumChunkSize: thresholds.chunkSizeForStrategyC,
                    targetEstimatedTokensPerChunk: chunkTokenBudget
                )
                let chunkResult = try await executeStrategyC(
                    targetLanguage: targetLanguage,
                    chunks: chunks,
                    candidate: candidateWithIndex.element,
                    template: template,
                    onToken: { token in
                        await onEvent(.token(token))
                    }
                )
                translatedBySegmentID = chunkResult.translatedBySegmentID
                requestCount = chunkResult.requestCount
            case .perSegmentRequests:
                throw AITranslationExecutionError.invalidModelResponse
            }

            let translatedSegments = try AITranslationExecutionSupport.buildPersistedSegments(
                sourceSegments: request.sourceSnapshot.segments,
                translatedBySegmentID: translatedBySegmentID
            )

            return AITranslationExecutionSuccess(
                providerProfileId: route.providerProfileId,
                modelProfileId: route.modelProfileId,
                templateId: template.id,
                templateVersion: template.version,
                strategy: strategy,
                requestCount: requestCount,
                translatedSegments: translatedSegments,
                runtimeSnapshot: [
                    "targetLanguage": targetLanguage,
                    "strategy": strategy.rawValue,
                    "routeIndex": String(route.routeIndex),
                    "providerProfileId": String(route.providerProfileId),
                    "modelProfileId": String(route.modelProfileId),
                    "requestCount": String(requestCount),
                    "segmentCount": String(request.sourceSnapshot.segments.count),
                    "estimatedTokens": String(estimatedTokens),
                    "threshold.maxSegmentsForA": String(thresholds.maxSegmentsForStrategyA),
                    "threshold.maxEstimatedTokensForA": String(thresholds.maxEstimatedTokenBudgetForStrategyA),
                    "threshold.chunkSizeForC": String(thresholds.chunkSizeForStrategyC),
                    "sourceContentHash": request.sourceSnapshot.sourceContentHash,
                    "segmenterVersion": request.sourceSnapshot.segmenterVersion
                ]
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            lastError = error
            if candidateWithIndex.offset < candidates.count - 1 {
                continue
            }
        }
    }

    throw lastError ?? AITranslationExecutionError.noUsableModelRoute
}

private func resolveRoute(from candidateWithIndex: EnumeratedSequence<[TranslationRouteCandidate]>.Element) throws -> AITranslationResolvedRoute {
    guard let baseURL = URL(string: candidateWithIndex.element.provider.baseURL) else {
        throw AITranslationExecutionError.invalidBaseURL(candidateWithIndex.element.provider.baseURL)
    }
    _ = baseURL

    guard let providerProfileId = candidateWithIndex.element.provider.id,
          let modelProfileId = candidateWithIndex.element.model.id else {
        throw AITranslationExecutionError.noUsableModelRoute
    }

    return AITranslationResolvedRoute(
        providerProfileId: providerProfileId,
        modelProfileId: modelProfileId,
        routeIndex: candidateWithIndex.offset
    )
}

private func executeStrategyA(
    request: AITranslationRunRequest,
    targetLanguage: String,
    candidate: TranslationRouteCandidate,
    template: AgentPromptTemplate,
    onToken: @escaping @Sendable (String) async -> Void
) async throws -> [String: String] {
    let responseText = try await performTranslationModelRequest(
        targetLanguage: targetLanguage,
        segments: request.sourceSnapshot.segments,
        candidate: candidate,
        template: template,
        onToken: onToken
    )

    let parsed = try await parseTranslatedSegmentsWithRepair(
        rawResponseText: responseText,
        targetLanguage: targetLanguage,
        sourceSegments: request.sourceSnapshot.segments,
        template: template,
        candidate: candidate
    )
    return parsed
}

private struct ChunkExecutionResult: Sendable {
    let translatedBySegmentID: [String: String]
    let requestCount: Int
}

private func executeStrategyC(
    targetLanguage: String,
    chunks: [[ReaderSourceSegment]],
    candidate: TranslationRouteCandidate,
    template: AgentPromptTemplate,
    onToken: @escaping @Sendable (String) async -> Void
) async throws -> ChunkExecutionResult {
    guard chunks.isEmpty == false else {
        return ChunkExecutionResult(translatedBySegmentID: [:], requestCount: 0)
    }
    let expectedSegments = chunks.flatMap { $0 }
    var merged: [String: String] = [:]
    var executedRequests = 0

    for chunk in chunks {
        try Task.checkCancellation()
        let responseText = try await performTranslationModelRequest(
            targetLanguage: targetLanguage,
            segments: chunk,
            candidate: candidate,
            template: template,
            onToken: onToken
        )
        let parsed = try await parseTranslatedSegmentsWithRepair(
            rawResponseText: responseText,
            targetLanguage: targetLanguage,
            sourceSegments: chunk,
            template: template,
            candidate: candidate
        )

        for (sourceSegmentId, translatedText) in parsed {
            if merged[sourceSegmentId] != nil {
                throw AITranslationExecutionError.duplicateTranslatedSegment(sourceSegmentId: sourceSegmentId)
            }
            merged[sourceSegmentId] = translatedText
        }
        executedRequests += 1
    }

    try validateCompleteCoverage(
        parsed: merged,
        sourceSegments: expectedSegments
    )

    return ChunkExecutionResult(
        translatedBySegmentID: merged,
        requestCount: executedRequests
    )
}

private func withTranslationExecutionWatchdog<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let clampedSeconds = max(30, min(seconds, 900))
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(for: .seconds(clampedSeconds))
            throw AITranslationExecutionError.executionTimedOut(seconds: Int(clampedSeconds))
        }

        guard let firstResult = try await group.next() else {
            group.cancelAll()
            throw AITranslationExecutionError.executionTimedOut(seconds: Int(clampedSeconds))
        }
        group.cancelAll()
        return firstResult
    }
}

private func parseTranslatedSegmentsWithRepair(
    rawResponseText: String,
    targetLanguage: String,
    sourceSegments: [ReaderSourceSegment],
    template: AgentPromptTemplate,
    candidate: TranslationRouteCandidate
) async throws -> [String: String] {
    let expectedSegmentIDs = Set(sourceSegments.map(\.sourceSegmentId))

    do {
        let parsed = try AITranslationExecutionSupport.parseTranslatedSegmentsRecovering(
            from: rawResponseText,
            expectedSegmentIDs: expectedSegmentIDs
        )
        return try await fillMissingSegmentsIfNeeded(
            parsed: parsed,
            targetLanguage: targetLanguage,
            sourceSegments: sourceSegments,
            template: template,
            candidate: candidate
        )
    } catch {
        guard shouldAttemptTranslationOutputRepair(after: error, rawResponseText: rawResponseText) else {
            throw error
        }

        let repairedResponseText = try await performTranslationOutputRepairRequest(
            rawResponseText: rawResponseText,
            targetLanguage: targetLanguage,
            sourceSegments: sourceSegments,
            template: template,
            candidate: candidate
        )
        let repairedParsed = try AITranslationExecutionSupport.parseTranslatedSegmentsRecovering(
            from: repairedResponseText,
            expectedSegmentIDs: expectedSegmentIDs
        )
        return try await fillMissingSegmentsIfNeeded(
            parsed: repairedParsed,
            targetLanguage: targetLanguage,
            sourceSegments: sourceSegments,
            template: template,
            candidate: candidate
        )
    }
}

private func fillMissingSegmentsIfNeeded(
    parsed: [String: String],
    targetLanguage: String,
    sourceSegments: [ReaderSourceSegment],
    template: AgentPromptTemplate,
    candidate: TranslationRouteCandidate
) async throws -> [String: String] {
    let missingSegments = sourceSegments
        .sorted(by: { $0.orderIndex < $1.orderIndex })
        .filter { segment in
            guard let translated = parsed[segment.sourceSegmentId] else {
                return true
            }
            return translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

    if missingSegments.isEmpty {
        try validateCompleteCoverage(parsed: parsed, sourceSegments: sourceSegments)
        return parsed
    }

    let completedSegments = try await performTranslationMissingSegmentCompletionRequest(
        targetLanguage: targetLanguage,
        missingSegments: missingSegments,
        template: template,
        candidate: candidate
    )

    var merged = parsed
    for segment in missingSegments {
                guard let completed = completedSegments[segment.sourceSegmentId],
              completed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            continue
        }
        merged[segment.sourceSegmentId] = completed
    }

    try validateCompleteCoverage(parsed: merged, sourceSegments: sourceSegments)
    return merged
}

private func performTranslationMissingSegmentCompletionRequest(
    targetLanguage: String,
    missingSegments: [ReaderSourceSegment],
    template: AgentPromptTemplate,
    candidate: TranslationRouteCandidate
) async throws -> [String: String] {
    guard missingSegments.isEmpty == false else {
        return [:]
    }

    guard let baseURL = URL(string: candidate.provider.baseURL) else {
        throw AITranslationExecutionError.invalidBaseURL(candidate.provider.baseURL)
    }

    let sourceSegmentsJSON = try AITranslationExecutionSupport.sourceSegmentsJSON(missingSegments)
    let templateParameters = [
        "targetLanguageDisplayName": translationLanguageDisplayName(for: targetLanguage),
        "sourceSegmentsJSON": sourceSegmentsJSON
    ]
    let systemPrompt = try template.renderSystem(parameters: templateParameters) ?? ""

    let completionPrompt = """
    Translate ONLY the missing segments below.

    Target language: \(translationLanguageDisplayName(for: targetLanguage))
    Missing source segments (JSON array):
    \(sourceSegmentsJSON)

    Rules:
    - Output JSON only. No markdown, no code fences, no explanations.
    - Output must be a JSON array.
    - Each item must include keys: sourceSegmentId, translatedText.
    - Return exactly one item for each provided sourceSegmentId.
    """

    let llmRequest = LLMRequest(
        baseURL: baseURL,
        apiKey: candidate.apiKey,
        model: candidate.model.modelName,
        messages: [
            LLMMessage(role: "system", content: systemPrompt),
            LLMMessage(role: "user", content: completionPrompt)
        ],
        temperature: 0,
        topP: candidate.model.topP,
        maxTokens: candidate.model.maxTokens,
        stream: false
    )

    let provider = AgentLLMProvider()
    let response = try await provider.complete(request: llmRequest)
    let expected = Set(missingSegments.map(\.sourceSegmentId))
    return try AITranslationExecutionSupport.parseTranslatedSegmentsRecovering(
        from: response.text,
        expectedSegmentIDs: expected
    )
}

private func shouldAttemptTranslationOutputRepair(after error: Error, rawResponseText: String) -> Bool {
    let normalizedRaw = rawResponseText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalizedRaw.isEmpty == false else {
        return false
    }

    guard let translationError = error as? AITranslationExecutionError else {
        return false
    }

    switch translationError {
    case .invalidModelResponse,
         .missingTranslatedSegment,
         .emptyTranslatedSegment,
         .duplicateTranslatedSegment:
        return true
    case .sourceSegmentsRequired,
         .targetLanguageRequired,
         .noUsableModelRoute,
         .invalidBaseURL,
         .executionTimedOut:
        return false
    }
}

private func performTranslationOutputRepairRequest(
    rawResponseText: String,
    targetLanguage: String,
    sourceSegments: [ReaderSourceSegment],
    template: AgentPromptTemplate,
    candidate: TranslationRouteCandidate
) async throws -> String {
    guard let baseURL = URL(string: candidate.provider.baseURL) else {
        throw AITranslationExecutionError.invalidBaseURL(candidate.provider.baseURL)
    }

    let expectedSegmentIDs = sourceSegments
        .sorted(by: { $0.orderIndex < $1.orderIndex })
        .map(\.sourceSegmentId)

    let expectedIDsJSON: String
    do {
        let data = try JSONEncoder().encode(expectedSegmentIDs)
        expectedIDsJSON = String(decoding: data, as: UTF8.self)
    } catch {
        expectedIDsJSON = "[]"
    }

    let sourceSegmentsJSON = try AITranslationExecutionSupport.sourceSegmentsJSON(sourceSegments)
    let templateParameters = [
        "targetLanguageDisplayName": translationLanguageDisplayName(for: targetLanguage),
        "sourceSegmentsJSON": sourceSegmentsJSON
    ]
    let systemPrompt = try template.renderSystem(parameters: templateParameters) ?? ""

    let normalizedRaw = rawResponseText.trimmingCharacters(in: .whitespacesAndNewlines)
    let repairPrompt = """
    Convert the previous translation output to strict JSON.

    Target language: \(translationLanguageDisplayName(for: targetLanguage))
    Expected sourceSegmentIds (JSON array):
    \(expectedIDsJSON)

    Previous model output:
    \(normalizedRaw)

    Rules:
    - Output JSON only. No markdown, no code fences, no explanations.
    - Output must be a JSON array.
    - Each item must include keys: sourceSegmentId, translatedText.
    - Keep translatedText non-empty.
    - Do not invent new sourceSegmentId values.
    """

    let llmRequest = LLMRequest(
        baseURL: baseURL,
        apiKey: candidate.apiKey,
        model: candidate.model.modelName,
        messages: [
            LLMMessage(role: "system", content: systemPrompt),
            LLMMessage(role: "user", content: repairPrompt)
        ],
        temperature: 0,
        topP: candidate.model.topP,
        maxTokens: candidate.model.maxTokens,
        stream: false
    )

    let provider = AgentLLMProvider()
    let response = try await provider.complete(request: llmRequest)
    return response.text
}

private func performTranslationModelRequest(
    targetLanguage: String,
    segments: [ReaderSourceSegment],
    candidate: TranslationRouteCandidate,
    template: AgentPromptTemplate,
    onToken: @escaping @Sendable (String) async -> Void
) async throws -> String {
    let sourceSegmentsJSON = try AITranslationExecutionSupport.sourceSegmentsJSON(segments)
    let parameters = [
        "targetLanguageDisplayName": translationLanguageDisplayName(for: targetLanguage),
        "sourceSegmentsJSON": sourceSegmentsJSON
    ]

    let systemPrompt = try template.renderSystem(parameters: parameters) ?? ""
    let userPromptTemplate = try template.render(parameters: parameters)
    let userPrompt = """
    \(userPromptTemplate)

    Output format (strict):
    - Return JSON only.
    - Use array items with keys: `sourceSegmentId`, `translatedText`.
    """

    guard let baseURL = URL(string: candidate.provider.baseURL) else {
        throw AITranslationExecutionError.invalidBaseURL(candidate.provider.baseURL)
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
    return response.text
}

private func validateCompleteCoverage(
    parsed: [String: String],
    sourceSegments: [ReaderSourceSegment]
) throws {
    for segment in sourceSegments {
        guard let translated = parsed[segment.sourceSegmentId] else {
            throw AITranslationExecutionError.missingTranslatedSegment(sourceSegmentId: segment.sourceSegmentId)
        }
        if translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AITranslationExecutionError.emptyTranslatedSegment(sourceSegmentId: segment.sourceSegmentId)
        }
    }
}

private func resolveTranslationRouteCandidates(
    defaults: TranslationAgentDefaults,
    database: DatabaseManager,
    credentialStore: CredentialStore
) async throws -> [TranslationRouteCandidate] {
    let (models, providers) = try await database.read { db in
        let models = try AIModelProfile
            .filter(Column("supportsTranslation") == true)
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

    var candidates: [TranslationRouteCandidate] = []
    for modelID in routeModelIDs {
        guard let model = modelsByID[modelID] else { continue }
        guard let provider = providersByID[model.providerProfileId] else { continue }
        let apiKey = try credentialStore.readSecret(for: provider.apiKeyRef)
        candidates.append(TranslationRouteCandidate(provider: provider, model: model, apiKey: apiKey))
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
            candidates.append(TranslationRouteCandidate(provider: provider, model: fallbackModel, apiKey: apiKey))
        }
    }

    guard candidates.isEmpty == false else {
        throw AITranslationExecutionError.noUsableModelRoute
    }
    return candidates
}

private extension AppModel {
    func recordTranslationTerminalRun(
        entryId: Int64,
        status: AITaskRunStatus,
        context: AITranslationExecutionFailureContext,
        targetLanguage: String,
        durationMs: Int
    ) async throws {
        let snapshot = try encodeTranslationExecutionRuntimeSnapshot(context.runtimeSnapshot)
        let now = Date()
        try await database.write { db in
            var run = AITaskRun(
                id: nil,
                entryId: entryId,
                taskType: .translation,
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

private func encodeTranslationExecutionRuntimeSnapshot(_ snapshot: [String: String]) throws -> String? {
    guard snapshot.isEmpty == false else {
        return nil
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(snapshot)
    return String(data: data, encoding: .utf8)
}

private func translationLanguageDisplayName(for identifier: String) -> String {
    let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.isEmpty == false else {
        return "English (en)"
    }
    if let localized = Locale.current.localizedString(forIdentifier: trimmed) {
        return "\(localized) (\(trimmed))"
    }
    return trimmed
}
