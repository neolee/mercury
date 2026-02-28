import SwiftUI
import CryptoKit

extension ReaderTranslationView {
    // MARK: - Runtime Events

    func abandonTranslationWaiting(for previousEntryId: Int64, nextSelectedEntryId: Int64?) async {
        guard previousEntryId != nextSelectedEntryId else {
            return
        }
        await appModel.agentRuntimeEngine.abandonWaiting(taskKind: .translation, entryId: previousEntryId)
        await MainActor.run {
            let ownersToDrop = translationQueuedRunPayloads.keys.filter { $0.entryId == previousEntryId }
            for owner in ownersToDrop {
                translationQueuedRunPayloads.removeValue(forKey: owner)
                translationTaskIDByOwner.removeValue(forKey: owner)
                translationProjectionStateByOwner.removeValue(forKey: owner)
                translationRetryMergeContextByOwner.removeValue(forKey: owner)
            }
            translationPhaseByOwner = translationPhaseByOwner.filter { owner, phase in
                guard phase == .waiting else {
                    return true
                }
                return owner.entryId != previousEntryId
            }
            refreshRunningStateForCurrentEntry()
        }
    }

    func observeRuntimeEventsForTranslation() async {
        let stream = await appModel.agentRuntimeEngine.events()
        for await event in stream {
            await MainActor.run {
                handleTranslationRuntimeEvent(event)
            }
        }
    }

    @MainActor
    func handleTranslationRuntimeEvent(_ event: AgentRuntimeEvent) {
        switch event {
        case let .activated(_, owner, activeToken):
            guard owner.taskKind == .translation else { return }
            guard translationRunningOwner != owner else { return }
            guard let request = translationQueuedRunPayloads.removeValue(forKey: owner) else {
                translationTaskIDByOwner.removeValue(forKey: owner)
                translationProjectionStateByOwner.removeValue(forKey: owner)
                translationRetryMergeContextByOwner.removeValue(forKey: owner)
                // Engine promoted this owner to active but we have no queued payload (e.g. user
                // toggled back to original mode before activation). Release the slot immediately
                // to prevent a permanent engine capacity leak.
                Task {
                    _ = await appModel.agentRuntimeEngine.finish(
                        owner: owner, terminalPhase: .cancelled, reason: .cancelled, activeToken: activeToken
                    )
                }
                return
            }
            guard shouldProjectTranslation(owner: owner) else {
                translationPhaseByOwner.removeValue(forKey: owner)
                translationTaskIDByOwner.removeValue(forKey: owner)
                translationProjectionStateByOwner.removeValue(forKey: owner)
                Task {
                    _ = await appModel.agentRuntimeEngine.finish(owner: owner, terminalPhase: .cancelled, reason: .cancelled, activeToken: activeToken)
                }
                return
            }
            translationCurrentSlotKey = request.slotKey
            translationPhaseByOwner[owner] = .requesting
            startTranslationRun(request, activeToken: activeToken)
        case let .dropped(_, owner, _):
            guard owner.taskKind == .translation else { return }
            if translationQueuedRunPayloads.removeValue(forKey: owner) != nil {
                translationTaskIDByOwner.removeValue(forKey: owner)
                translationProjectionStateByOwner.removeValue(forKey: owner)
                translationRetryMergeContextByOwner.removeValue(forKey: owner)
                if translationPhaseByOwner[owner] == .waiting {
                    translationPhaseByOwner.removeValue(forKey: owner)
                }
            }
        default:
            return
        }
    }

