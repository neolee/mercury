import SwiftUI

extension ReaderSummaryView {
    func observeRuntimeEventsForSummary() async {
        let stream = await appModel.agentRuntimeEngine.events()
        for await event in stream {
            await MainActor.run {
                handleSummaryRuntimeEvent(event)
    }
}
    }

    @MainActor
    func handleSummaryRuntimeEvent(_ event: AgentRuntimeEvent) {
        switch event {
        case let .activated(_, owner, activeToken):
            guard owner.taskKind == .summary else { return }
            // Guard against duplicate activation for an already-running owner. The .startNow path
            // fires .activated synchronously from submit(); the direct startSummaryRun call takes
            // precedence and sets summaryRunningOwner before this event is processed.
            guard summaryRunningOwner != owner else { return }
            guard let payload = summaryQueuedRunPayloads.removeValue(forKey: owner) else {
                // Engine promoted this owner to active but we have no queued payload
                // (e.g. the user aborted before activation). Release the slot immediately
                // to prevent a permanent engine capacity leak.
                Task {
                    _ = await appModel.agentRuntimeEngine.finish(
                        owner: owner, terminalPhase: .cancelled, reason: .cancelled, activeToken: activeToken
                    )
                }
                return
            }
            Task {
                await activatePromotedSummaryRun(owner: owner, payload: payload, activeToken: activeToken)
            }
        case let .dropped(_, owner, _):
            guard owner.taskKind == .summary else { return }
            if summaryQueuedRunPayloads.removeValue(forKey: owner) != nil {
                if displayedEntryId == owner.entryId,
                   summaryText.isEmpty,
                   hasPendingSummaryRequest(for: owner.entryId) == false {
                    summaryPlaceholderText = AgentRuntimeProjection.summaryNoContentStatus()
                }
            }
        default:
            return
        }
    }

    // Applies ownership and pre-start policy checks, then starts the run.
    // Called from handleSummaryRuntimeEvent(.activated) for waiting->active promotions; the
    // .startNow path in requestSummaryRun bypasses this and calls startSummaryRun directly.
    @MainActor
    func activatePromotedSummaryRun(
        owner: AgentRunOwner,
        payload: SummaryQueuedRunRequest,
        activeToken: String
    ) async {
        // Guard against the race where the .startNow path already called startSummaryRun for this
        // owner before this promotion task got a chance to run.
        guard summaryRunningOwner != owner else { return }
        if payload.requestSource == .auto {
            // Auto-trigger ownership gate: cancel if the entry is no longer displayed.
            guard displayedEntryId == owner.entryId else {
                _ = await appModel.agentRuntimeEngine.finish(
                    owner: owner, terminalPhase: .cancelled, reason: .cancelled, activeToken: activeToken
                )
                return
            }
            // Pre-start persisted-summary check: cancel if a summary already exists.
            let hasPersisted = ((try? await appModel.loadLatestSummaryRecord(entryId: owner.entryId)) ?? nil) != nil
            if hasPersisted {
                _ = await appModel.agentRuntimeEngine.finish(
                    owner: owner, terminalPhase: .cancelled, reason: .cancelled, activeToken: activeToken
                )
                return
            }
            // Re-check ownership after the async DB load.
            guard displayedEntryId == owner.entryId else {
                _ = await appModel.agentRuntimeEngine.finish(
                    owner: owner, terminalPhase: .cancelled, reason: .cancelled, activeToken: activeToken
                )
                return
            }
        }

        // Prefer the in-memory entry prop if it matches; otherwise fall back to the queued payload.
        let entry = (self.entry?.id == owner.entryId ? self.entry : nil) ?? payload.entry
        startSummaryRun(
            for: entry,
            taskId: payload.taskId,
            owner: owner,
            targetLanguage: payload.targetLanguage,
            detailLevel: payload.detailLevel,
            activeToken: activeToken
        )
    }
    // MARK: - Summary run lifecycle

