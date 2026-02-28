import SwiftUI

extension ReaderTranslationView {
    // MARK: - Mode Toggle

    func toggleTranslationMode() {
        guard appModel.isTranslationAgentAvailable else {
            let message = !appModel.isSummaryAgentAvailable
                ? String(localized: "Agents are not configured. Add a provider and model in Settings.", bundle: bundle)
                : String(localized: "Translation agent is not configured. Add a provider and model in Settings to enable translation.", bundle: bundle)
            topBannerMessage = ReaderBannerMessage(
                text: message,
                action: ReaderBannerMessage.BannerAction(label: String(localized: "Open Settings", bundle: bundle)) { openSettings() }
            )
            return
        }
        if isTranslationRunningForDisplayedEntry() {
            cancelTranslationRunForCurrentEntry()
            return
        }
        if translationMode == .original,
           hasResumableTranslationCheckpointForCurrentSlot {
            Task {
                await resumeTranslationCheckpointForCurrentEntry()
            }
            return
        }
        let nextMode = TranslationModePolicy.toggledMode(from: translationMode)
        translationMode = nextMode
        if nextMode == .bilingual {
            translationManualStartRequestedEntryId = entry?.id
        } else {
            translationManualStartRequestedEntryId = nil
            if let slotKey = translationCurrentSlotKey {
                let owner = makeTranslationRunOwner(slotKey: slotKey)
                translationQueuedRunPayloads.removeValue(forKey: owner)
                Task {
                    await appModel.agentRuntimeEngine.abandonWaiting(owner: owner)
                    await MainActor.run {
                        if translationPhaseByOwner[owner] == .waiting {
                            translationPhaseByOwner.removeValue(forKey: owner)
                        }
                    }
                }
            }
        }
        Task {
            await syncTranslationPresentationForCurrentEntry(allowAutoEnterBilingualForRunningEntry: false)
        }
    }

    @MainActor
    func cancelTranslationRunForCurrentEntry() {
        guard let entryId = displayedEntryId else {
            return
        }

        var ownersToCancel: [AgentRunOwner] = translationQueuedRunPayloads.keys.filter { $0.entryId == entryId }
        if let runningOwner = translationRunningOwner,
           runningOwner.entryId == entryId,
           ownersToCancel.contains(runningOwner) == false {
            ownersToCancel.append(runningOwner)
        }
        guard ownersToCancel.isEmpty == false else {
            return
        }

        var cancelledSlotKeys: Set<TranslationSlotKey> = []
        for owner in ownersToCancel {
            if let queuedSlotKey = translationQueuedRunPayloads[owner]?.slotKey {
                cancelledSlotKeys.insert(queuedSlotKey)
            } else if let runningSlotKey = TranslationRuntimePolicy.decodeRunOwnerSlot(owner) {
                cancelledSlotKeys.insert(runningSlotKey)
            }
        }

        for owner in ownersToCancel {
            translationQueuedRunPayloads.removeValue(forKey: owner)
            translationPhaseByOwner.removeValue(forKey: owner)
            translationProjectionStateByOwner.removeValue(forKey: owner)
            translationRetryMergeContextByOwner.removeValue(forKey: owner)
        }
        translationProjectionDebounceTask?.cancel()
        translationProjectionDebounceTask = nil

        let runningOwner = translationRunningOwner
        if runningOwner?.entryId == entryId {
            translationRunningOwner = nil
        }
        refreshRunningStateForCurrentEntry()

        Task {
            for owner in ownersToCancel {
                if let taskId = await MainActor.run(body: { translationTaskIDByOwner.removeValue(forKey: owner) }) {
                    await appModel.cancelTask(taskId)
                }
                _ = await appModel.agentRuntimeEngine.finish(
                    owner: owner,
                    terminalPhase: .cancelled,
                    reason: .cancelled
                )
            }
            await reconcileTranslationPresentationAfterCancellation(
                entryId: entryId,
                candidateSlotKeys: cancelledSlotKeys
            )
        }
    }

