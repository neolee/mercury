//
//  ReaderTranslationView.swift
//  Mercury
//
//  Created by Neo on 2026/2/4.
//

import SwiftUI
import AppKit
import CryptoKit

// MARK: - Supporting Types

private struct TranslationQueuedRunRequest: Sendable {
    let taskId: UUID
    let owner: AgentRunOwner
    let slotKey: TranslationSlotKey
    let executionSnapshot: ReaderSourceSegmentsSnapshot
    let projectionSnapshot: ReaderSourceSegmentsSnapshot
    let targetLanguage: String
    let initialTranslatedBySegmentID: [String: String]
    let initialPendingSegmentIDs: Set<String>
    let initialFailedSegmentIDs: Set<String>
    let isRetry: Bool
}

private struct TranslationProjectionState: Sendable {
    let slotKey: TranslationSlotKey
    let sourceSnapshot: ReaderSourceSegmentsSnapshot
    var translatedBySegmentID: [String: String]
    var pendingSegmentIDs: Set<String>
    var failedSegmentIDs: Set<String>
}

private struct TranslationRetryMergeContext: Sendable {
    let sourceSnapshot: ReaderSourceSegmentsSnapshot
    let baseTranslatedBySegmentID: [String: String]
}

private struct TranslationPersistedCoverage: Sendable {
    let translatedBySegmentID: [String: String]
    let unresolvedSegmentIDs: Set<String>

    var hasTranslatedSegments: Bool {
        translatedBySegmentID.isEmpty == false
    }
}

private enum TranslationReaderAction: Sendable {
    case retrySegment(entryId: Int64, slotKey: TranslationSlotKey, segmentId: String)
    case retryFailed(entryId: Int64, slotKey: TranslationSlotKey)
}

// MARK: - ReaderTranslationView

/// Zero-height view that manages translation agent state, toolbar items, and
/// `readerHTML` / `sourceReaderHTML` mutations for the reader detail container.
///
/// Renders as `Color.clear` with `.frame(height: 0)` so it occupies no visual
/// space while still contributing toolbar items and lifecycle hooks to the view
/// hierarchy.
struct ReaderTranslationView: View {
    let entry: Entry?
    @Binding var displayedEntryId: Int64?
    @Binding var readerHTML: String?
    @Binding var sourceReaderHTML: String?
    @Binding var topBannerMessage: ReaderBannerMessage?
    let readingModeRaw: String

