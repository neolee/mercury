import SwiftUI

extension ReaderSummaryView {
    // MARK: - Auto-summary scheduling

    func handleAutoSummaryToggleChange(_ enabled: Bool) {
        if enabled == false {
            summaryAutoEnabled = false
            summaryFetchRetryEntryId = nil
            autoSummaryDebounceTask?.cancel()
            autoSummaryDebounceTask = nil
            return
        }

        if appModel.summaryAutoEnableWarningEnabled() {
            summaryAutoEnabled = false
            showAutoSummaryEnableRiskAlert = true
            return
        }

        summaryAutoEnabled = true
        scheduleAutoSummaryForSelectedEntry()
    }

    func scheduleAutoSummaryForSelectedEntry() {
        autoSummaryDebounceTask?.cancel()
        autoSummaryDebounceTask = nil

        guard summaryAutoEnabled else {
            return
        }

        guard let entry, entry.id != nil else {
            return
        }

        autoSummaryDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard Task.isCancelled == false else { return }
            await runSummaryAutoActivation(for: entry)
        }
    }

    func checkAutoSummaryStartReadiness(entryId: Int64) async -> AgentPersistedStateCheckResult {
        do {
            let latest = try await appModel.loadLatestSummaryRecord(entryId: entryId)
            return latest == nil ? .renderableMissing : .renderableAvailable
        } catch {
            appModel.reportDebugIssue(
                title: "Load Summary Failed",
                detail: error.localizedDescription,
                category: .task
            )
            return .fetchFailed
        }
    }

    func runSummaryAutoActivation(for entry: Entry) async {
        guard let entryId = entry.id else { return }
        let context = await MainActor.run {
            AgentEntryActivationContext(
                autoEnabled: summaryAutoEnabled,
                displayedEntryId: displayedEntryId,
                candidateEntryId: entryId
            )
        }

        await AgentEntryActivation.run(
            context: context,
            checkPersistedState: {
                await checkAutoSummaryStartReadiness(entryId: entryId)
            },
            onProjectPersisted: {
                await MainActor.run {
                    topBannerMessage = nil
                    hasAnyPersistedSummaryForCurrentEntry = true
                    summaryFetchRetryEntryId = nil
                    syncSummaryPlaceholderForCurrentState()
                }
            },
            onRequestRun: {
                await MainActor.run {
                    topBannerMessage = nil
                    summaryFetchRetryEntryId = nil
                    hasAnyPersistedSummaryForCurrentEntry = false
                    requestSummaryRun(for: entry, requestSource: .auto)
                }
            },
            onSkip: {
                await MainActor.run {
                    syncSummaryPlaceholderForCurrentState()
                }
            },
            onShowFetchFailedRetry: {
                await MainActor.run {
                    topBannerMessage = ReaderBannerMessage(text: "Fetch data failed.")
                    summaryFetchRetryEntryId = entryId
                    syncSummaryPlaceholderForCurrentState()
                }
            }
        )
    }

    // MARK: - Summary scroll helpers

    func updateSummaryScrollFollowState() {
        guard summaryScrollViewportHeight > 0 else {
            return
        }

        guard Date() >= summaryIgnoreScrollStateUntil else {
            return
        }

        let nearBottomThreshold: Double = 24
        let isAtBottom = summaryScrollBottomMaxY <= (summaryScrollViewportHeight + nearBottomThreshold)
        summaryShouldFollowTail = isAtBottom
    }

    func scrollSummaryToBottom(using proxy: ScrollViewProxy, force: Bool = false) {
        guard force || summaryShouldFollowTail else {
            return
        }

        summaryIgnoreScrollStateUntil = Date().addingTimeInterval(0.25)
        withAnimation(.easeOut(duration: 0.16)) {
            proxy.scrollTo(Self.summaryScrollBottomAnchorID, anchor: .bottom)
        }
    }

    // MARK: - Availability banner

    func checkAndSetAvailabilityBanner() {
        guard !appModel.isSummaryAgentAvailable,
              !isSummaryRunning,
              summaryText.isEmpty,
              !summaryAvailabilityBannerSuppressed else { return }
        summaryAvailabilityBannerSuppressed = true
        let message = !appModel.isTranslationAgentAvailable
            ? String(localized: "Agents are not configured. Add a provider and model in Settings.", bundle: bundle)
            : String(localized: "Summary agent is not configured. Add a provider and model in Settings to enable summaries.", bundle: bundle)
        topBannerMessage = ReaderBannerMessage(
            text: message,
            action: ReaderBannerMessage.BannerAction(label: String(localized: "Open Settings", bundle: bundle)) { openSettings() }
        )
    }
}
