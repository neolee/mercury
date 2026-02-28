import SwiftUI

extension ReaderSummaryView {
    func refreshSummaryForSelectedEntry(_ entryId: Int64?) async {
        guard let entryId else {
            hasAnyPersistedSummaryForCurrentEntry = false
            summaryText = ""
            summaryUpdatedAt = nil
            summaryDurationMs = nil
            summaryPlaceholderText = AgentRuntimeProjection.summaryNoContentStatus()
            applySummaryAgentDefaults()
            return
        }

        pruneSummaryStreamingStates()

        if isSummaryRunning,
           let runningSlot = summaryRunningSlotKey,
           runningSlot.entryId == entryId {
            hasAnyPersistedSummaryForCurrentEntry = false
            let resolved = SummaryPolicy.resolveControlSelection(
                selectedEntryId: entryId,
                runningSlot: SummarySlotKey(
                    entryId: runningSlot.entryId,
                    targetLanguage: runningSlot.targetLanguage,
                    detailLevel: runningSlot.detailLevel
                ),
                latestPersistedSlot: nil,
                defaults: SummaryControlSelection(
                    targetLanguage: appModel.loadSummaryAgentDefaults().targetLanguage,
                    detailLevel: appModel.loadSummaryAgentDefaults().detailLevel
                )
            )
            applySummaryControls(
                targetLanguage: resolved.targetLanguage,
                detailLevel: resolved.detailLevel
            )
            summaryText = summaryStreamingStates[runningSlot]?.text ?? ""
            summaryUpdatedAt = nil
            summaryDurationMs = nil
            summaryPlaceholderText = summaryText.isEmpty
                ? AgentRuntimeProjection.summaryDisplayStrings().generating
                : ""
            return
        }

        isSummaryLoading = true
        if summaryText.isEmpty {
            summaryPlaceholderText = AgentRuntimeProjection.summaryDisplayStrings().loading
        }
        defer { isSummaryLoading = false }

        do {
            if let latest = try await appModel.loadLatestSummaryRecord(entryId: entryId) {
                hasAnyPersistedSummaryForCurrentEntry = true
                summaryFetchRetryEntryId = nil
                let normalizedLatestLanguage = AgentLanguageOption.normalizeCode(latest.result.targetLanguage)
                applySummaryControls(
                    targetLanguage: normalizedLatestLanguage,
                    detailLevel: latest.result.detailLevel
                )
                summaryText = latest.result.text
                summaryUpdatedAt = latest.result.updatedAt
                summaryDurationMs = latest.run.durationMs
                summaryPlaceholderText = latest.result.text.isEmpty ? "No summary" : ""
                return
            }
        } catch {
            appModel.reportDebugIssue(
                title: "Load Summary Failed",
                detail: error.localizedDescription,
                category: .task
            )
        }

        hasAnyPersistedSummaryForCurrentEntry = false
        applySummaryAgentDefaults()
        await loadSummaryRecordForCurrentSlot(entryId: entryId)
    }

    func loadSummaryRecordForCurrentSlot(entryId: Int64?) async {
        guard let entryId else {
            summaryText = ""
            summaryUpdatedAt = nil
            summaryDurationMs = nil
            summaryPlaceholderText = AgentRuntimeProjection.summaryNoContentStatus()
            return
        }

        let targetLanguage = AgentLanguageOption.normalizeCode(summaryTargetLanguage)
        if summaryTargetLanguage != targetLanguage {
            summaryTargetLanguage = targetLanguage
        }
        let currentSlotKey = makeSummarySlotKey(
            entryId: entryId,
            targetLanguage: targetLanguage,
            detailLevel: summaryDetailLevel
        )
        pruneSummaryStreamingStates()
        if isSummaryRunning,
           summaryRunningSlotKey == currentSlotKey {
            summaryText = summaryStreamingStates[currentSlotKey]?.text ?? ""
            summaryUpdatedAt = nil
            summaryDurationMs = nil
            summaryPlaceholderText = summaryText.isEmpty
                ? AgentRuntimeProjection.summaryDisplayStrings().generating
                : ""
            return
        }

        isSummaryLoading = true
        defer { isSummaryLoading = false }

        do {
            let record = try await appModel.loadSummaryRecord(
                entryId: entryId,
                targetLanguage: targetLanguage,
                detailLevel: summaryDetailLevel
            )
            if Task.isCancelled { return }
            if record != nil {
                summaryFetchRetryEntryId = nil
            }
            summaryText = record?.result.text ?? ""
            summaryUpdatedAt = record?.result.updatedAt
            summaryDurationMs = record?.run.durationMs
            if record != nil {
                summaryStreamingStates[currentSlotKey] = nil
            }
            if summaryText.isEmpty {
                summaryPlaceholderText = AgentRuntimeProjection.summaryPlaceholderText(
                    hasContent: false,
                    isLoading: false,
                    hasFetchFailure: false,
                    hasPendingRequest: SummaryPolicy.shouldShowWaitingPlaceholder(
                        summaryTextIsEmpty: true,
                        hasPendingRequestForSelectedEntry: hasPendingSummaryRequest(for: entryId)
                    ),
                    activePhase: nil
                )
            } else {
                summaryPlaceholderText = ""
            }
        } catch {
            appModel.reportDebugIssue(
                title: "Load Summary Failed",
                detail: error.localizedDescription,
                category: .task
            )
            if summaryText.isEmpty {
                summaryPlaceholderText = AgentRuntimeProjection.summaryNoContentStatus()
            }
        }
    }
    // MARK: - Summary control helpers

