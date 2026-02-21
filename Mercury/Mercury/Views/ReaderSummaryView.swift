//
//  ReaderSummaryView.swift
//  Mercury
//
//  Created by Neo on 2026/2/22.
//

import SwiftUI
import AppKit

// MARK: - Private types

private struct SummaryQueuedRunRequest: Sendable {
    let entry: Entry
    let owner: AgentRunOwner
    let targetLanguage: String
    let detailLevel: SummaryDetailLevel
    let requestSource: AgentTaskRequestSource
}

// MARK: - ReaderSummaryView

struct ReaderSummaryView: View {

    // MARK: - Props from container

    let entry: Entry?
    @Binding var displayedEntryId: Int64?
    @Binding var topErrorBannerText: String?
    let loadReaderHTML: (Entry, EffectiveReaderTheme) async -> ReaderBuildResult
    let effectiveReaderTheme: EffectiveReaderTheme

    @EnvironmentObject var appModel: AppModel

    // MARK: - Panel geometry state

    @State private var isSummaryPanelExpanded = Self.loadSummaryPanelExpandedState()
    @State private var summaryPanelExpandedHeight = Self.loadSummaryPanelExpandedHeight()

    // MARK: - Summary control state

    @State private var summaryTargetLanguage = "en"
    @State private var summaryDetailLevel: SummaryDetailLevel = .medium
    @State private var summaryAutoEnabled = false

    // MARK: - Summary content state

    @State private var summaryText = ""
    @State private var summaryRenderedText = AttributedString("")
    @State private var summaryUpdatedAt: Date?
    @State private var summaryDurationMs: Int?

    // MARK: - Summary loading/running state

    @State private var isSummaryLoading = false
    @State private var isSummaryRunning = false
    @State private var summaryActivePhase: AgentRunPhase?
    @State private var hasAnyPersistedSummaryForCurrentEntry = false

    // MARK: - Summary scroll state

    @State private var summaryShouldFollowTail = true
    @State private var summaryScrollViewportHeight: Double = 0
    @State private var summaryScrollBottomMaxY: Double = 0
    @State private var summaryIgnoreScrollStateUntil = Date.distantPast

    // MARK: - Summary runtime state

    @State private var summaryRunStartTask: Task<Void, Never>?
    @State private var summaryTaskId: UUID?
    @State private var summaryRunningEntryId: Int64?
    @State private var summaryRunningSlotKey: SummarySlotKey?
    @State private var summaryRunningOwner: AgentRunOwner?
    @State private var summaryQueuedRunPayloads: [AgentRunOwner: SummaryQueuedRunRequest] = [:]
    @State private var summaryStreamingStates: [SummarySlotKey: SummaryStreamingCacheState] = [:]

    // MARK: - Auto-summary / UI state

    @State private var autoSummaryDebounceTask: Task<Void, Never>?
    @State private var showAutoSummaryEnableRiskAlert = false
    @State private var summaryPlaceholderText = AgentRuntimeProjection.summaryNoContentStatus()
    @State private var summaryFetchRetryEntryId: Int64?

    // MARK: - Body