    func requestSummaryRun(for entry: Entry, requestSource: AgentTaskRequestSource) {
        guard let entryId = entry.id else { return }

        // For user-initiated runs, check availability before touching the runtime engine.
        // Auto-triggered paths skip this guard — they are already gated by the auto-run policy.
        if requestSource == .manual, !appModel.isSummaryAgentAvailable {
            let message = !appModel.isTranslationAgentAvailable
                ? String(localized: "Agents are not configured. Add a provider and model in Settings.", bundle: bundle)
                : String(localized: "Summary agent is not configured. Add a provider and model in Settings to enable summaries.", bundle: bundle)
            topBannerMessage = ReaderBannerMessage(
                text: message,
                action: ReaderBannerMessage.BannerAction(label: String(localized: "Open Settings", bundle: bundle)) { openSettings() }
            )
            return
        }

        let targetLanguage = AgentLanguageOption.normalizeCode(summaryTargetLanguage)
        if summaryTargetLanguage != targetLanguage {
            summaryTargetLanguage = targetLanguage
        }
        let detailLevel = summaryDetailLevel
        let owner = makeSummaryRunOwner(
            entryId: entryId,
            targetLanguage: targetLanguage,
            detailLevel: detailLevel
        )
        let payload = SummaryQueuedRunRequest(
            taskId: appModel.makeTaskID(),
            entry: entry,
            owner: owner,
            targetLanguage: targetLanguage,
            detailLevel: detailLevel,
            requestSource: requestSource
        )

        // Register the payload synchronously BEFORE submit() so handleSummaryRuntimeEvent(.activated)
        // always finds it. Without this, .activated can fire during the actor-hop gap between
        // submit() returning .startNow and the MainActor.run block calling startSummaryRun, find
        // no payload, and immediately cancel the engine slot via finish(.cancelled). That frees the
        // concurrency slot, causing a subsequent submit() for a different entry to return .startNow
        // and overwrite all running-entry state.
        summaryQueuedRunPayloads[owner] = payload

        Task {
            let submission = await appModel.submitAgentTask(
                taskId: payload.taskId,
                kind: .summary,
                owner: owner,
                requestSource: requestSource,
                visibilityPolicy: .selectedEntryOnly
            )
            await MainActor.run {
                switch submission.decision {
                case .startNow:
                    // Guard against the race where .activated fired during the actor-hop gap above
                    // and activatePromotedSummaryRun has already claimed the payload and called
                    // startSummaryRun for this owner.
                    if summaryRunningOwner != owner {
                        summaryQueuedRunPayloads.removeValue(forKey: owner)
                        startSummaryRun(
                            for: entry,
                            taskId: payload.taskId,
                            owner: owner,
                            targetLanguage: targetLanguage,
                            detailLevel: detailLevel,
                            activeToken: submission.activeToken ?? ""
                        )
                    }
                case .queuedWaiting, .alreadyWaiting:
                    // Payload already registered above; only update the placeholder text.
                    if displayedEntryId == entryId && summaryText.isEmpty {
                        summaryPlaceholderText = AgentRuntimeProjection.summaryPlaceholderText(
                            hasContent: false,
                            isLoading: false,
                            hasFetchFailure: false,
                            hasPendingRequest: true,
                            activePhase: nil
                        )
                    }
                case .alreadyActive:
                    // Duplicate submission; remove the speculatively registered payload.
                    summaryQueuedRunPayloads.removeValue(forKey: owner)
                }
            }
        }
    }