    func syncSummaryControlsWithAgentDefaultsIfNeeded() async {
        guard hasAnyPersistedSummaryForCurrentEntry == false else {
            return
        }
        applySummaryAgentDefaults()
        await loadSummaryRecordForCurrentSlot(entryId: displayedEntryId)
    }

    func applySummaryControls(targetLanguage: String, detailLevel: SummaryDetailLevel) {
        summaryTargetLanguage = AgentLanguageOption.normalizeCode(targetLanguage)
        summaryDetailLevel = detailLevel
    }

    func applySummaryAgentDefaults() {
        let defaults = appModel.loadSummaryAgentDefaults()
        applySummaryControls(
            targetLanguage: defaults.targetLanguage,
            detailLevel: defaults.detailLevel
        )
    }

    func makeSummarySlotKey(entryId: Int64, targetLanguage: String, detailLevel: SummaryDetailLevel) -> SummarySlotKey {
        SummarySlotKey(
            entryId: entryId,
            targetLanguage: AgentLanguageOption.normalizeCode(targetLanguage),
            detailLevel: detailLevel
        )
    }

    func makeSummaryRunOwner(entryId: Int64, targetLanguage: String, detailLevel: SummaryDetailLevel) -> AgentRunOwner {
        AgentRunOwner(
            taskKind: .summary,
            entryId: entryId,
            slotKey: "\(AgentLanguageOption.normalizeCode(targetLanguage))|\(detailLevel.rawValue)"
        )
    }

    func abandonSummaryWaiting(for previousEntryId: Int64, nextSelectedEntryId: Int64?) async {
        guard previousEntryId != nextSelectedEntryId else { return }
        // Use the engine's authoritative record rather than the payload map to avoid a race:
        // submit() is async, so summaryQueuedRunPayloads may not yet be populated by the time
        // an entry switch fires.
        await appModel.agentRuntimeEngine.abandonWaiting(taskKind: .summary, entryId: previousEntryId)
        await MainActor.run {
            let ownersToDrop = summaryQueuedRunPayloads.keys.filter {
                $0.taskKind == .summary && $0.entryId == previousEntryId
            }
            for owner in ownersToDrop {
                summaryQueuedRunPayloads.removeValue(forKey: owner)
            }
        }
    }

    func isShowingSummarySlot(_ slotKey: SummarySlotKey) -> Bool {
        guard displayedEntryId == slotKey.entryId else {
            return false
        }
        let currentLanguage = AgentLanguageOption.normalizeCode(summaryTargetLanguage)
        return currentLanguage == slotKey.targetLanguage && summaryDetailLevel == slotKey.detailLevel
    }

    func currentDisplayedSummarySlotKey() -> SummarySlotKey? {
        guard let entryId = displayedEntryId else {
            return nil
        }
        return makeSummarySlotKey(
            entryId: entryId,
            targetLanguage: summaryTargetLanguage,
            detailLevel: summaryDetailLevel
        )
    }

    func pruneSummaryStreamingStates(now: Date = Date()) {
        let pinned = Set([summaryRunningSlotKey, currentDisplayedSummarySlotKey()].compactMap { $0 })
        summaryStreamingStates = SummaryStreamingCachePolicy.evict(
            states: summaryStreamingStates,
            now: now,
            ttl: Self.summaryStreamingStateTTL,
            capacity: Self.summaryStreamingStateCapacity,
            pinnedKeys: pinned
        )
    }

    func syncSummaryPlaceholderForCurrentState() {
        let activePhase: AgentRunPhase?
        if isSummaryRunning, summaryRunningEntryId == displayedEntryId {
            activePhase = summaryActivePhase
        } else {
            activePhase = nil
        }
        summaryPlaceholderText = AgentRuntimeProjection.summaryPlaceholderText(
            hasContent: summaryText.isEmpty == false,
            isLoading: isSummaryLoading,
            hasFetchFailure: summaryFetchRetryEntryId == displayedEntryId,
            hasPendingRequest: SummaryPolicy.shouldShowWaitingPlaceholder(
                summaryTextIsEmpty: true,
                hasPendingRequestForSelectedEntry: hasPendingSummaryRequest(for: displayedEntryId)
            ),
            activePhase: activePhase
        )
    }

    func hasPendingSummaryRequest(for entryId: Int64?) -> Bool {
        guard let entryId else { return false }
        return summaryQueuedRunPayloads.keys.contains { $0.entryId == entryId }
    }
}