    @MainActor
    func applyPersistedTranslationForCompletedRun(
        _ request: TranslationQueuedRunRequest
    ) async -> TranslationPersistedCoverage? {
        guard AgentDisplayOwnershipPolicy.shouldProject(
            owner: request.owner,
            displayedEntryId: displayedEntryId
        ),
              let currentSourceReaderHTML = sourceReaderHTML else {
            return nil
        }

        do {
            guard let record = try await appModel.loadTranslationRecord(slotKey: request.slotKey) else {
                hasPersistedTranslationForCurrentSlot = false
                hasResumableTranslationCheckpointForCurrentSlot = false
                translationMode = .original
                return nil
            }
            guard AgentDisplayOwnershipPolicy.shouldProject(
                owner: request.owner,
                displayedEntryId: displayedEntryId
            ) else {
                return nil
            }
            translationCurrentSlotKey = request.slotKey
            translationPhaseByOwner.removeValue(forKey: request.owner)
            let coverage = makePersistedCoverage(record: record, sourceSnapshot: request.projectionSnapshot)
            hasPersistedTranslationForCurrentSlot = coverage.hasTranslatedSegments
            hasResumableTranslationCheckpointForCurrentSlot = false
            translationMode = coverage.hasTranslatedSegments ? .bilingual : .original

            if coverage.hasTranslatedSegments {
                applyProjection(
                    entryId: request.projectionSnapshot.entryId,
                    slotKey: request.slotKey,
                    sourceReaderHTML: currentSourceReaderHTML,
                    sourceSnapshot: request.projectionSnapshot,
                    translatedBySegmentID: coverage.translatedBySegmentID,
                    pendingSegmentIDs: [],
                    failedSegmentIDs: coverage.unresolvedSegmentIDs,
                    pendingStatusText: nil,
                    failedStatusText: AgentRuntimeProjection.translationNoContentStatus()
                )
            } else {
                setReaderHTML(currentSourceReaderHTML)
            }
            return coverage
        } catch {
            hasPersistedTranslationForCurrentSlot = false
            hasResumableTranslationCheckpointForCurrentSlot = false
            translationMode = .original
            return nil
        }
    }

    @MainActor
    func mergeRetryPersistedTranslationIfNeeded(request: TranslationQueuedRunRequest) async {
        guard let retryContext = translationRetryMergeContextByOwner.removeValue(forKey: request.owner) else {
            return
        }
        do {
            guard let retryRecord = try await appModel.loadTranslationRecord(slotKey: request.slotKey) else {
                return
            }
            var mergedBySegmentID = retryContext.baseTranslatedBySegmentID
            for segment in retryRecord.segments {
                mergedBySegmentID[segment.sourceSegmentId] = segment.translatedText
            }
            let mergedSegments = try TranslationExecutionSupport.buildPersistedSegments(
                sourceSegments: retryContext.sourceSnapshot.segments,
                translatedBySegmentID: mergedBySegmentID
            )
            guard mergedSegments.isEmpty == false else {
                return
            }
            var runtimeSnapshot = decodeRuntimeSnapshotDictionary(retryRecord.run.runtimeParameterSnapshot)
            runtimeSnapshot["retryMerge"] = "true"
            _ = try await appModel.persistSuccessfulTranslationResult(
                entryId: request.slotKey.entryId,
                agentProfileId: retryRecord.run.agentProfileId,
                providerProfileId: retryRecord.run.providerProfileId,
                modelProfileId: retryRecord.run.modelProfileId,
                promptVersion: retryRecord.run.promptVersion,
                targetLanguage: request.slotKey.targetLanguage,
                sourceContentHash: retryContext.sourceSnapshot.sourceContentHash,
                segmenterVersion: retryContext.sourceSnapshot.segmenterVersion,
                outputLanguage: retryRecord.result.outputLanguage,
                segments: mergedSegments,
                templateId: retryRecord.run.templateId,
                templateVersion: retryRecord.run.templateVersion,
                runtimeParameterSnapshot: runtimeSnapshot,
                durationMs: retryRecord.run.durationMs
            )
        } catch {
            appModel.reportDebugIssue(
                title: "Translation Retry Merge Failed",
                detail: "entryId=\(request.slotKey.entryId)\nslot=\(request.slotKey.targetLanguage)\nreason=\(error.localizedDescription)",
                category: .task
            )
        }
    }

    func decodeRuntimeSnapshotDictionary(_ raw: String?) -> [String: String] {
        guard let raw,
              let data = raw.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return snapshot
    }

    @MainActor
    func handleTranslationActionURL(_ url: URL) async {
        guard let action = parseTranslationReaderAction(from: url) else {
            return
        }
        switch action {
        case .retrySegment(let entryId, let slotKey, let segmentId):
            await retryTranslationSegments(
                entryId: entryId,
                slotKey: slotKey,
                requestedSegmentIDs: [segmentId]
            )
        case .retryFailed(let entryId, let slotKey):
            let failedSegmentIDs = await resolveFailedSegmentIDs(entryId: entryId, slotKey: slotKey)
            await retryTranslationSegments(
                entryId: entryId,
                slotKey: slotKey,
                requestedSegmentIDs: failedSegmentIDs
            )
        }
    }

