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
    let owner: AgentRunOwner
    let slotKey: TranslationSlotKey
    let snapshot: ReaderSourceSegmentsSnapshot
    let targetLanguage: String
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
    @Binding var topErrorBannerText: String?
    let readingModeRaw: String

    @EnvironmentObject var appModel: AppModel

    @Binding var translationMode: TranslationMode
    @Binding var hasPersistedTranslationForCurrentSlot: Bool
    @Binding var translationToggleRequested: Bool
    @Binding var translationClearRequested: Bool

    @State private var translationCurrentSlotKey: TranslationSlotKey?
    @State private var translationManualStartRequestedEntryId: Int64?
    @State private var translationRunningOwner: AgentRunOwner?
    @State private var translationQueuedRunPayloads: [AgentRunOwner: TranslationQueuedRunRequest] = [:]
    @State private var translationStatusByOwner: [AgentRunOwner: String] = [:]

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
                translationCurrentSlotKey = nil
                translationMode = .original
                translationManualStartRequestedEntryId = nil
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
        let nextMode = TranslationModePolicy.toggledMode(from: translationMode)
        translationMode = nextMode
        if nextMode == .bilingual {
            translationManualStartRequestedEntryId = entry?.id
            clearTranslationTerminalStatuses()
        } else {
            translationManualStartRequestedEntryId = nil
            if let slotKey = translationCurrentSlotKey {
                let owner = makeTranslationRunOwner(slotKey: slotKey)
                translationQueuedRunPayloads.removeValue(forKey: owner)
                Task {
                    await appModel.agentRuntimeEngine.abandonWaiting(owner: owner)
                    await MainActor.run {
                        if let status = translationStatusByOwner[owner],
                           AgentRuntimeProjection.isTranslationWaitingStatus(status) {
                            translationStatusByOwner[owner] = AgentRuntimeProjection.translationNoContentStatus()
                        }
                    }
                }
            }
        }
        Task {
            await syncTranslationPresentationForCurrentEntry(allowAutoEnterBilingualForRunningEntry: false)
        }
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
                return
            }
            let owner = makeTranslationRunOwner(slotKey: slotKey)
            translationQueuedRunPayloads.removeValue(forKey: owner)
            translationStatusByOwner[owner] = nil
            hasPersistedTranslationForCurrentSlot = false
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
                hasPersistedTranslationForCurrentSlot = true
                let translatedBySegmentID = Dictionary(uniqueKeysWithValues: record.segments.map {
                    ($0.sourceSegmentId, $0.translatedText)
                })
                let headerTranslatedText = translatedBySegmentID[Self.translationHeaderSegmentID]
                let bodyTranslatedBySegmentID = translatedBySegmentID.filter { key, _ in
                    key != Self.translationHeaderSegmentID
                }
                applyTranslationProjection(
                    entryId: entryId,
                    slotKey: slotKey,
                    sourceReaderHTML: sourceReaderHTML,
                    translatedBySegmentID: bodyTranslatedBySegmentID,
                    missingStatusText: nil,
                    headerTranslatedText: headerTranslatedText,
                    headerStatusText: nil
                )
                let owner = makeTranslationRunOwner(slotKey: slotKey)
                translationStatusByOwner[owner] = nil
            },
            onRequestRun: {
                guard shouldProjectEntry(entryId) else {
                    return
                }
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
                topErrorBannerText = AgentRuntimeProjection.translationFetchFailedRetryStatus()
                let owner = makeTranslationRunOwner(slotKey: slotKey)
                translationStatusByOwner[owner] = AgentRuntimeProjection.translationNoContentStatus()
                applyTranslationProjection(
                    entryId: entryId,
                    slotKey: slotKey,
                    sourceReaderHTML: sourceReaderHTML,
                    translatedBySegmentID: [:],
                    missingStatusText: AgentRuntimeProjection.translationNoContentStatus(),
                    headerTranslatedText: nil,
                    headerStatusText: headerSourceText == nil ? nil : AgentRuntimeProjection.translationNoContentStatus()
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
        let owner = makeTranslationRunOwner(slotKey: slotKey)
        let missingStatusText: String
        if hasManualRequest {
            translationManualStartRequestedEntryId = nil
            missingStatusText = await requestTranslationRun(
                owner: owner,
                slotKey: slotKey,
                snapshot: snapshot,
                targetLanguage: targetLanguage
            )
        } else {
            missingStatusText = await currentTranslationMissingStatusText(for: owner)
            translationStatusByOwner[owner] = missingStatusText
        }

        applyTranslationProjection(
            entryId: entryId,
            slotKey: slotKey,
            sourceReaderHTML: sourceReaderHTML,
            translatedBySegmentID: [:],
            missingStatusText: missingStatusText,
            headerTranslatedText: nil,
            headerStatusText: headerSourceText == nil ? nil : missingStatusText
        )
    }

    @MainActor
    private func refreshTranslationClearAvailabilityForCurrentEntry() async {
        guard let entryId = displayedEntryId else {
            hasPersistedTranslationForCurrentSlot = false
            return
        }

        if let currentSlot = translationCurrentSlotKey,
           currentSlot.entryId == entryId {
            do {
                hasPersistedTranslationForCurrentSlot = try await appModel.loadTranslationRecord(slotKey: currentSlot) != nil
            } catch {
                hasPersistedTranslationForCurrentSlot = false
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
            hasPersistedTranslationForCurrentSlot = try await appModel.loadTranslationRecord(slotKey: slotKey) != nil
        } catch {
            hasPersistedTranslationForCurrentSlot = false
        }
    }

    // MARK: - Request / Run

    @MainActor
    private func requestTranslationRun(
        owner: AgentRunOwner,
        slotKey: TranslationSlotKey,
        snapshot: ReaderSourceSegmentsSnapshot,
        targetLanguage: String
    ) async -> String {
        let request = TranslationQueuedRunRequest(
            owner: owner,
            slotKey: slotKey,
            snapshot: snapshot,
            targetLanguage: targetLanguage
        )
        let decision = await appModel.agentRuntimeEngine.submit(
            spec: AgentTaskSpec(
                owner: owner,
                requestSource: .manual,
                queuePolicy: AgentQueuePolicy(
                    concurrentLimitPerKind: AgentRuntimeContract.baselineConcurrentLimitPerKind,
                    waitingCapacityPerKind: AgentRuntimeContract.baselineWaitingCapacityPerKind,
                    replacementWhenFull: .latestOnlyReplaceWaiting
                ),
                visibilityPolicy: .selectedEntryOnly
            )
        )
        let startToken: String?
        if case .startNow = decision {
            startToken = await appModel.agentRuntimeEngine.activeToken(for: owner)
        } else {
            startToken = nil
        }
        switch decision {
        case .startNow:
            translationQueuedRunPayloads.removeValue(forKey: owner)
            startTranslationRun(request, activeToken: startToken ?? "")
            let status = AgentRuntimeProjection.translationStatusText(for: .requesting)
            translationStatusByOwner[owner] = status
            return status
        case .queuedWaiting, .alreadyWaiting:
            translationQueuedRunPayloads[owner] = request
            let waitingText = AgentRuntimeProjection.translationStatusText(for: .waiting)
            translationStatusByOwner[owner] = waitingText
            return waitingText
        case .alreadyActive:
            let status = AgentRuntimeProjection.translationStatusTextForAlreadyActive(
                cachedStatus: translationStatusByOwner[owner]
            )
            translationStatusByOwner[owner] = status
            return status
        }
    }

    @MainActor
    private func currentTranslationMissingStatusText(
        for owner: AgentRunOwner
    ) async -> String {
        let projection = await appModel.agentRuntimeEngine.statusProjection(for: owner)
        return AgentRuntimeProjection.translationMissingStatusText(
            projection: projection,
            cachedStatus: translationStatusByOwner[owner],
            transientStatuses: Self.translationTransientStatuses,
            noContentStatus: AgentRuntimeProjection.translationNoContentStatus(),
            fetchFailedRetryStatus: AgentRuntimeProjection.translationFetchFailedRetryStatus()
        )
    }

    @MainActor
    private func startTranslationRun(_ request: TranslationQueuedRunRequest, activeToken: String) {
        translationRunningOwner = request.owner
        translationCurrentSlotKey = request.slotKey
        translationStatusByOwner[request.owner] = AgentRuntimeProjection.translationStatusText(for: .requesting)
        topErrorBannerText = nil

        let capturedToken = activeToken
        Task {
            _ = await appModel.startTranslationRun(
                request: TranslationRunRequest(
                    entryId: request.snapshot.entryId,
                    targetLanguage: request.targetLanguage,
                    sourceSnapshot: request.snapshot
                ),
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
        case .started:
            translationStatusByOwner[request.owner] = AgentRuntimeProjection.translationStatusText(for: .requesting)
            Task {
                await appModel.agentRuntimeEngine.updatePhase(owner: request.owner, phase: .requesting, activeToken: activeToken)
                let shouldProject = await MainActor.run { shouldProjectTranslation(owner: request.owner) }
                guard shouldProject else { return }
                await syncTranslationPresentationForCurrentEntry(allowAutoEnterBilingualForRunningEntry: false)
            }
        case .strategySelected:
            translationStatusByOwner[request.owner] = AgentRuntimeProjection.translationStatusText(for: .generating)
            Task {
                await appModel.agentRuntimeEngine.updatePhase(owner: request.owner, phase: .generating, activeToken: activeToken)
                let shouldProject = await MainActor.run { shouldProjectTranslation(owner: request.owner) }
                guard shouldProject else { return }
                await syncTranslationPresentationForCurrentEntry(allowAutoEnterBilingualForRunningEntry: false)
            }
        case .token:
            let generatingStatus = AgentRuntimeProjection.translationStatusText(for: .generating)
            if translationStatusByOwner[request.owner] != generatingStatus {
                translationStatusByOwner[request.owner] = generatingStatus
            }
        case .persisting:
            translationStatusByOwner[request.owner] = AgentRuntimeProjection.translationStatusText(for: .persisting)
            Task {
                await appModel.agentRuntimeEngine.updatePhase(owner: request.owner, phase: .persisting, activeToken: activeToken)
                let shouldProject = await MainActor.run { shouldProjectTranslation(owner: request.owner) }
                guard shouldProject else { return }
                await syncTranslationPresentationForCurrentEntry(allowAutoEnterBilingualForRunningEntry: false)
            }
        case .completed:
            translationStatusByOwner[request.owner] = nil
            topErrorBannerText = nil
            if translationRunningOwner == request.owner {
                translationRunningOwner = nil
            }
            Task {
                _ = await appModel.agentRuntimeEngine.finish(
                    owner: request.owner,
                    terminalPhase: .completed,
                    reason: nil,
                    activeToken: activeToken
                )
                let shouldProject = await MainActor.run { shouldProjectTranslation(owner: request.owner) }
                guard shouldProject else { return }
                await applyPersistedTranslationForCompletedRun(request)
                await syncTranslationPresentationForCurrentEntry(allowAutoEnterBilingualForRunningEntry: false)
                await refreshTranslationClearAvailabilityForCurrentEntry()
            }
        case .failed(_, let failureReason):
            if translationRunningOwner == request.owner {
                translationRunningOwner = nil
            }
            topErrorBannerText = AgentRuntimeProjection.failureMessage(
                for: failureReason,
                taskKind: .translation
            )
            translationStatusByOwner[request.owner] = AgentRuntimeProjection.translationStatusText(for: .failed)
            Task {
                let terminalPhase: AgentRunPhase = failureReason == .timedOut ? .timedOut : .failed
                _ = await appModel.agentRuntimeEngine.finish(
                    owner: request.owner,
                    terminalPhase: terminalPhase,
                    reason: failureReason,
                    activeToken: activeToken
                )
                let shouldProject = await MainActor.run { shouldProjectTranslation(owner: request.owner) }
                guard shouldProject else { return }
                await syncTranslationPresentationForCurrentEntry(allowAutoEnterBilingualForRunningEntry: false)
            }
        case .cancelled:
            if translationRunningOwner == request.owner {
                translationRunningOwner = nil
            }
            translationStatusByOwner[request.owner] = AgentRuntimeProjection.translationStatusText(for: .cancelled)
            Task {
                _ = await appModel.agentRuntimeEngine.finish(
                    owner: request.owner,
                    terminalPhase: .cancelled,
                    reason: .cancelled,
                    activeToken: activeToken
                )
                let shouldProject = await MainActor.run { shouldProjectTranslation(owner: request.owner) }
                guard shouldProject else { return }
                await syncTranslationPresentationForCurrentEntry(allowAutoEnterBilingualForRunningEntry: false)
            }
        }
    }

    // MARK: - Projection Helpers

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

    private func clearTranslationTerminalStatuses() {
        let blockedStatuses: Set<String> = [
            AgentRuntimeProjection.translationNoContentStatus(),
            AgentRuntimeProjection.translationFetchFailedRetryStatus()
        ]
        translationStatusByOwner = translationStatusByOwner.filter { _, status in
            blockedStatuses.contains(status) == false
        }
    }

    private func makeTranslationRunOwner(slotKey: TranslationSlotKey) -> AgentRunOwner {
        AgentRunOwner(
            taskKind: .translation,
            entryId: slotKey.entryId,
            slotKey: TranslationRuntimePolicy.makeRunOwnerSlotKey(slotKey)
        )
    }

    private func applyTranslationProjection(
        entryId: Int64,
        slotKey: TranslationSlotKey,
        sourceReaderHTML: String,
        translatedBySegmentID: [String: String],
        missingStatusText: String?,
        headerTranslatedText: String?,
        headerStatusText: String?
    ) {
        do {
            let composed = try TranslationBilingualComposer.compose(
                renderedHTML: sourceReaderHTML,
                entryId: entryId,
                translatedBySegmentID: translatedBySegmentID,
                missingStatusText: missingStatusText,
                headerTranslatedText: headerTranslatedText,
                headerStatusText: headerStatusText
            )
            let visibleHTML = ensureVisibleTranslationBlockIfNeeded(
                composedHTML: composed.html,
                translatedBySegmentID: translatedBySegmentID,
                headerTranslatedText: headerTranslatedText,
                missingStatusText: missingStatusText
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

    private static let translationTransientStatuses: Set<String> =
        AgentRuntimeProjection.translationTransientStatuses()

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
            }
            translationStatusByOwner = translationStatusByOwner.filter { owner, status in
                guard AgentRuntimeProjection.isTranslationWaitingStatus(status) else {
                    return true
                }
                return owner.entryId != previousEntryId
            }
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
                translationStatusByOwner[owner] = AgentRuntimeProjection.translationNoContentStatus()
                Task {
                    _ = await appModel.agentRuntimeEngine.finish(owner: owner, terminalPhase: .cancelled, reason: .cancelled, activeToken: activeToken)
                }
                return
            }
            translationCurrentSlotKey = request.slotKey
            translationStatusByOwner[owner] = AgentRuntimeProjection.translationStatusText(for: .requesting)
            startTranslationRun(request, activeToken: activeToken)
        case let .dropped(_, owner, _):
            guard owner.taskKind == .translation else { return }
            if translationQueuedRunPayloads.removeValue(forKey: owner) != nil {
                if let status = translationStatusByOwner[owner],
                   AgentRuntimeProjection.isTranslationWaitingStatus(status) {
                    translationStatusByOwner[owner] = AgentRuntimeProjection.translationNoContentStatus()
                }
            }
        default:
            return
        }
    }

    @MainActor
    private func applyPersistedTranslationForCompletedRun(_ request: TranslationQueuedRunRequest) async {
        guard AgentDisplayOwnershipPolicy.shouldProject(
            owner: request.owner,
            displayedEntryId: displayedEntryId
        ),
              let currentSourceReaderHTML = sourceReaderHTML else {
            return
        }

        do {
            guard let record = try await appModel.loadTranslationRecord(slotKey: request.slotKey) else {
                return
            }
            guard AgentDisplayOwnershipPolicy.shouldProject(
                owner: request.owner,
                displayedEntryId: displayedEntryId
            ) else {
                return
            }
            translationCurrentSlotKey = request.slotKey
            hasPersistedTranslationForCurrentSlot = true
            translationStatusByOwner[request.owner] = nil

            let translatedBySegmentID = Dictionary(uniqueKeysWithValues: record.segments.map {
                ($0.sourceSegmentId, $0.translatedText)
            })
            let headerTranslatedText = translatedBySegmentID[Self.translationHeaderSegmentID]
            let bodyTranslatedBySegmentID = translatedBySegmentID.filter { key, _ in
                key != Self.translationHeaderSegmentID
            }
            applyTranslationProjection(
                entryId: request.snapshot.entryId,
                slotKey: request.slotKey,
                sourceReaderHTML: currentSourceReaderHTML,
                translatedBySegmentID: bodyTranslatedBySegmentID,
                missingStatusText: nil,
                headerTranslatedText: headerTranslatedText,
                headerStatusText: nil
            )
        } catch {
            return
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
