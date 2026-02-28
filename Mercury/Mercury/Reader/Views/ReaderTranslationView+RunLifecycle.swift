import SwiftUI

extension ReaderTranslationView {
    // MARK: - Request / Run

    @MainActor
    func requestTranslationRun(
        owner: AgentRunOwner,
        slotKey: TranslationSlotKey,
        snapshot: TranslationSourceSegmentsSnapshot,
        projectionSnapshot: TranslationSourceSegmentsSnapshot,
        targetLanguage: String,
        initialTranslatedBySegmentID: [String: String] = [:],
        initialFailedSegmentIDs: Set<String> = [],
        isRetry: Bool = false
    ) async -> String {
        hasResumableTranslationCheckpointForCurrentSlot = false
        let initialPendingSegmentIDs = translatableSegmentIDs(in: snapshot)
        let request = TranslationQueuedRunRequest(
            taskId: appModel.makeTaskID(),
            owner: owner,
            slotKey: slotKey,
            executionSnapshot: snapshot,
            projectionSnapshot: projectionSnapshot,
            targetLanguage: targetLanguage,
            initialTranslatedBySegmentID: initialTranslatedBySegmentID,
            initialPendingSegmentIDs: initialPendingSegmentIDs,
            initialFailedSegmentIDs: initialFailedSegmentIDs,
            isRetry: isRetry
        )

        // Register payload synchronously BEFORE submit() so handleTranslationRuntimeEvent(.activated)
        // can always claim it, including the .startNow path. Without this, .activated may arrive in
        // the actor-hop gap before the direct startTranslationRun call below and incorrectly release
        // the runtime slot as .cancelled because no payload exists yet.
        translationQueuedRunPayloads[owner] = request
        translationTaskIDByOwner[owner] = request.taskId
        translationProjectionStateByOwner[owner] = TranslationProjectionState(
            slotKey: request.slotKey,
            sourceSnapshot: request.projectionSnapshot,
            translatedBySegmentID: request.initialTranslatedBySegmentID,
            pendingSegmentIDs: request.initialPendingSegmentIDs,
            failedSegmentIDs: request.initialFailedSegmentIDs
        )

        let submission = await appModel.submitAgentTask(
            taskId: request.taskId,
            kind: .translation,
            owner: owner,
            requestSource: .manual,
            visibilityPolicy: .selectedEntryOnly
        )
        switch submission.decision {
        case .startNow:
            // Guard against the race where .activated already claimed this owner and started
            // translation while submit() was returning to this caller.
            if translationRunningOwner != owner {
                translationQueuedRunPayloads.removeValue(forKey: owner)
                translationPhaseByOwner[owner] = .requesting
                startTranslationRun(request, activeToken: submission.activeToken ?? "")
            }
            return AgentRuntimeProjection.translationStatusText(for: .requesting)
        case .queuedWaiting, .alreadyWaiting:
            // Payload already registered above; only update placeholder phase.
            translationPhaseByOwner[owner] = .waiting
            return AgentRuntimeProjection.translationStatusText(for: .waiting)
        case .alreadyActive:
            // Duplicate submission; remove the speculatively registered payload.
            translationQueuedRunPayloads.removeValue(forKey: owner)
            translationTaskIDByOwner.removeValue(forKey: owner)
            translationProjectionStateByOwner.removeValue(forKey: owner)
            translationRetryMergeContextByOwner.removeValue(forKey: owner)
            let phase = translationPhaseByOwner[owner] ?? .generating
            return AgentRuntimeProjection.translationStatusText(for: phase)
        }
    }

    @MainActor
    func currentTranslationMissingStatusText(
        for owner: AgentRunOwner
    ) async -> String {
        let projection = await appModel.agentRuntimeEngine.statusProjection(for: owner)
        return AgentRuntimeProjection.translationMissingStatusText(
            projection: projection,
            cachedPhase: translationPhaseByOwner[owner],
            noContentStatus: AgentRuntimeProjection.translationNoContentStatus(),
            fetchFailedRetryStatus: AgentRuntimeProjection.translationFetchFailedRetryStatus()
        )
    }

