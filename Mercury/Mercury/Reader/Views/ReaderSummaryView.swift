//
//  ReaderSummaryView.swift
//  Mercury
//
//  Created by Neo on 2026/2/22.
//

import SwiftUI
import AppKit

// MARK: - Private types

struct SummaryQueuedRunRequest: Sendable {
    let taskId: UUID
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
    @Binding var topBannerMessage: ReaderBannerMessage?
    let loadReaderHTML: (Entry, EffectiveReaderTheme) async -> ReaderBuildResult
    let effectiveReaderTheme: EffectiveReaderTheme

    @EnvironmentObject var appModel: AppModel
    @Environment(\.openSettings) var openSettings
    @Environment(\.localizationBundle) var bundle

    // MARK: - Panel geometry state

    @State var isSummaryPanelExpanded = Self.loadSummaryPanelExpandedState()
    @State var summaryPanelExpandedHeight = Self.loadSummaryPanelExpandedHeight()

    // MARK: - Summary control state

    @State var summaryTargetLanguage = "en"
    @State var summaryDetailLevel: SummaryDetailLevel = .medium
    @State var summaryAutoEnabled = false

    // MARK: - Summary content state

    @State var summaryText = ""
    @State var summaryRenderedText = AttributedString("")
    @State var summaryUpdatedAt: Date?
    @State var summaryDurationMs: Int?

    // MARK: - Summary loading/running state

    @State var isSummaryLoading = false
    @State var isSummaryRunning = false
    @State var summaryActivePhase: AgentRunPhase?
    @State var hasAnyPersistedSummaryForCurrentEntry = false

    // MARK: - Summary scroll state

    @State var summaryShouldFollowTail = true
    @State var summaryScrollViewportHeight: Double = 0
    @State var summaryScrollBottomMaxY: Double = 0
    @State var summaryIgnoreScrollStateUntil = Date.distantPast

    // MARK: - Summary runtime state

    @State var summaryRunStartTask: Task<Void, Never>?
    @State var summaryTaskId: UUID?
    @State var summaryRunningEntryId: Int64?
    @State var summaryRunningSlotKey: SummarySlotKey?
    @State var summaryRunningOwner: AgentRunOwner?
    @State var summaryQueuedRunPayloads: [AgentRunOwner: SummaryQueuedRunRequest] = [:]
    @State var summaryStreamingStates: [SummarySlotKey: SummaryStreamingCacheState] = [:]

    // MARK: - Auto-summary / UI state

    @State var autoSummaryDebounceTask: Task<Void, Never>?
    @State var showAutoSummaryEnableRiskAlert = false
    @State var summaryPlaceholderText = AgentRuntimeProjection.summaryNoContentStatus()
    @State var summaryFetchRetryEntryId: Int64?

    // Suppresses the availability banner after the first show until availability is restored.
    @State var summaryAvailabilityBannerSuppressed = false

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
        .alert(Text("Enable Auto-summary?", bundle: bundle), isPresented: $showAutoSummaryEnableRiskAlert) {
            Button(action: {
                summaryAutoEnabled = true
                scheduleAutoSummaryForSelectedEntry()
            }) { Text("Enable", bundle: bundle) }
            Button(action: {
                appModel.setSummaryAutoEnableWarningEnabled(false)
                summaryAutoEnabled = true
                scheduleAutoSummaryForSelectedEntry()
            }) { Text("Enable & Don't Ask Again", bundle: bundle) }
            Button(role: .cancel, action: {
                summaryAutoEnabled = false
            }) { Text("Cancel", bundle: bundle) }
        } message: {
            Text("Auto-summary may trigger model requests and generate additional usage cost.", bundle: bundle)
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
        .onChange(of: appModel.isSummaryAgentAvailable) { _, isAvailable in
            // Reset suppression when the agent becomes available so the banner
            // can appear again if it is later disabled.
            if isAvailable {
                summaryAvailabilityBannerSuppressed = false
            }
        }
        .task(id: displayedEntryId) {
            await refreshSummaryForSelectedEntry(displayedEntryId)
            scheduleAutoSummaryForSelectedEntry()
            checkAndSetAvailabilityBanner()
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

    // MARK: - Summary panel view

    @ViewBuilder
    private func summaryPanel(entry: Entry) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        isSummaryPanelExpanded.toggle()
                    } label: {
                        Label {
                            Text("Summary", bundle: bundle)
                        } icon: {
                            Image(systemName: isSummaryPanelExpanded ? "chevron.down" : "chevron.up")
                        }
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
                                    Text(level.labelKey, bundle: bundle).tag(level)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(width: 240)
                        }

                        Spacer(minLength: 12)

                        HStack(spacing: 16) {
                            Toggle(
                                isOn: Binding(
                                    get: { summaryAutoEnabled },
                                    set: { newValue in
                                        handleAutoSummaryToggleChange(newValue)
                                    }
                                )
                            ) { Text("Auto-summary", bundle: bundle) }
                                .toggleStyle(.checkbox)

                            HStack(spacing: 8) {
                                Button(action: {
                                    requestSummaryRun(for: entry, requestSource: .manual)
                                }) { Text("Summary", bundle: bundle) }
                                .disabled(entry.id == nil)

                                Button(action: {
                                    abortSummary()
                                }) { Text("Abort", bundle: bundle) }
                                .disabled(isSummaryRunning == false)

                                Button(action: {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(summaryText, forType: .string)
                                }) { Text("Copy", bundle: bundle) }
                                .disabled(summaryText.isEmpty)

                                Button(action: {
                                    clearSummary(for: entry)
                                }) { Text("Clear", bundle: bundle) }
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

    var summaryMetaRow: some View {
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
    // MARK: - Static helpers and constants

    static func renderMarkdownSummaryText(_ text: String) -> AttributedString {
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

    static let summaryDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static let summaryPanelExpandedKey = "ReaderSummaryPanelExpanded"
    static let summaryPanelExpandedHeightKey = "ReaderSummaryPanelExpandedHeight"
    static let summaryScrollCoordinateSpaceName = "ReaderSummaryScroll"
    static let summaryScrollBottomAnchorID = "ReaderSummaryScrollBottomAnchor"
    static let summaryStreamingStateTTL: TimeInterval = SummaryStreamingCachePolicy.defaultTTL
    static let summaryStreamingStateCapacity: Int = SummaryStreamingCachePolicy.defaultCapacity

    static func loadSummaryPanelExpandedState() -> Bool {
        UserDefaults.standard.object(forKey: summaryPanelExpandedKey) as? Bool ?? false
    }

    static func loadSummaryPanelExpandedHeight() -> Double {
        let value = UserDefaults.standard.double(forKey: summaryPanelExpandedHeightKey)
        guard value > 0 else { return 280 }
        return value
    }

    static func persistSummaryPanelExpandedHeight(_ height: Double) {
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