    func parseTranslationReaderAction(from url: URL) -> TranslationReaderAction? {
        guard url.scheme?.lowercased() == "mercury-action",
              url.host?.lowercased() == "translation",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        var queryItems: [String: String] = [:]
        for queryItem in components.queryItems ?? [] {
            queryItems[queryItem.name] = queryItem.value ?? ""
        }
        guard let entryIDRaw = queryItems["entryId"],
              let entryId = Int64(entryIDRaw),
              let slotRaw = queryItems["slot"] else {
            return nil
        }
        let slotKey = TranslationSlotKey(
            entryId: entryId,
            targetLanguage: AgentLanguageOption.option(for: slotRaw).code
        )
        switch components.path {
        case "/retry-segment":
            guard let segmentID = queryItems["segmentId"],
                  segmentID.isEmpty == false else {
                return nil
            }
            return .retrySegment(entryId: entryId, slotKey: slotKey, segmentId: segmentID)
        case "/retry-failed":
            return .retryFailed(entryId: entryId, slotKey: slotKey)
        default:
            return nil
        }
    }

    @MainActor
    func retryTranslationSegments(
        entryId: Int64,
        slotKey: TranslationSlotKey,
        requestedSegmentIDs: Set<String>
    ) async {
        guard requestedSegmentIDs.isEmpty == false,
              displayedEntryId == entryId else {
            return
        }
        guard isTranslationRunningForDisplayedEntry() == false else {
            return
        }
        guard appModel.isTranslationAgentAvailable else {
            topBannerMessage = ReaderBannerMessage(
                text: String(localized: "Translation agent is not configured. Add a provider and model in Settings to enable translation.", bundle: bundle),
                action: ReaderBannerMessage.BannerAction(
                    label: String(localized: "Open Settings", bundle: bundle),
                    handler: { openSettings() }
                )
            )
            return
        }
        guard let snapshotContext = buildCurrentTranslationSnapshot(entryId: entryId) else {
            return
        }

        let availableSegmentIDs = translatableSegmentIDs(in: snapshotContext.snapshot)
        let retrySegmentIDs = requestedSegmentIDs.intersection(availableSegmentIDs)
        guard retrySegmentIDs.isEmpty == false else {
            return
        }

        let retrySegments = snapshotContext.snapshot.segments.filter {
            retrySegmentIDs.contains($0.sourceSegmentId)
        }
        let retrySnapshot = TranslationSourceSegmentsSnapshot(
            entryId: snapshotContext.snapshot.entryId,
            sourceContentHash: snapshotContext.snapshot.sourceContentHash,
            segmenterVersion: snapshotContext.snapshot.segmenterVersion,
            segments: retrySegments
        )
        let owner = makeTranslationRunOwner(slotKey: slotKey)

        var baseTranslatedBySegmentID: [String: String] = [:]
        if let persistedRecord = try? await appModel.loadTranslationRecord(slotKey: slotKey) {
            for segment in persistedRecord.segments {
                baseTranslatedBySegmentID[segment.sourceSegmentId] = segment.translatedText
            }
        }
        if let projectionState = translationProjectionStateByOwner[owner] {
            baseTranslatedBySegmentID.merge(projectionState.translatedBySegmentID) { _, new in new }
        }
        for retrySegmentID in retrySegmentIDs {
            baseTranslatedBySegmentID.removeValue(forKey: retrySegmentID)
        }
        let allSegmentIDs = translatableSegmentIDs(in: snapshotContext.snapshot)
        let initialFailedSegmentIDs = allSegmentIDs
            .subtracting(Set(baseTranslatedBySegmentID.keys))
            .subtracting(retrySegmentIDs)

        translationRetryMergeContextByOwner[owner] = TranslationRetryMergeContext(
            sourceSnapshot: snapshotContext.snapshot,
            baseTranslatedBySegmentID: baseTranslatedBySegmentID
        )
        translationMode = .bilingual
        translationManualStartRequestedEntryId = nil

        let pendingStatusText = await requestTranslationRun(
            owner: owner,
            slotKey: slotKey,
            snapshot: retrySnapshot,
            projectionSnapshot: snapshotContext.snapshot,
            targetLanguage: slotKey.targetLanguage,
            initialTranslatedBySegmentID: baseTranslatedBySegmentID,
            initialFailedSegmentIDs: initialFailedSegmentIDs,
            isRetry: true
        )

        applyProjection(
            entryId: entryId,
            slotKey: slotKey,
            sourceReaderHTML: snapshotContext.sourceReaderHTML,
            sourceSnapshot: snapshotContext.snapshot,
            translatedBySegmentID: baseTranslatedBySegmentID,
            pendingSegmentIDs: retrySegmentIDs,
            failedSegmentIDs: initialFailedSegmentIDs,
            pendingStatusText: pendingStatusText,
            failedStatusText: AgentRuntimeProjection.translationNoContentStatus()
        )
    }