    @EnvironmentObject var appModel: AppModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.localizationBundle) var bundle
    @Binding var translationMode: TranslationMode
    @Binding var hasPersistedTranslationForCurrentSlot: Bool
    @Binding var hasResumableTranslationCheckpointForCurrentSlot: Bool
    @Binding var translationToggleRequested: Bool
    @Binding var translationClearRequested: Bool
    @Binding var translationActionURL: URL?
    @Binding var isTranslationRunningForCurrentEntry: Bool

    @State private var translationCurrentSlotKey: TranslationSlotKey?
    @State private var translationManualStartRequestedEntryId: Int64?
    @State private var translationRunningOwner: AgentRunOwner?
    @State private var translationQueuedRunPayloads: [AgentRunOwner: TranslationQueuedRunRequest] = [:]
    @State private var translationTaskIDByOwner: [AgentRunOwner: UUID] = [:]
    @State private var translationProjectionStateByOwner: [AgentRunOwner: TranslationProjectionState] = [:]
    @State private var translationRetryMergeContextByOwner: [AgentRunOwner: TranslationRetryMergeContext] = [:]
    @State private var translationPhaseByOwner: [AgentRunOwner: AgentRunPhase] = [:]
    @State private var translationNoticeByOwner: [AgentRunOwner: String] = [:]
    @State private var translationProjectionDebounceTask: Task<Void, Never>?

    var body: some View {
        Color.clear
            .onChange(of: translationToggleRequested) { _, requested in
                guard requested else { return }
                translationToggleRequested = false
                toggleTranslationMode()
            }
            .onChange(of: translationClearRequested) { _, requested in
                guard requested else { return }
                translationClearRequested = false
                Task { await clearTranslationForCurrentEntry() }
            }
            .onChange(of: displayedEntryId) { previousId, newId in
                hasPersistedTranslationForCurrentSlot = false
                hasResumableTranslationCheckpointForCurrentSlot = false
                translationCurrentSlotKey = nil
                translationMode = .original
                translationManualStartRequestedEntryId = nil
                translationRunningOwner = nil
                translationNoticeByOwner.removeAll()
                translationTaskIDByOwner.removeAll()
                translationProjectionStateByOwner.removeAll()
                translationRetryMergeContextByOwner.removeAll()
                translationProjectionDebounceTask?.cancel()
                translationProjectionDebounceTask = nil
                refreshRunningStateForCurrentEntry()
                if let previousId {
                    Task {
                        await abandonTranslationWaiting(for: previousId, nextSelectedEntryId: newId)
                    }
                }
            }
            .onChange(of: readingModeRaw) { _, newValue in
                let mode = ReadingMode(rawValue: newValue) ?? .reader
                if mode != .reader {
                    translationMode = .original
                } else {
                    Task {
                        await syncTranslationPresentationForCurrentEntry(allowAutoEnterBilingualForRunningEntry: true)
                    }
                }
            }
            .onChange(of: sourceReaderHTML) { _, newHTML in
                guard newHTML != nil else { return }
                Task {
                    await syncTranslationPresentationForCurrentEntry(allowAutoEnterBilingualForRunningEntry: true)
                    await refreshTranslationClearAvailabilityForCurrentEntry()
                }
            }
            .onChange(of: translationActionURL) { _, actionURL in
                guard let actionURL else { return }
                translationActionURL = nil
                Task {
                    await handleTranslationActionURL(actionURL)
                }
            }
            .task {
                await observeRuntimeEventsForTranslation()
            }
            .onReceive(NotificationCenter.default.publisher(for: .translationAgentDefaultsDidChange)) { _ in
                Task {
                    await syncTranslationPresentationForCurrentEntry(allowAutoEnterBilingualForRunningEntry: false)
                    await refreshTranslationClearAvailabilityForCurrentEntry()
                }
            }
    }

    // MARK: - Mode Toggle

    private func toggleTranslationMode() {
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
    private func cancelTranslationRunForCurrentEntry() {
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
    private func resumeTranslationCheckpointForCurrentEntry() async {
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
    private func clearTranslationForCurrentEntry() async {
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
    private func syncTranslationPresentationForCurrentEntry(
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

        let snapshot: ReaderSourceSegmentsSnapshot
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
    private func runTranslationActivation(
        entryId: Int64,
        slotKey: TranslationSlotKey,
        snapshot: ReaderSourceSegmentsSnapshot,
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
    private func renderTranslationMissingState(
        entryId: Int64,
        slotKey: TranslationSlotKey,
        snapshot: ReaderSourceSegmentsSnapshot,
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
    private func refreshTranslationClearAvailabilityForCurrentEntry() async {
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

    // MARK: - Request / Run

    @MainActor
    private func requestTranslationRun(
        owner: AgentRunOwner,
        slotKey: TranslationSlotKey,
        snapshot: ReaderSourceSegmentsSnapshot,
        projectionSnapshot: ReaderSourceSegmentsSnapshot,
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
    private func currentTranslationMissingStatusText(
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
    private func startTranslationRun(_ request: TranslationQueuedRunRequest, activeToken: String) {
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
    private func handleTranslationRunEvent(
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
    private func isTranslationRunningForDisplayedEntry() -> Bool {
        guard let displayedEntryId else {
            return false
        }
        guard let runningOwner = translationRunningOwner else {
            return false
        }
        return runningOwner.entryId == displayedEntryId
    }

    @MainActor
    private func refreshRunningStateForCurrentEntry() {
        isTranslationRunningForCurrentEntry = isTranslationRunningForDisplayedEntry()
    }

    @MainActor
    private func scheduleProgressiveProjectionUpdate(owner: AgentRunOwner) {
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
    private func finalizeProjectionStateForTerminal(owner: AgentRunOwner) -> TranslationProjectionState? {
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
    private func renderTerminalProjectionIfNeeded(
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
    private func makeTerminalSuccessBanner(
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

    private func shouldOfferResumeTranslation(
        record: TranslationStoredRecord,
        coverage: TranslationPersistedCoverage
    ) -> Bool {
        record.isCheckpointRunning && coverage.unresolvedSegmentIDs.isEmpty == false
    }

    @MainActor
    private func makeResumeTranslationBanner(
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

    private func makePersistedCoverage(
        record: TranslationStoredRecord,
        sourceSnapshot: ReaderSourceSegmentsSnapshot
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

    private func translatableSegmentIDs(in snapshot: ReaderSourceSegmentsSnapshot) -> Set<String> {
        Set(snapshot.segments.map(\.sourceSegmentId))
    }

    private func loadPersistedCoverage(
        slotKey: TranslationSlotKey,
        sourceSnapshot: ReaderSourceSegmentsSnapshot
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
    private func reconcileTranslationPresentationAfterCancellation(
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
    private func makeRetryFailedBannerAction(
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
    private func shouldProjectTranslation(owner: AgentRunOwner) -> Bool {
        AgentDisplayOwnershipPolicy.shouldProject(owner: owner, displayedEntryId: displayedEntryId)
    }

    @MainActor
    private func shouldProjectEntry(_ entryId: Int64) -> Bool {
        AgentDisplayOwnershipPolicy.shouldProject(
            candidateEntryId: entryId,
            displayedEntryId: displayedEntryId
        )
    }

    private func makeTranslationRunOwner(slotKey: TranslationSlotKey) -> AgentRunOwner {
        AgentRunOwner(
            taskKind: .translation,
            entryId: slotKey.entryId,
            slotKey: TranslationRuntimePolicy.makeRunOwnerSlotKey(slotKey)
        )
    }

    @MainActor
    private func applyProjection(
        entryId: Int64,
        slotKey: TranslationSlotKey,
        sourceReaderHTML: String,
        sourceSnapshot: ReaderSourceSegmentsSnapshot,
        translatedBySegmentID: [String: String],
        pendingSegmentIDs: Set<String>,
        failedSegmentIDs: Set<String>,
        pendingStatusText: String?,
        failedStatusText: String?,
        defaultMissingStatusText: String? = nil
    ) {
        let headerTranslatedText = translatedBySegmentID[Self.translationHeaderSegmentID]
        let hasHeaderSegment = sourceSnapshot.segments.contains { $0.sourceSegmentId == Self.translationHeaderSegmentID }
        let headerStatusText: String? = {
            guard hasHeaderSegment else {
                return nil
            }
            if let headerTranslatedText,
               headerTranslatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                return nil
            }
            if pendingSegmentIDs.contains(Self.translationHeaderSegmentID) {
                return pendingStatusText
            }
            if failedSegmentIDs.contains(Self.translationHeaderSegmentID) {
                return failedStatusText
            }
            return defaultMissingStatusText
        }()

        let bodyTranslatedBySegmentID = translatedBySegmentID.filter { key, _ in
            key != Self.translationHeaderSegmentID
        }
        let bodyPendingSegmentIDs = Set(
            pendingSegmentIDs.filter { $0 != Self.translationHeaderSegmentID }
        )
        let bodyFailedSegmentIDs = Set(
            failedSegmentIDs.filter { $0 != Self.translationHeaderSegmentID }
        )

        do {
            let composed = try TranslationBilingualComposer.compose(
                renderedHTML: sourceReaderHTML,
                entryId: entryId,
                translatedBySegmentID: bodyTranslatedBySegmentID,
                missingStatusText: defaultMissingStatusText,
                headerTranslatedText: headerTranslatedText,
                headerStatusText: headerStatusText,
                pendingSegmentIDs: bodyPendingSegmentIDs,
                failedSegmentIDs: bodyFailedSegmentIDs,
                pendingStatusText: pendingStatusText,
                failedStatusText: failedStatusText,
                headerFailedSegmentID: failedSegmentIDs.contains(Self.translationHeaderSegmentID)
                    ? Self.translationHeaderSegmentID
                    : nil,
                retryActionContext: TranslationRetryActionContext(
                    entryId: slotKey.entryId,
                    slotKey: slotKey.targetLanguage
                )
            )
            let visibleHTML = ensureVisibleTranslationBlockIfNeeded(
                composedHTML: composed.html,
                translatedBySegmentID: bodyTranslatedBySegmentID,
                headerTranslatedText: headerTranslatedText,
                missingStatusText: pendingStatusText ?? failedStatusText ?? defaultMissingStatusText
            )
            setReaderHTML(visibleHTML)
        } catch {
            appModel.reportDebugIssue(
                title: "Translation Render Failed",
                detail: "entryId=\(entryId)\nslot=\(slotKey.targetLanguage)\nreason=\(error.localizedDescription)",
                category: .task
            )
        }
    }

    private func ensureVisibleTranslationBlockIfNeeded(
        composedHTML: String,
        translatedBySegmentID: [String: String],
        headerTranslatedText: String?,
        missingStatusText: String?
    ) -> String {
        let marker = "mercury-translation-block"
        if composedHTML.contains(marker) {
            return composedHTML
        }

        let fallbackText = preferredVisibleTranslationText(
            translatedBySegmentID: translatedBySegmentID,
            headerTranslatedText: headerTranslatedText,
            missingStatusText: missingStatusText
        )
        guard let fallbackText,
              fallbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return composedHTML
        }

        let escaped = escapeHTMLForTranslationFallback(fallbackText)
        let blockHTML = """
        <div class=\"mercury-translation-block mercury-translation-ready\"><div class=\"mercury-translation-text\">\(escaped)</div></div>
        """
        if composedHTML.contains("<article class=\"reader\">") {
            return composedHTML.replacingOccurrences(
                of: "<article class=\"reader\">",
                with: "<article class=\"reader\">\n\(blockHTML)",
                options: [],
                range: composedHTML.range(of: "<article class=\"reader\">")
            )
        }
        if composedHTML.contains("<body>") {
            return composedHTML.replacingOccurrences(
                of: "<body>",
                with: "<body>\n\(blockHTML)",
                options: [],
                range: composedHTML.range(of: "<body>")
            )
        }
        return blockHTML + composedHTML
    }

    private func preferredVisibleTranslationText(
        translatedBySegmentID: [String: String],
        headerTranslatedText: String?,
        missingStatusText: String?
    ) -> String? {
        if let headerTranslatedText,
           headerTranslatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return headerTranslatedText
        }

        if let translated = translatedBySegmentID
            .sorted(by: { lhs, rhs in lhs.key < rhs.key })
            .map({ $0.value })
            .first(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }) {
            return translated
        }

        if let missingStatusText,
           missingStatusText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return missingStatusText
        }
        return nil
    }

    private func escapeHTMLForTranslationFallback(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    // MARK: - Runtime Events

    private func abandonTranslationWaiting(for previousEntryId: Int64, nextSelectedEntryId: Int64?) async {
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

    private func observeRuntimeEventsForTranslation() async {
        let stream = await appModel.agentRuntimeEngine.events()
        for await event in stream {
            await MainActor.run {
                handleTranslationRuntimeEvent(event)
            }
        }
    }

    @MainActor
    private func handleTranslationRuntimeEvent(_ event: AgentRuntimeEvent) {
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
    private func applyPersistedTranslationForCompletedRun(
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
    private func mergeRetryPersistedTranslationIfNeeded(request: TranslationQueuedRunRequest) async {
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

    private func decodeRuntimeSnapshotDictionary(_ raw: String?) -> [String: String] {
        guard let raw,
              let data = raw.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return snapshot
    }

    @MainActor
    private func handleTranslationActionURL(_ url: URL) async {
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

    private func parseTranslationReaderAction(from url: URL) -> TranslationReaderAction? {
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
    private func retryTranslationSegments(
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
        let retrySnapshot = ReaderSourceSegmentsSnapshot(
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
    private func resolveFailedSegmentIDs(
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
    private func buildCurrentTranslationSnapshot(
        entryId: Int64
    ) -> (sourceReaderHTML: String, snapshot: ReaderSourceSegmentsSnapshot)? {
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

    private func translationHeaderSourceText(for entry: Entry?, renderedHTML: String?) -> String? {
        TranslationHeaderTextBuilder.buildHeaderSourceText(
            entryTitle: entry?.title,
            entryAuthor: entry?.author,
            renderedHTML: renderedHTML
        )
    }

    private func makeTranslationSnapshot(
        baseSnapshot: ReaderSourceSegmentsSnapshot,
        headerSourceText: String?
    ) -> ReaderSourceSegmentsSnapshot {
        guard let headerSourceText,
              headerSourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return baseSnapshot
        }

        var segments = baseSnapshot.segments
        let headerSegment = ReaderSourceSegment(
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

        return ReaderSourceSegmentsSnapshot(
            entryId: baseSnapshot.entryId,
            sourceContentHash: combinedHash,
            segmenterVersion: baseSnapshot.segmenterVersion,
            segments: segments
        )
    }

    // MARK: - HTML Helpers

    private func setReaderHTML(_ html: String?) {
        if readerHTML == html {
            return
        }
        readerHTML = html
    }

    // MARK: - Statics

    private static let translationHeaderSegmentID = "seg_meta_title_author"
}