    func startSummaryRun(
        for entry: Entry,
        taskId: UUID,
        owner: AgentRunOwner,
        targetLanguage: String,
        detailLevel: SummaryDetailLevel,
        activeToken: String
    ) {
        guard let entryId = entry.id else { return }
        let slotKey = makeSummarySlotKey(
            entryId: entryId,
            targetLanguage: targetLanguage,
            detailLevel: detailLevel
        )

        isSummaryRunning = true
        summaryActivePhase = .requesting
        summaryFetchRetryEntryId = nil
        summaryRunningEntryId = entryId
        summaryRunningSlotKey = slotKey
        summaryRunningOwner = owner
        summaryStreamingStates[slotKey] = SummaryStreamingCacheState(text: "", updatedAt: Date())
        pruneSummaryStreamingStates()
        summaryText = ""
        summaryUpdatedAt = nil
        summaryDurationMs = nil
        summaryShouldFollowTail = true
        if displayedEntryId == entryId {
            summaryPlaceholderText = AgentRuntimeProjection.summaryPlaceholderText(
                hasContent: false,
                isLoading: false,
                hasFetchFailure: false,
                hasPendingRequest: false,
                activePhase: .requesting
            )
        }

        let capturedToken = activeToken
        summaryRunStartTask = Task {
            let source = await resolveSummarySourceText(for: entry)
            if Task.isCancelled { return }

            let request = SummaryRunRequest(
                entryId: entryId,
                sourceText: source,
                targetLanguage: targetLanguage,
                detailLevel: detailLevel
            )
            let enqueuedTaskId = await appModel.startSummaryRun(request: request, requestedTaskId: taskId) { event in
                await MainActor.run {
                    handleSummaryRunEvent(event, entryId: entryId, activeToken: capturedToken)
                }
            }
            await MainActor.run {
                summaryTaskId = enqueuedTaskId
            }
        }
    }

    func resolveSummarySourceText(for entry: Entry) async -> String {
        let fallback = fallbackSummarySourceText(for: entry)
        guard let entryId = entry.id else {
            return fallback
        }

        if let markdown = try? await appModel.summarySourceMarkdown(entryId: entryId) {
            return markdown
        }

        _ = await loadReaderHTML(entry, effectiveReaderTheme)
        if let markdown = try? await appModel.summarySourceMarkdown(entryId: entryId) {
            return markdown
        }

        return fallback
    }