    @MainActor
    func resolveFailedSegmentIDs(
        entryId: Int64,
        slotKey: TranslationSlotKey
    ) async -> Set<String> {
        guard let snapshotContext = buildCurrentTranslationSnapshot(entryId: entryId) else {
            return []
        }
        let owner = makeTranslationRunOwner(slotKey: slotKey)
        if let projectionState = translationProjectionStateByOwner[owner],
           projectionState.failedSegmentIDs.isEmpty == false {
            return projectionState.failedSegmentIDs
        }

        var translatedSegmentIDs: Set<String> = []
        if let record = try? await appModel.loadTranslationRecord(slotKey: slotKey) {
            translatedSegmentIDs = Set(record.segments.map(\.sourceSegmentId))
        }
        return translatableSegmentIDs(in: snapshotContext.snapshot)
            .subtracting(translatedSegmentIDs)
    }

    @MainActor
    func buildCurrentTranslationSnapshot(
        entryId: Int64
    ) -> (sourceReaderHTML: String, snapshot: TranslationSourceSegmentsSnapshot)? {
        guard let currentSourceReaderHTML = sourceReaderHTML else {
            return nil
        }
        let headerSourceText = translationHeaderSourceText(for: entry, renderedHTML: currentSourceReaderHTML)
        do {
            let baseSnapshot = try TranslationSegmentExtractor.extractFromRenderedHTML(
                entryId: entryId,
                renderedHTML: currentSourceReaderHTML
            )
            return (
                currentSourceReaderHTML,
                makeTranslationSnapshot(
                    baseSnapshot: baseSnapshot,
                    headerSourceText: headerSourceText
                )
            )
        } catch {
            return nil
        }
    }

    // MARK: - Snapshot Construction

    func translationHeaderSourceText(for entry: Entry?, renderedHTML: String?) -> String? {
        TranslationHeaderTextBuilder.buildHeaderSourceText(
            entryTitle: entry?.title,
            entryAuthor: entry?.author,
            renderedHTML: renderedHTML
        )
    }

    func makeTranslationSnapshot(
        baseSnapshot: TranslationSourceSegmentsSnapshot,
        headerSourceText: String?
    ) -> TranslationSourceSegmentsSnapshot {
        guard let headerSourceText,
              headerSourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return baseSnapshot
        }

        var segments = baseSnapshot.segments
        let headerSegment = TranslationSourceSegment(
            sourceSegmentId: Self.translationHeaderSegmentID,
            orderIndex: -1,
            sourceHTML: "",
            sourceText: headerSourceText,
            segmentType: .p
        )
        segments.insert(headerSegment, at: 0)

        let combinedHashInput = "\(baseSnapshot.sourceContentHash)\n\(headerSourceText)"
        let digest = SHA256.hash(data: Data(combinedHashInput.utf8))
        let combinedHash = digest.map { String(format: "%02x", $0) }.joined()

        return TranslationSourceSegmentsSnapshot(
            entryId: baseSnapshot.entryId,
            sourceContentHash: combinedHash,
            segmenterVersion: baseSnapshot.segmenterVersion,
            segments: segments
        )
    }

    // MARK: - HTML Helpers

    func setReaderHTML(_ html: String?) {
        if readerHTML == html {
            return
        }
        readerHTML = html
    }

    // MARK: - Statics

    static let translationHeaderSegmentID = "seg_meta_title_author"
}