    @MainActor
    func startTranslationRun(_ request: TranslationQueuedRunRequest, activeToken: String) {
        translationRunningOwner = request.owner
        translationCurrentSlotKey = request.slotKey
        translationPhaseByOwner[request.owner] = .requesting
        hasResumableTranslationCheckpointForCurrentSlot = false
        topBannerMessage = nil
        refreshRunningStateForCurrentEntry()

        let capturedToken = activeToken
        Task {
            _ = await appModel.startTranslationRun(
                request: TranslationRunRequest(
                    entryId: request.executionSnapshot.entryId,
                    targetLanguage: request.targetLanguage,
                    sourceSnapshot: request.executionSnapshot
                ),
                requestedTaskId: request.taskId,
                onEvent: { event in
                    await MainActor.run {
                        handleTranslationRunEvent(event, request: request, activeToken: capturedToken)
                    }
                }
            )
        }
    }

    // MARK: - Run Event Handling

    @MainActor
    func handleTranslationRunEvent(
        _ event: TranslationRunEvent,
        request: TranslationQueuedRunRequest,
        activeToken: String
    ) {
        switch event {
        case .started(let taskId):
            translationTaskIDByOwner[request.owner] = taskId
            translationPhaseByOwner[request.owner] = .requesting
            Task {
                await appModel.agentRuntimeEngine.updatePhase(owner: request.owner, phase: .requesting, activeToken: activeToken)
                let shouldProject = await MainActor.run { shouldProjectTranslation(owner: request.owner) }
                guard shouldProject else { return }
                await MainActor.run {
                    refreshRunningStateForCurrentEntry()
                }
            }
        case .notice(let message):
            translationNoticeByOwner[request.owner] = message
            if request.owner.entryId == displayedEntryId {
                topBannerMessage = ReaderBannerMessage(
                    text: message,
                    secondaryAction: .openDebugIssues
                )
            }
        case .segmentCompleted(let sourceSegmentId, let translatedText):
            translationPhaseByOwner[request.owner] = .generating
            if var state = translationProjectionStateByOwner[request.owner] {
                state.translatedBySegmentID[sourceSegmentId] = translatedText
                state.pendingSegmentIDs.remove(sourceSegmentId)
                state.failedSegmentIDs.remove(sourceSegmentId)
                translationProjectionStateByOwner[request.owner] = state
                scheduleProgressiveProjectionUpdate(owner: request.owner)
            }
            Task {
                await appModel.agentRuntimeEngine.updatePhase(owner: request.owner, phase: .generating, activeToken: activeToken)
            }
        case .token:
            if translationPhaseByOwner[request.owner] != .generating {
                translationPhaseByOwner[request.owner] = .generating
            }
        case .persisting:
            translationPhaseByOwner[request.owner] = .persisting
            Task {
                await appModel.agentRuntimeEngine.updatePhase(owner: request.owner, phase: .persisting, activeToken: activeToken)
            }
        case .terminal(let outcome):
            let terminalProjection = finalizeProjectionStateForTerminal(owner: request.owner)
            if translationRunningOwner == request.owner {
                translationRunningOwner = nil
            }
            hasResumableTranslationCheckpointForCurrentSlot = false
            translationPhaseByOwner.removeValue(forKey: request.owner)
            translationTaskIDByOwner.removeValue(forKey: request.owner)
            refreshRunningStateForCurrentEntry()
            let notice = translationNoticeByOwner.removeValue(forKey: request.owner)
            translationProjectionDebounceTask?.cancel()
            translationProjectionDebounceTask = nil
            Task {
                _ = await appModel.agentRuntimeEngine.finish(
                    owner: request.owner,
                    terminalPhase: outcome.agentRunPhase,
                    reason: outcome.normalizedFailureReason,
                    activeToken: activeToken
                )
                let shouldProject = await MainActor.run { shouldProjectTranslation(owner: request.owner) }
                guard shouldProject else { return }
                switch outcome {
                case .succeeded:
                    if request.isRetry {
                        await mergeRetryPersistedTranslationIfNeeded(request: request)
                    } else {
                        await MainActor.run {
                            _ = translationRetryMergeContextByOwner.removeValue(forKey: request.owner)
                        }
                    }
                    let coverage = await applyPersistedTranslationForCompletedRun(request)
                    await syncTranslationPresentationForCurrentEntry(allowAutoEnterBilingualForRunningEntry: false)
                    await refreshTranslationClearAvailabilityForCurrentEntry()
                    if request.owner.entryId == displayedEntryId {
                        await MainActor.run {
                            topBannerMessage = makeTerminalSuccessBanner(
                                slotKey: request.slotKey,
                                coverage: coverage
                            )
                        }
                    }
                    await MainActor.run {
                        _ = translationProjectionStateByOwner.removeValue(forKey: request.owner)
                    }
                case .failed, .timedOut:
                    let failedSegmentIDs = terminalProjection?.failedSegmentIDs
                        ?? translatableSegmentIDs(in: request.projectionSnapshot)
                    if request.owner.entryId == displayedEntryId {
                        let failureText = AgentRuntimeProjection.bannerMessage(
                            for: outcome,
                            taskKind: .translation
                        ) ?? AgentRuntimeProjection.failureMessage(for: .unknown, taskKind: .translation)
                        let bannerText: String
                        if let notice, notice.isEmpty == false {
                            bannerText = "\(notice) \(failureText)"
                        } else {
                            bannerText = failureText
                        }
                        await MainActor.run {
                            topBannerMessage = ReaderBannerMessage(
                                text: bannerText,
                                action: ReaderBannerMessage.BannerAction.openDebugIssues,
                                secondaryAction: makeRetryFailedBannerAction(
                                    slotKey: request.slotKey,
                                    failedSegmentIDs: failedSegmentIDs
                                )
                            )
                        }
                    }
                    await MainActor.run {
                        renderTerminalProjectionIfNeeded(
                            request: request,
                            state: terminalProjection
                        )
                    }
                case .cancelled:
                    await MainActor.run {
                        _ = translationRetryMergeContextByOwner.removeValue(forKey: request.owner)
                    }
                    let coverage = await loadPersistedCoverage(
                        slotKey: request.slotKey,
                        sourceSnapshot: request.projectionSnapshot
                    )
                    await MainActor.run {
                        guard request.owner.entryId == displayedEntryId else {
                            return
                        }
                        let hasTranslatedSegments = coverage?.hasTranslatedSegments == true
                        hasPersistedTranslationForCurrentSlot = hasTranslatedSegments
                        translationMode = hasTranslatedSegments ? .bilingual : .original
                        topBannerMessage = makeTerminalSuccessBanner(
                            slotKey: request.slotKey,
                            coverage: coverage
                        )
                    }
                    await syncTranslationPresentationForCurrentEntry(allowAutoEnterBilingualForRunningEntry: false)
                    await refreshTranslationClearAvailabilityForCurrentEntry()
                    await MainActor.run {
                        _ = translationProjectionStateByOwner.removeValue(forKey: request.owner)
                    }
                }
            }
        }
    }