    @MainActor
    func resumeTranslationCheckpointForCurrentEntry() async {
        guard let entryId = entry?.id else {
            return
        }
        let resolvedSlotKey: TranslationSlotKey
        if let currentSlot = translationCurrentSlotKey,
           currentSlot.entryId == entryId {
            resolvedSlotKey = currentSlot
        } else {
            let targetLanguage = appModel.loadTranslationAgentDefaults().targetLanguage
            resolvedSlotKey = appModel.makeTranslationSlotKey(
                entryId: entryId,
                targetLanguage: targetLanguage
            )
            translationCurrentSlotKey = resolvedSlotKey
        }

        let unresolvedSegmentIDs = await resolveFailedSegmentIDs(
            entryId: entryId,
            slotKey: resolvedSlotKey
        )
        guard unresolvedSegmentIDs.isEmpty == false else {
            hasResumableTranslationCheckpointForCurrentSlot = false
            await syncTranslationPresentationForCurrentEntry(
                allowAutoEnterBilingualForRunningEntry: false
            )
            return
        }

        await retryTranslationSegments(
            entryId: entryId,
            slotKey: resolvedSlotKey,
            requestedSegmentIDs: unresolvedSegmentIDs
        )
    }

    // MARK: - Clear Translation

    @MainActor
    func clearTranslationForCurrentEntry() async {
        guard let entryId = entry?.id else {
            return
        }

        let targetLanguage = appModel.loadTranslationAgentDefaults().targetLanguage
        let slotKey = appModel.makeTranslationSlotKey(
            entryId: entryId,
            targetLanguage: targetLanguage
        )
        translationCurrentSlotKey = slotKey

        do {
            let deletedCount = try await appModel.clearTranslationRecords(
                entryId: slotKey.entryId,
                targetLanguage: slotKey.targetLanguage
            )
            if deletedCount == 0 {
                hasPersistedTranslationForCurrentSlot = false
                hasResumableTranslationCheckpointForCurrentSlot = false
                return
            }
            let owner = makeTranslationRunOwner(slotKey: slotKey)
            translationQueuedRunPayloads.removeValue(forKey: owner)
            translationPhaseByOwner.removeValue(forKey: owner)
            translationTaskIDByOwner.removeValue(forKey: owner)
            translationProjectionStateByOwner.removeValue(forKey: owner)
            translationRetryMergeContextByOwner.removeValue(forKey: owner)
            hasPersistedTranslationForCurrentSlot = false
            hasResumableTranslationCheckpointForCurrentSlot = false
            translationMode = .original
            await syncTranslationPresentationForCurrentEntry(allowAutoEnterBilingualForRunningEntry: false)
            await refreshTranslationClearAvailabilityForCurrentEntry()
        } catch {
            appModel.reportDebugIssue(
                title: "Clear Translation Failed",
                detail: error.localizedDescription,
                category: .task
            )
        }
    }

    // MARK: - Sync Presentation

    @MainActor
    func syncTranslationPresentationForCurrentEntry(
        allowAutoEnterBilingualForRunningEntry: Bool
    ) async {
        guard let entryId = displayedEntryId,
              let currentSourceReaderHTML = sourceReaderHTML else {
            return
        }

        let runningSlot = TranslationRuntimePolicy.decodeRunOwnerSlot(translationRunningOwner)
        let hasRunningTranslationForCurrentEntry = runningSlot?.entryId == entryId

        if translationMode != .bilingual {
            if hasRunningTranslationForCurrentEntry && allowAutoEnterBilingualForRunningEntry {
                translationMode = .bilingual
            } else {
                setReaderHTML(currentSourceReaderHTML)
                return
            }
        }

        let snapshot: TranslationSourceSegmentsSnapshot
        let headerSourceText = translationHeaderSourceText(for: entry, renderedHTML: currentSourceReaderHTML)
        do {
            let baseSnapshot = try TranslationSegmentExtractor.extractFromRenderedHTML(
                entryId: entryId,
                renderedHTML: currentSourceReaderHTML
            )
            snapshot = makeTranslationSnapshot(
                baseSnapshot: baseSnapshot,
                headerSourceText: headerSourceText
            )
        } catch {
            setReaderHTML(currentSourceReaderHTML)
            return
        }

        let targetLanguage: String
        let slotKey: TranslationSlotKey
        if let runningSlot,
           runningSlot.entryId == entryId {
            targetLanguage = runningSlot.targetLanguage
            slotKey = runningSlot
        } else if let currentSlot = translationCurrentSlotKey,
                  currentSlot.entryId == entryId {
            targetLanguage = currentSlot.targetLanguage
            slotKey = currentSlot
        } else {
            targetLanguage = appModel.loadTranslationAgentDefaults().targetLanguage
            slotKey = appModel.makeTranslationSlotKey(
                entryId: entryId,
                targetLanguage: targetLanguage
            )
        }
        translationCurrentSlotKey = slotKey
        let owner = makeTranslationRunOwner(slotKey: slotKey)
        if translationRunningOwner == owner,
           let projectionState = translationProjectionStateByOwner[owner] {
            hasResumableTranslationCheckpointForCurrentSlot = false
            applyProjection(
                entryId: entryId,
                slotKey: slotKey,
                sourceReaderHTML: currentSourceReaderHTML,
                sourceSnapshot: projectionState.sourceSnapshot,
                translatedBySegmentID: projectionState.translatedBySegmentID,
                pendingSegmentIDs: projectionState.pendingSegmentIDs,
                failedSegmentIDs: projectionState.failedSegmentIDs,
                pendingStatusText: AgentRuntimeProjection.translationStatusText(for: .generating),
                failedStatusText: AgentRuntimeProjection.translationNoContentStatus()
            )
            return
        }

        await runTranslationActivation(
            entryId: entryId,
            slotKey: slotKey,
            snapshot: snapshot,
            sourceReaderHTML: currentSourceReaderHTML,
            headerSourceText: headerSourceText,
            targetLanguage: targetLanguage
        )
    }