    func fallbackSummarySourceText(for entry: Entry) -> String {
        let summary = (entry.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if summary.isEmpty == false {
            return summary
        }

        let title = (entry.title ?? "Untitled").trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Untitled" : title
    }

    func abortSummary() {
        autoSummaryDebounceTask?.cancel()
        autoSummaryDebounceTask = nil
        let pendingOwners = Array(summaryQueuedRunPayloads.keys)
        summaryQueuedRunPayloads.removeAll()
        summaryRunStartTask?.cancel()
        summaryRunStartTask = nil
        if let summaryTaskId {
            Task {
                await appModel.cancelTask(summaryTaskId)
            }
            self.summaryTaskId = nil
        }
        let runningOwner = summaryRunningOwner
        isSummaryRunning = false
        summaryActivePhase = nil
        summaryRunningEntryId = nil
        summaryRunningSlotKey = nil
        summaryRunningOwner = nil
        Task {
            if let runningOwner {
                _ = await appModel.agentRuntimeEngine.finish(owner: runningOwner, terminalPhase: .cancelled)
            }
            for owner in pendingOwners {
                _ = await appModel.agentRuntimeEngine.finish(owner: owner, terminalPhase: .cancelled)
            }
        }
        if displayedEntryId != nil, summaryText.isEmpty {
            summaryPlaceholderText = AgentRuntimeProjection.summaryCancelledStatus()
        }
    }

    func clearSummary(for entry: Entry) {
        abortSummary()
        summaryText = ""
        summaryUpdatedAt = nil
        summaryDurationMs = nil

        guard let entryId = entry.id else { return }
        let targetLanguage = AgentLanguageOption.normalizeCode(summaryTargetLanguage)
        if summaryTargetLanguage != targetLanguage {
            summaryTargetLanguage = targetLanguage
        }
        let currentSlotKey = makeSummarySlotKey(
            entryId: entryId,
            targetLanguage: targetLanguage,
            detailLevel: summaryDetailLevel
        )
        summaryStreamingStates[currentSlotKey] = nil
        pruneSummaryStreamingStates()

        Task {
            do {
                _ = try await appModel.clearSummaryRecord(
                    entryId: entryId,
                    targetLanguage: targetLanguage,
                    detailLevel: summaryDetailLevel
                )
                await refreshSummaryForSelectedEntry(entryId)
                scheduleAutoSummaryForSelectedEntry()
            } catch {
                appModel.reportDebugIssue(
                    title: "Clear Summary Failed",
                    detail: error.localizedDescription,
                    category: .task
                )
            }
        }
    }

    @MainActor
    func handleSummaryRunEvent(_ event: SummaryRunEvent, entryId: Int64, activeToken: String) {
        // Discard all events from a stale run. When entry A's run is aborted (abortSummary sets
        // summaryRunningEntryId = nil) or replaced by entry B's run, A's onEvent closures may
        // still be in the MainActor queue. Without this guard, A's .token writes would land on
        // B's summaryRunningSlotKey because that state is read live, not captured at run start.
        guard entryId == summaryRunningEntryId else { return }

        let runningSlotKey = summaryRunningSlotKey
        let runningOwner = summaryRunningOwner

        switch event {
        case .started(let taskId):
            summaryTaskId = taskId
            summaryActivePhase = .generating
            if let runningOwner {
                Task {
                    await appModel.agentRuntimeEngine.updatePhase(owner: runningOwner, phase: .requesting, activeToken: activeToken)
                }
            }
            if let runningSlotKey,
               isShowingSummarySlot(runningSlotKey),
               summaryText.isEmpty {
                summaryPlaceholderText = AgentRuntimeProjection.summaryPlaceholderText(
                    hasContent: false,
                    isLoading: false,
                    hasFetchFailure: false,
                    hasPendingRequest: false,
                    activePhase: .generating
                )
            }
        case .token(let token):
            summaryActivePhase = .generating
            if let runningOwner {
                Task {
                    await appModel.agentRuntimeEngine.updatePhase(owner: runningOwner, phase: .generating, activeToken: activeToken)
                }
            }
            if let runningSlotKey {
                let now = Date()
                var state = summaryStreamingStates[runningSlotKey]
                    ?? SummaryStreamingCacheState(text: "", updatedAt: now)
                state.text += token
                state.updatedAt = now
                summaryStreamingStates[runningSlotKey] = state
                pruneSummaryStreamingStates(now: now)
                if isShowingSummarySlot(runningSlotKey) {
                    summaryText = state.text
                }
                if summaryText.isEmpty == false {
                    summaryPlaceholderText = ""
                }
            }
        case .terminal(let outcome):
            isSummaryRunning = false
            summaryActivePhase = nil
            summaryTaskId = nil
            summaryRunStartTask = nil
            summaryRunningEntryId = nil
            summaryRunningSlotKey = nil
            summaryRunningOwner = nil
            pruneSummaryStreamingStates()
            Task {
                if let runningOwner {
                    _ = await appModel.agentRuntimeEngine.finish(
                        owner: runningOwner,
                        terminalPhase: outcome.agentRunPhase,
                        reason: outcome.normalizedFailureReason,
                        activeToken: activeToken
                    )
                }
            }

            switch outcome {
            case .succeeded:
                if SummaryPolicy.shouldMarkCurrentEntryPersistedOnCompletion(
                    completedEntryId: entryId,
                    displayedEntryId: displayedEntryId
                ) {
                    hasAnyPersistedSummaryForCurrentEntry = true
                    Task {
                        await loadSummaryRecordForCurrentSlot(entryId: entryId)
                    }
                }
                syncSummaryPlaceholderForCurrentState()
            case .failed, .timedOut:
                let shouldShowFailureMessage = displayedEntryId == entryId
                if shouldShowFailureMessage, isSummaryRunning == false {
                    let bannerText = AgentRuntimeProjection.bannerMessage(
                        for: outcome,
                        taskKind: .summary
                    ) ?? AgentRuntimeProjection.failureMessage(for: .unknown, taskKind: .summary)
                    topBannerMessage = ReaderBannerMessage(
                        text: bannerText,
                        secondaryAction: .openDebugIssues
                    )
                    if summaryText.isEmpty {
                        summaryPlaceholderText = AgentRuntimeProjection.summaryNoContentStatus()
                    }
                } else {
                    syncSummaryPlaceholderForCurrentState()
                }
            case .cancelled:
                let shouldShowCancelledMessage = displayedEntryId == entryId && summaryText.isEmpty
                if shouldShowCancelledMessage, isSummaryRunning == false {
                    summaryPlaceholderText = AgentRuntimeProjection.summaryCancelledStatus()
                } else {
                    syncSummaryPlaceholderForCurrentState()
                }
            }
        }
    }

}