    var body: some View {
        let collapsedHeight: Double = 44
        let minExpandedHeight: Double = 220
        let maxExpandedHeight: Double = 520
        let clampedExpandedHeight = min(max(summaryPanelExpandedHeight, minExpandedHeight), maxExpandedHeight)
        let panelHeight = isSummaryPanelExpanded ? clampedExpandedHeight : collapsedHeight

        VStack(spacing: 0) {
            if isSummaryPanelExpanded {
                VSplitDivider(
                    dimension: $summaryPanelExpandedHeight,
                    minDimension: minExpandedHeight,
                    maxDimension: maxExpandedHeight,
                    cursor: .resizeUpDown
                ) { finalHeight in
                    Self.persistSummaryPanelExpandedHeight(finalHeight)
                }
            } else {
                Rectangle()
                    .fill(Color.primary.opacity(0.12))
                    .frame(height: 1)
            }

            if let entry {
                summaryPanel(entry: entry)
                    .frame(height: panelHeight)
            }
        }
        .alert("Enable Auto-summary?", isPresented: $showAutoSummaryEnableRiskAlert) {
            Button("Enable") {
                summaryAutoEnabled = true
                scheduleAutoSummaryForSelectedEntry()
            }
            Button("Enable & Don't Ask Again") {
                appModel.setSummaryAutoEnableWarningEnabled(false)
                summaryAutoEnabled = true
                scheduleAutoSummaryForSelectedEntry()
            }
            Button("Cancel", role: .cancel) {
                summaryAutoEnabled = false
            }
        } message: {
            Text("Auto-summary may trigger model requests and generate additional usage cost.")
        }
        .onChange(of: isSummaryPanelExpanded) { _, expanded in
            UserDefaults.standard.set(expanded, forKey: Self.summaryPanelExpandedKey)
        }
        .onChange(of: summaryTargetLanguage) { _, _ in
            Task {
                await loadSummaryRecordForCurrentSlot(entryId: displayedEntryId)
            }
        }
        .onChange(of: summaryDetailLevel) { _, _ in
            Task {
                await loadSummaryRecordForCurrentSlot(entryId: displayedEntryId)
            }
        }
        .onChange(of: displayedEntryId) { previousEntryId, newEntryId in
            if summaryFetchRetryEntryId != newEntryId {
                summaryFetchRetryEntryId = nil
            }
            pruneSummaryStreamingStates()
            if isSummaryRunning,
               let runningEntryId = summaryRunningEntryId,
               runningEntryId != newEntryId {
                summaryText = ""
                summaryUpdatedAt = nil
                summaryDurationMs = nil
                summaryPlaceholderText = AgentRuntimeProjection.summaryNoContentStatus()
            }
            if let previousEntryId {
                Task {
                    await abandonSummaryWaiting(for: previousEntryId, nextSelectedEntryId: newEntryId)
                }
            }
        }
        .onChange(of: summaryText) { _, newText in
            summaryRenderedText = Self.renderMarkdownSummaryText(newText)
        }
        .task(id: displayedEntryId) {
            await refreshSummaryForSelectedEntry(displayedEntryId)
            scheduleAutoSummaryForSelectedEntry()
        }
        .task {
            await observeRuntimeEventsForSummary()
        }
        .onReceive(NotificationCenter.default.publisher(for: .summaryAgentDefaultsDidChange)) { _ in
            Task {
                await syncSummaryControlsWithAgentDefaultsIfNeeded()
            }
        }
    }

    // MARK: - Summary runtime event observer

    private func observeRuntimeEventsForSummary() async {
        let stream = await appModel.agentRuntimeEngine.events()
        for await event in stream {
            await MainActor.run {
                handleSummaryRuntimeEvent(event)
            }
        }
    }