    @MainActor
    func runTranslationActivation(
        entryId: Int64,
        slotKey: TranslationSlotKey,
        snapshot: TranslationSourceSegmentsSnapshot,
        sourceReaderHTML: String,
        headerSourceText: String?,
        targetLanguage: String
    ) async {
        var persistedRecord: TranslationStoredRecord?
        let context = AgentEntryActivationContext(
            autoEnabled: translationManualStartRequestedEntryId == entryId,
            displayedEntryId: displayedEntryId,
            candidateEntryId: entryId
        )

        await AgentEntryActivation.run(
            context: context,
            checkPersistedState: {
                do {
                    persistedRecord = try await appModel.loadTranslationRecord(slotKey: slotKey)
                    return persistedRecord == nil ? .renderableMissing : .renderableAvailable
                } catch {
                    return .fetchFailed
                }
            },
            onProjectPersisted: {
                guard shouldProjectEntry(entryId) else {
                    return
                }
                guard let record = persistedRecord else {
                    return
                }
                let coverage = makePersistedCoverage(record: record, sourceSnapshot: snapshot)
                let showResumeAction = shouldOfferResumeTranslation(
                    record: record,
                    coverage: coverage
                )
                let isCheckpointRunning = record.isCheckpointRunning
                hasPersistedTranslationForCurrentSlot = coverage.hasTranslatedSegments
                hasResumableTranslationCheckpointForCurrentSlot = showResumeAction
                translationMode = (coverage.hasTranslatedSegments || isCheckpointRunning) ? .bilingual : .original
                topBannerMessage = showResumeAction
                    ? makeResumeTranslationBanner(
                        slotKey: slotKey,
                        unresolvedSegmentIDs: coverage.unresolvedSegmentIDs
                    )
                    : makeTerminalSuccessBanner(
                        slotKey: slotKey,
                        coverage: coverage
                    )
                if coverage.hasTranslatedSegments || isCheckpointRunning {
                    let pendingSegmentIDs = isCheckpointRunning ? coverage.unresolvedSegmentIDs : []
                    let failedSegmentIDs = isCheckpointRunning ? [] : coverage.unresolvedSegmentIDs
                    applyProjection(
                        entryId: entryId,
                        slotKey: slotKey,
                        sourceReaderHTML: sourceReaderHTML,
                        sourceSnapshot: snapshot,
                        translatedBySegmentID: coverage.translatedBySegmentID,
                        pendingSegmentIDs: pendingSegmentIDs,
                        failedSegmentIDs: failedSegmentIDs,
                        pendingStatusText: nil,
                        failedStatusText: AgentRuntimeProjection.translationNoContentStatus()
                    )
                } else {
                    setReaderHTML(sourceReaderHTML)
                }
                let owner = makeTranslationRunOwner(slotKey: slotKey)
                translationPhaseByOwner.removeValue(forKey: owner)
            },
            onRequestRun: {
                guard shouldProjectEntry(entryId) else {
                    return
                }
                hasResumableTranslationCheckpointForCurrentSlot = false
                await renderTranslationMissingState(
                    entryId: entryId,
                    slotKey: slotKey,
                    snapshot: snapshot,
                    sourceReaderHTML: sourceReaderHTML,
                    headerSourceText: headerSourceText,
                    targetLanguage: targetLanguage,
                    hasManualRequest: true
                )
            },
            onSkip: {
                guard shouldProjectEntry(entryId) else {
                    return
                }
                hasResumableTranslationCheckpointForCurrentSlot = false
                await renderTranslationMissingState(
                    entryId: entryId,
                    slotKey: slotKey,
                    snapshot: snapshot,
                    sourceReaderHTML: sourceReaderHTML,
                    headerSourceText: headerSourceText,
                    targetLanguage: targetLanguage,
                    hasManualRequest: false
                )
            },
            onShowFetchFailedRetry: {
                guard shouldProjectEntry(entryId) else {
                    return
                }
                hasPersistedTranslationForCurrentSlot = false
                hasResumableTranslationCheckpointForCurrentSlot = false
                topBannerMessage = ReaderBannerMessage(text: AgentRuntimeProjection.translationFetchFailedRetryStatus())
                let owner = makeTranslationRunOwner(slotKey: slotKey)
                translationPhaseByOwner.removeValue(forKey: owner)
                applyProjection(
                    entryId: entryId,
                    slotKey: slotKey,
                    sourceReaderHTML: sourceReaderHTML,
                    sourceSnapshot: snapshot,
                    translatedBySegmentID: [:],
                    pendingSegmentIDs: [],
                    failedSegmentIDs: [],
                    pendingStatusText: nil,
                    failedStatusText: nil,
                    defaultMissingStatusText: AgentRuntimeProjection.translationNoContentStatus()
                )
            }
        )
    }