    // MARK: - Projection Helpers

    @MainActor
    func isTranslationRunningForDisplayedEntry() -> Bool {
        guard let displayedEntryId else {
            return false
        }
        guard let runningOwner = translationRunningOwner else {
            return false
        }
        return runningOwner.entryId == displayedEntryId
    }

    @MainActor
    func refreshRunningStateForCurrentEntry() {
        isTranslationRunningForCurrentEntry = isTranslationRunningForDisplayedEntry()
    }

    @MainActor
    func scheduleProgressiveProjectionUpdate(owner: AgentRunOwner) {
        translationProjectionDebounceTask?.cancel()
        translationProjectionDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard Task.isCancelled == false else { return }
            await MainActor.run {
                guard translationRunningOwner == owner,
                      shouldProjectTranslation(owner: owner),
                      let sourceReaderHTML,
                      let projectionState = translationProjectionStateByOwner[owner] else {
                    return
                }
                let phase = translationPhaseByOwner[owner] ?? .generating
                let pendingStatusText = AgentRuntimeProjection.translationStatusText(for: phase)
                applyProjection(
                    entryId: owner.entryId,
                    slotKey: projectionState.slotKey,
                    sourceReaderHTML: sourceReaderHTML,
                    sourceSnapshot: projectionState.sourceSnapshot,
                    translatedBySegmentID: projectionState.translatedBySegmentID,
                    pendingSegmentIDs: projectionState.pendingSegmentIDs,
                    failedSegmentIDs: projectionState.failedSegmentIDs,
                    pendingStatusText: pendingStatusText,
                    failedStatusText: AgentRuntimeProjection.translationNoContentStatus()
                )
            }
        }
    }

    @MainActor
    func finalizeProjectionStateForTerminal(owner: AgentRunOwner) -> TranslationProjectionState? {
        guard var state = translationProjectionStateByOwner[owner] else {
            return nil
        }
        let translatedSegmentIDs = Set(state.translatedBySegmentID.keys)
        let unresolvedSegmentIDs = translatableSegmentIDs(in: state.sourceSnapshot)
            .subtracting(translatedSegmentIDs)
        state.pendingSegmentIDs.removeAll()
        state.failedSegmentIDs.formUnion(unresolvedSegmentIDs)
        translationProjectionStateByOwner[owner] = state
        return state
    }

    @MainActor
    func renderTerminalProjectionIfNeeded(
        request: TranslationQueuedRunRequest,
        state: TranslationProjectionState?
    ) {
        guard request.owner.entryId == displayedEntryId,
              let state,
              let sourceReaderHTML else {
            return
        }
        applyProjection(
            entryId: request.owner.entryId,
            slotKey: request.slotKey,
            sourceReaderHTML: sourceReaderHTML,
            sourceSnapshot: state.sourceSnapshot,
            translatedBySegmentID: state.translatedBySegmentID,
            pendingSegmentIDs: [],
            failedSegmentIDs: state.failedSegmentIDs,
            pendingStatusText: nil,
            failedStatusText: AgentRuntimeProjection.translationNoContentStatus()
        )
    }

    @MainActor
    func makeTerminalSuccessBanner(
        slotKey: TranslationSlotKey,
        coverage: TranslationPersistedCoverage?
    ) -> ReaderBannerMessage? {
        guard let coverage,
              coverage.hasTranslatedSegments,
              coverage.unresolvedSegmentIDs.isEmpty == false else {
            return nil
        }
        return ReaderBannerMessage(
            text: String(localized: "Translation completed with missing segments.", bundle: bundle),
            secondaryAction: makeRetryFailedBannerAction(
                slotKey: slotKey,
                failedSegmentIDs: coverage.unresolvedSegmentIDs
            )
        )
    }

    func shouldOfferResumeTranslation(
        record: TranslationStoredRecord,
        coverage: TranslationPersistedCoverage
    ) -> Bool {
        record.isCheckpointRunning && coverage.unresolvedSegmentIDs.isEmpty == false
    }

    @MainActor
    func makeResumeTranslationBanner(
        slotKey: TranslationSlotKey,
        unresolvedSegmentIDs: Set<String>
    ) -> ReaderBannerMessage? {
        guard unresolvedSegmentIDs.isEmpty == false else {
            return nil
        }
        return ReaderBannerMessage(
            text: String(localized: "Partial translation found. Resume to continue.", bundle: bundle),
            action: ReaderBannerMessage.BannerAction(
                label: String(localized: "Resume Translation", bundle: bundle),
                handler: {
                    Task {
                        await retryTranslationSegments(
                            entryId: slotKey.entryId,
                            slotKey: slotKey,
                            requestedSegmentIDs: unresolvedSegmentIDs
                        )
                    }
                }
            )
        )
    }

    func makePersistedCoverage(
        record: TranslationStoredRecord,
        sourceSnapshot: TranslationSourceSegmentsSnapshot
    ) -> TranslationPersistedCoverage {
        let sourceSegmentIDs = translatableSegmentIDs(in: sourceSnapshot)
        var translatedBySegmentID: [String: String] = [:]
        for segment in record.segments {
            guard sourceSegmentIDs.contains(segment.sourceSegmentId) else {
                continue
            }
            guard segment.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                continue
            }
            translatedBySegmentID[segment.sourceSegmentId] = segment.translatedText
        }
        let translatedSegmentIDs = Set(translatedBySegmentID.keys)
        let unresolvedSegmentIDs = sourceSegmentIDs
            .subtracting(translatedSegmentIDs)
        return TranslationPersistedCoverage(
            translatedBySegmentID: translatedBySegmentID,
            unresolvedSegmentIDs: unresolvedSegmentIDs
        )
    }

    func translatableSegmentIDs(in snapshot: TranslationSourceSegmentsSnapshot) -> Set<String> {
        Set(snapshot.segments.map(\.sourceSegmentId))
    }

    func loadPersistedCoverage(
        slotKey: TranslationSlotKey,
        sourceSnapshot: TranslationSourceSegmentsSnapshot
    ) async -> TranslationPersistedCoverage? {
        do {
            guard let record = try await appModel.loadTranslationRecord(slotKey: slotKey) else {
                return nil
            }
            return makePersistedCoverage(record: record, sourceSnapshot: sourceSnapshot)
        } catch {
            return nil
        }
    }

    @MainActor
    func reconcileTranslationPresentationAfterCancellation(
        entryId: Int64,
        candidateSlotKeys: Set<TranslationSlotKey>
    ) async {
        guard displayedEntryId == entryId else {
            return
        }
        guard let snapshotContext = buildCurrentTranslationSnapshot(entryId: entryId) else {
            translationMode = .original
            hasPersistedTranslationForCurrentSlot = false
            hasResumableTranslationCheckpointForCurrentSlot = false
            return
        }

        let resolvedSlotKey: TranslationSlotKey
        if let currentSlot = translationCurrentSlotKey,
           currentSlot.entryId == entryId,
           (candidateSlotKeys.isEmpty || candidateSlotKeys.contains(currentSlot)) {
            resolvedSlotKey = currentSlot
        } else if let candidateSlot = candidateSlotKeys
            .filter({ $0.entryId == entryId })
            .sorted(by: { $0.targetLanguage < $1.targetLanguage })
            .first {
            resolvedSlotKey = candidateSlot
        } else {
            let targetLanguage = appModel.loadTranslationAgentDefaults().targetLanguage
            resolvedSlotKey = appModel.makeTranslationSlotKey(
                entryId: entryId,
                targetLanguage: targetLanguage
            )
        }

        translationCurrentSlotKey = resolvedSlotKey
        let coverage = await loadPersistedCoverage(
            slotKey: resolvedSlotKey,
            sourceSnapshot: snapshotContext.snapshot
        )
        let hasTranslatedSegments = coverage?.hasTranslatedSegments == true
        hasPersistedTranslationForCurrentSlot = hasTranslatedSegments
        hasResumableTranslationCheckpointForCurrentSlot = false
        translationMode = hasTranslatedSegments ? .bilingual : .original
        topBannerMessage = makeTerminalSuccessBanner(
            slotKey: resolvedSlotKey,
            coverage: coverage
        )
        if let coverage, hasTranslatedSegments {
            applyProjection(
                entryId: entryId,
                slotKey: resolvedSlotKey,
                sourceReaderHTML: snapshotContext.sourceReaderHTML,
                sourceSnapshot: snapshotContext.snapshot,
                translatedBySegmentID: coverage.translatedBySegmentID,
                pendingSegmentIDs: [],
                failedSegmentIDs: coverage.unresolvedSegmentIDs,
                pendingStatusText: nil,
                failedStatusText: AgentRuntimeProjection.translationNoContentStatus()
            )
        } else {
            setReaderHTML(snapshotContext.sourceReaderHTML)
        }
    }

    @MainActor
    func makeRetryFailedBannerAction(
        slotKey: TranslationSlotKey,
        failedSegmentIDs: Set<String>
    ) -> ReaderBannerMessage.BannerAction? {
        guard failedSegmentIDs.isEmpty == false else {
            return nil
        }
        return ReaderBannerMessage.BannerAction(
            label: String(localized: "Retry failed segments", bundle: bundle),
            handler: {
                Task {
                    await retryTranslationSegments(
                        entryId: slotKey.entryId,
                        slotKey: slotKey,
                        requestedSegmentIDs: failedSegmentIDs
                    )
                }
            }
        )
    }

    @MainActor
    func shouldProjectTranslation(owner: AgentRunOwner) -> Bool {
        AgentDisplayOwnershipPolicy.shouldProject(owner: owner, displayedEntryId: displayedEntryId)
    }

    @MainActor
    func shouldProjectEntry(_ entryId: Int64) -> Bool {
        AgentDisplayOwnershipPolicy.shouldProject(
            candidateEntryId: entryId,
            displayedEntryId: displayedEntryId
        )
    }

    func makeTranslationRunOwner(slotKey: TranslationSlotKey) -> AgentRunOwner {
        AgentRunOwner(
            taskKind: .translation,
            entryId: slotKey.entryId,
            slotKey: TranslationRuntimePolicy.makeRunOwnerSlotKey(slotKey)
        )
    }
}