    @MainActor
    private func handleSummaryRuntimeEvent(_ event: AgentRuntimeEvent) {
        switch event {
        case let .activated(_, owner, _):
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
                        owner: owner, terminalPhase: .cancelled, reason: .cancelled
                    )
                }
                return
            }
            Task {
                await activatePromotedSummaryRun(owner: owner, payload: payload)
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
    private func activatePromotedSummaryRun(
        owner: AgentRunOwner,
        payload: SummaryQueuedRunRequest
    ) async {
        if payload.requestSource == .auto {
            // Auto-trigger ownership gate: cancel if the entry is no longer displayed.
            guard displayedEntryId == owner.entryId else {
                _ = await appModel.agentRuntimeEngine.finish(
                    owner: owner, terminalPhase: .cancelled, reason: .cancelled
                )
                return
            }
            // Pre-start persisted-summary check: cancel if a summary already exists.
            let hasPersisted = ((try? await appModel.loadLatestSummaryRecord(entryId: owner.entryId)) ?? nil) != nil
            if hasPersisted {
                _ = await appModel.agentRuntimeEngine.finish(
                    owner: owner, terminalPhase: .cancelled, reason: .cancelled
                )
                return
            }
            // Re-check ownership after the async DB load.
            guard displayedEntryId == owner.entryId else {
                _ = await appModel.agentRuntimeEngine.finish(
                    owner: owner, terminalPhase: .cancelled, reason: .cancelled
                )
                return
            }
        }

        // Prefer the in-memory entry prop if it matches; otherwise fall back to the queued payload.
        let entry = (self.entry?.id == owner.entryId ? self.entry : nil) ?? payload.entry
        startSummaryRun(
            for: entry,
            owner: owner,
            targetLanguage: payload.targetLanguage,
            detailLevel: payload.detailLevel
        )
    }

    // MARK: - Summary panel view

    @ViewBuilder
    private func summaryPanel(entry: Entry) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        isSummaryPanelExpanded.toggle()
                    } label: {
                        Label(
                            "Summary",
                            systemImage: isSummaryPanelExpanded ? "chevron.down" : "chevron.up"
                        )
                    }
                    .buttonStyle(.plain)

                    if summaryUpdatedAt != nil {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 8, height: 8)
                    }

                    Spacer(minLength: 0)

                    if isSummaryLoading || isSummaryRunning {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                if isSummaryPanelExpanded {
                    HStack(spacing: 8) {
                        HStack(spacing: 6) {
                            Picker("", selection: $summaryTargetLanguage) {
                                ForEach(AgentLanguageOption.supported) { option in
                                    Text(option.nativeName).tag(option.code)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .fixedSize()

                            Picker("", selection: $summaryDetailLevel) {
                                ForEach(SummaryDetailLevel.allCases, id: \.self) { level in
                                    Text(level.rawValue.capitalized).tag(level)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(width: 240)
                        }

                        Spacer(minLength: 12)

                        HStack(spacing: 16) {
                            Toggle(
                                "Auto-summary",
                                isOn: Binding(
                                    get: { summaryAutoEnabled },
                                    set: { newValue in
                                        handleAutoSummaryToggleChange(newValue)
                                    }
                                )
                            )
                                .toggleStyle(.checkbox)

                            HStack(spacing: 8) {
                                Button("Summary") {
                                    requestSummaryRun(for: entry, requestSource: .manual)
                                }
                                .disabled(entry.id == nil)

                                Button("Abort") {
                                    abortSummary()
                                }
                                .disabled(isSummaryRunning == false)

                                Button("Copy") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(summaryText, forType: .string)
                                }
                                .disabled(summaryText.isEmpty)

                                Button("Clear") {
                                    clearSummary(for: entry)
                                }
                                .disabled(summaryText.isEmpty && summaryUpdatedAt == nil)
                            }
                        }
                    }
                    .controlSize(.small)

                    summaryMetaRow

                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                if summaryText.isEmpty {
                                    Text(summaryPlaceholderText)
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .topLeading)
                                } else {
                                    Text(summaryRenderedText)
                                        .foregroundStyle(.primary)
                                        .frame(maxWidth: .infinity, alignment: .topLeading)
                                }

                                Color.clear
                                    .frame(height: 1)
                                    .id(Self.summaryScrollBottomAnchorID)
                                    .background(
                                        GeometryReader { geometry in
                                            Color.clear.preference(
                                                key: SummaryScrollBottomMaxYPreferenceKey.self,
                                                value: Double(geometry.frame(in: .named(Self.summaryScrollCoordinateSpaceName)).maxY)
                                            )
                                        }
                                    )
                            }
                            .font(.system(size: 15))
                            .lineSpacing(4)
                            .textSelection(.enabled)
                            .padding(10)
                        }
                        .coordinateSpace(name: Self.summaryScrollCoordinateSpaceName)
                        .background(
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: SummaryScrollViewportHeightPreferenceKey.self,
                                    value: Double(geometry.size.height)
                                )
                            }
                        )
                        .onPreferenceChange(SummaryScrollViewportHeightPreferenceKey.self) { height in
                            summaryScrollViewportHeight = height
                            updateSummaryScrollFollowState()
                        }
                        .onPreferenceChange(SummaryScrollBottomMaxYPreferenceKey.self) { maxY in
                            summaryScrollBottomMaxY = maxY
                            updateSummaryScrollFollowState()
                        }
                        .onChange(of: summaryText) { _, _ in
                            scrollSummaryToBottom(using: proxy)
                        }
                        .onChange(of: isSummaryPanelExpanded) { _, expanded in
                            guard expanded else { return }
                            scrollSummaryToBottom(using: proxy, force: true)
                        }
                    }
                    .frame(minHeight: 120, maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var summaryMetaRow: some View {
        let updatedAtText: String = {
            guard let summaryUpdatedAt else { return "updatedAt=-" }
            return "updatedAt=\(Self.summaryDateFormatter.string(from: summaryUpdatedAt))"
        }()
        let durationText = summaryDurationMs.map { "duration=\($0)ms" } ?? "duration=-"

        return HStack(spacing: 12) {
            Text("target=\(summaryTargetLanguage)")
            Text("detail=\(summaryDetailLevel.rawValue)")
            Text(durationText)
            Text(updatedAtText)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: - Summary data loading

    private func refreshSummaryForSelectedEntry(_ entryId: Int64?) async {
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

    private func loadSummaryRecordForCurrentSlot(entryId: Int64?) async {
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

    // MARK: - Summary run lifecycle

    private func requestSummaryRun(for entry: Entry, requestSource: AgentTaskRequestSource) {
        guard let entryId = entry.id else { return }
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
            entry: entry,
            owner: owner,
            targetLanguage: targetLanguage,
            detailLevel: detailLevel,
            requestSource: requestSource
        )

        Task {
            let decision = await appModel.agentRuntimeEngine.submit(
                spec: AgentTaskSpec(
                    owner: owner,
                    requestSource: requestSource,
                    queuePolicy: AgentQueuePolicy(
                        concurrentLimitPerKind: AgentRuntimeContract.baselineConcurrentLimitPerKind,
                        waitingCapacityPerKind: AgentRuntimeContract.baselineWaitingCapacityPerKind,
                        replacementWhenFull: .latestOnlyReplaceWaiting
                    ),
                    visibilityPolicy: .selectedEntryOnly
                )
            )
            await MainActor.run {
                switch decision {
                case .startNow:
                    summaryQueuedRunPayloads.removeValue(forKey: owner)
                    startSummaryRun(
                        for: entry,
                        owner: owner,
                        targetLanguage: targetLanguage,
                        detailLevel: detailLevel
                    )
                case .queuedWaiting, .alreadyWaiting:
                    summaryQueuedRunPayloads[owner] = payload
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
                    break
                }
            }
        }
    }

    private func startSummaryRun(
        for entry: Entry,
        owner: AgentRunOwner,
        targetLanguage: String,
        detailLevel: SummaryDetailLevel
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

        summaryRunStartTask = Task {
            let source = await resolveSummarySourceText(for: entry)
            if Task.isCancelled { return }

            let request = SummaryRunRequest(
                entryId: entryId,
                sourceText: source,
                targetLanguage: targetLanguage,
                detailLevel: detailLevel
            )
            let taskId = await appModel.startSummaryRun(request: request) { event in
                await MainActor.run {
                    handleSummaryRunEvent(event, entryId: entryId)
                }
            }
            await MainActor.run {
                summaryTaskId = taskId
            }
        }
    }

    private func resolveSummarySourceText(for entry: Entry) async -> String {
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

    private func fallbackSummarySourceText(for entry: Entry) -> String {
        let summary = (entry.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if summary.isEmpty == false {
            return summary
        }

        let title = (entry.title ?? "Untitled").trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Untitled" : title
    }

    private func abortSummary() {
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

    private func clearSummary(for entry: Entry) {
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
    private func handleSummaryRunEvent(_ event: SummaryRunEvent, entryId: Int64) {
        let runningSlotKey = summaryRunningSlotKey
        let runningOwner = summaryRunningOwner

        switch event {
        case .started(let taskId):
            summaryTaskId = taskId
            summaryActivePhase = .generating
            if let runningOwner {
                Task {
                    await appModel.agentRuntimeEngine.updatePhase(owner: runningOwner, phase: .requesting)
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
                    await appModel.agentRuntimeEngine.updatePhase(owner: runningOwner, phase: .generating)
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
        case .completed:
            isSummaryRunning = false
            summaryActivePhase = nil
            summaryTaskId = nil
            summaryRunStartTask = nil
            summaryRunningEntryId = nil
            summaryRunningSlotKey = nil
            summaryRunningOwner = nil
            if SummaryPolicy.shouldMarkCurrentEntryPersistedOnCompletion(
                completedEntryId: entryId,
                displayedEntryId: displayedEntryId
            ) {
                hasAnyPersistedSummaryForCurrentEntry = true
                Task {
                    await loadSummaryRecordForCurrentSlot(entryId: entryId)
                }
            }
            pruneSummaryStreamingStates()
            Task {
                if let runningOwner {
                    _ = await appModel.agentRuntimeEngine.finish(
                        owner: runningOwner, terminalPhase: .completed
                    )
                }
            }
            syncSummaryPlaceholderForCurrentState()
        case .failed(_, let failureReason):
            isSummaryRunning = false
            summaryActivePhase = nil
            summaryTaskId = nil
            summaryRunStartTask = nil
            summaryRunningEntryId = nil
            summaryRunningSlotKey = nil
            summaryRunningOwner = nil
            let shouldShowFailureMessage = displayedEntryId == entryId && summaryText.isEmpty
            pruneSummaryStreamingStates()
            Task {
                if let runningOwner {
                    _ = await appModel.agentRuntimeEngine.finish(
                        owner: runningOwner, terminalPhase: .failed
                    )
                }
            }
            if shouldShowFailureMessage, isSummaryRunning == false {
                topErrorBannerText = AgentRuntimeProjection.failureMessage(
                    for: failureReason,
                    taskKind: .summary
                )
                summaryPlaceholderText = AgentRuntimeProjection.summaryNoContentStatus()
            } else {
                syncSummaryPlaceholderForCurrentState()
            }
        case .cancelled:
            isSummaryRunning = false
            summaryActivePhase = nil
            summaryTaskId = nil
            summaryRunStartTask = nil
            summaryRunningEntryId = nil
            summaryRunningSlotKey = nil
            summaryRunningOwner = nil
            let shouldShowCancelledMessage = displayedEntryId == entryId && summaryText.isEmpty
            pruneSummaryStreamingStates()
            Task {
                if let runningOwner {
                    _ = await appModel.agentRuntimeEngine.finish(
                        owner: runningOwner, terminalPhase: .cancelled
                    )
                }
            }
            if shouldShowCancelledMessage, isSummaryRunning == false {
                summaryPlaceholderText = AgentRuntimeProjection.summaryCancelledStatus()
            } else {
                syncSummaryPlaceholderForCurrentState()
            }
        }
    }

    // MARK: - Summary control helpers

    private func syncSummaryControlsWithAgentDefaultsIfNeeded() async {
        guard hasAnyPersistedSummaryForCurrentEntry == false else {
            return
        }
        applySummaryAgentDefaults()
        await loadSummaryRecordForCurrentSlot(entryId: displayedEntryId)
    }

    private func applySummaryControls(targetLanguage: String, detailLevel: SummaryDetailLevel) {
        summaryTargetLanguage = AgentLanguageOption.normalizeCode(targetLanguage)
        summaryDetailLevel = detailLevel
    }

    private func applySummaryAgentDefaults() {
        let defaults = appModel.loadSummaryAgentDefaults()
        applySummaryControls(
            targetLanguage: defaults.targetLanguage,
            detailLevel: defaults.detailLevel
        )
    }

    private func makeSummarySlotKey(entryId: Int64, targetLanguage: String, detailLevel: SummaryDetailLevel) -> SummarySlotKey {
        SummarySlotKey(
            entryId: entryId,
            targetLanguage: AgentLanguageOption.normalizeCode(targetLanguage),
            detailLevel: detailLevel
        )
    }

    private func makeSummaryRunOwner(entryId: Int64, targetLanguage: String, detailLevel: SummaryDetailLevel) -> AgentRunOwner {
        AgentRunOwner(
            taskKind: .summary,
            entryId: entryId,
            slotKey: "\(AgentLanguageOption.normalizeCode(targetLanguage))|\(detailLevel.rawValue)"
        )
    }

    private func abandonSummaryWaiting(for previousEntryId: Int64, nextSelectedEntryId: Int64?) async {
        guard previousEntryId != nextSelectedEntryId else { return }
        let ownersToAbandon = await MainActor.run { () -> [AgentRunOwner] in
            summaryQueuedRunPayloads.keys.filter {
                $0.taskKind == .summary && $0.entryId == previousEntryId
            }
        }

        for owner in ownersToAbandon {
            await appModel.agentRuntimeEngine.abandonWaiting(owner: owner)
            _ = await MainActor.run {
                summaryQueuedRunPayloads.removeValue(forKey: owner)
            }
        }
    }

    private func isShowingSummarySlot(_ slotKey: SummarySlotKey) -> Bool {
        guard displayedEntryId == slotKey.entryId else {
            return false
        }
        let currentLanguage = AgentLanguageOption.normalizeCode(summaryTargetLanguage)
        return currentLanguage == slotKey.targetLanguage && summaryDetailLevel == slotKey.detailLevel
    }

    private func currentDisplayedSummarySlotKey() -> SummarySlotKey? {
        guard let entryId = displayedEntryId else {
            return nil
        }
        return makeSummarySlotKey(
            entryId: entryId,
            targetLanguage: summaryTargetLanguage,
            detailLevel: summaryDetailLevel
        )
    }

    private func pruneSummaryStreamingStates(now: Date = Date()) {
        let pinned = Set([summaryRunningSlotKey, currentDisplayedSummarySlotKey()].compactMap { $0 })
        summaryStreamingStates = SummaryStreamingCachePolicy.evict(
            states: summaryStreamingStates,
            now: now,
            ttl: Self.summaryStreamingStateTTL,
            capacity: Self.summaryStreamingStateCapacity,
            pinnedKeys: pinned
        )
    }

    private func syncSummaryPlaceholderForCurrentState() {
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

    private func hasPendingSummaryRequest(for entryId: Int64?) -> Bool {
        guard let entryId else { return false }
        return summaryQueuedRunPayloads.keys.contains { $0.entryId == entryId }
    }

    // MARK: - Auto-summary scheduling

    private func handleAutoSummaryToggleChange(_ enabled: Bool) {
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

    private func scheduleAutoSummaryForSelectedEntry() {
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

    private func checkAutoSummaryStartReadiness(entryId: Int64) async -> AgentPersistedStateCheckResult {
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

    private func runSummaryAutoActivation(for entry: Entry) async {
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
                    topErrorBannerText = nil
                    hasAnyPersistedSummaryForCurrentEntry = true
                    summaryFetchRetryEntryId = nil
                    syncSummaryPlaceholderForCurrentState()
                }
            },
            onRequestRun: {
                await MainActor.run {
                    topErrorBannerText = nil
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
                    topErrorBannerText = "Fetch data failed."
                    summaryFetchRetryEntryId = entryId
                    syncSummaryPlaceholderForCurrentState()
                }
            }
        )
    }

    // MARK: - Summary scroll helpers

    private func updateSummaryScrollFollowState() {
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

    private func scrollSummaryToBottom(using proxy: ScrollViewProxy, force: Bool = false) {
        guard force || summaryShouldFollowTail else {
            return
        }

        summaryIgnoreScrollStateUntil = Date().addingTimeInterval(0.25)
        withAnimation(.easeOut(duration: 0.16)) {
            proxy.scrollTo(Self.summaryScrollBottomAnchorID, anchor: .bottom)
        }
    }

    // MARK: - Static helpers and constants

    private static func renderMarkdownSummaryText(_ text: String) -> AttributedString {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return AttributedString("")
        }

        do {
            return try AttributedString(
                markdown: normalized,
                options: AttributedString.MarkdownParsingOptions(
                    interpretedSyntax: .inlineOnlyPreservingWhitespace,
                    failurePolicy: .returnPartiallyParsedIfPossible
                )
            )
        } catch {
            return AttributedString(normalized)
        }
    }

    private static let summaryDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static let summaryPanelExpandedKey = "ReaderSummaryPanelExpanded"
    private static let summaryPanelExpandedHeightKey = "ReaderSummaryPanelExpandedHeight"
    private static let summaryScrollCoordinateSpaceName = "ReaderSummaryScroll"
    private static let summaryScrollBottomAnchorID = "ReaderSummaryScrollBottomAnchor"
    private static let summaryStreamingStateTTL: TimeInterval = SummaryStreamingCachePolicy.defaultTTL
    private static let summaryStreamingStateCapacity: Int = SummaryStreamingCachePolicy.defaultCapacity

    private static func loadSummaryPanelExpandedState() -> Bool {
        UserDefaults.standard.object(forKey: summaryPanelExpandedKey) as? Bool ?? false
    }

    private static func loadSummaryPanelExpandedHeight() -> Double {
        let value = UserDefaults.standard.double(forKey: summaryPanelExpandedHeightKey)
        guard value > 0 else { return 280 }
        return value
    }

    private static func persistSummaryPanelExpandedHeight(_ height: Double) {
        UserDefaults.standard.set(height, forKey: summaryPanelExpandedHeightKey)
    }
}

// MARK: - Preference keys

private struct SummaryScrollViewportHeightPreferenceKey: PreferenceKey {
    static var defaultValue: Double = 0

    static func reduce(value: inout Double, nextValue: () -> Double) {
        value = nextValue()
    }
}

private struct SummaryScrollBottomMaxYPreferenceKey: PreferenceKey {
    static var defaultValue: Double = 0

    static func reduce(value: inout Double, nextValue: () -> Double) {
        value = nextValue()
    }
}