    @MainActor
    func renderTranslationMissingState(
        entryId: Int64,
        slotKey: TranslationSlotKey,
        snapshot: TranslationSourceSegmentsSnapshot,
        sourceReaderHTML: String,
        headerSourceText: String?,
        targetLanguage: String,
        hasManualRequest: Bool
    ) async {
        hasPersistedTranslationForCurrentSlot = false
        hasResumableTranslationCheckpointForCurrentSlot = false
        let owner = makeTranslationRunOwner(slotKey: slotKey)
        let missingStatusText: String
        if hasManualRequest {
            translationManualStartRequestedEntryId = nil
            guard snapshot.segments.isEmpty == false else {
                translationMode = .original
                setReaderHTML(sourceReaderHTML)
                return
            }
            missingStatusText = await requestTranslationRun(
                owner: owner,
                slotKey: slotKey,
                snapshot: snapshot,
                projectionSnapshot: snapshot,
                targetLanguage: targetLanguage
            )
        } else {
            missingStatusText = await currentTranslationMissingStatusText(for: owner)
        }

        applyProjection(
            entryId: entryId,
            slotKey: slotKey,
            sourceReaderHTML: sourceReaderHTML,
            sourceSnapshot: snapshot,
            translatedBySegmentID: [:],
            pendingSegmentIDs: [],
            failedSegmentIDs: [],
            pendingStatusText: nil,
            failedStatusText: nil,
            defaultMissingStatusText: missingStatusText
        )
    }

    @MainActor
    func refreshTranslationClearAvailabilityForCurrentEntry() async {
        guard let entryId = displayedEntryId else {
            hasPersistedTranslationForCurrentSlot = false
            hasResumableTranslationCheckpointForCurrentSlot = false
            return
        }

        if let currentSlot = translationCurrentSlotKey,
           currentSlot.entryId == entryId {
            do {
                if let record = try await appModel.loadTranslationRecord(slotKey: currentSlot) {
                    hasPersistedTranslationForCurrentSlot = record.segments.contains {
                        $0.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    }
                    hasResumableTranslationCheckpointForCurrentSlot = record.isCheckpointRunning
                } else {
                    hasPersistedTranslationForCurrentSlot = false
                    hasResumableTranslationCheckpointForCurrentSlot = false
                }
            } catch {
                hasPersistedTranslationForCurrentSlot = false
                hasResumableTranslationCheckpointForCurrentSlot = false
            }
            return
        }

        let targetLanguage = appModel.loadTranslationAgentDefaults().targetLanguage
        let slotKey = appModel.makeTranslationSlotKey(
            entryId: entryId,
            targetLanguage: targetLanguage
        )
        translationCurrentSlotKey = slotKey

        do {
            if let record = try await appModel.loadTranslationRecord(slotKey: slotKey) {
                hasPersistedTranslationForCurrentSlot = record.segments.contains {
                    $0.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                }
                hasResumableTranslationCheckpointForCurrentSlot = record.isCheckpointRunning
            } else {
                hasPersistedTranslationForCurrentSlot = false
                hasResumableTranslationCheckpointForCurrentSlot = false
            }
        } catch {
            hasPersistedTranslationForCurrentSlot = false
            hasResumableTranslationCheckpointForCurrentSlot = false
        }
    }
}
