//
//  ReaderDetailView.swift
//  Mercury
//
//  Created by Neo on 2026/2/4.
//

import SwiftUI
import AppKit
import CryptoKit

private enum SummaryRunTrigger {
    case manual
    case auto

    var waitingTrigger: SummaryWaitingTrigger {
        switch self {
        case .manual: return .manual
        case .auto: return .auto
        }
    }
}

private struct SummarySlotKey: Hashable {
    let entryId: Int64
    let targetLanguage: String
    let detailLevel: AISummaryDetailLevel
}

private struct TranslationQueuedRunRequest: Sendable {
    let owner: AgentRunOwner
    let slotKey: AITranslationSlotKey
    let snapshot: ReaderSourceSegmentsSnapshot
    let targetLanguage: String
}

struct ReaderDetailView: View {
    private static let translationHeaderSegmentID = "seg_meta_title_author"

    @EnvironmentObject var appModel: AppModel
    @Environment(\.colorScheme) private var colorScheme

    let selectedEntry: Entry?
    @Binding var readingModeRaw: String
    @Binding var readerThemePresetIDRaw: String
    @Binding var readerThemeModeRaw: String
    @Binding var readerThemeOverrideFontSize: Double
    @Binding var readerThemeOverrideLineHeight: Double
    @Binding var readerThemeOverrideContentWidth: Double
    @Binding var readerThemeOverrideFontFamilyRaw: String
    @Binding var readerThemeQuickStylePresetIDRaw: String
    let loadReaderHTML: (Entry, EffectiveReaderTheme) async -> ReaderBuildResult
    let onOpenDebugIssues: (() -> Void)?

    @State private var readerHTML: String?
    @State private var sourceReaderHTML: String?
    @State private var isLoadingReader = false
    @State private var readerError: String?
    @State private var isThemePanelPresented = false
    @State private var isSummaryPanelExpanded = Self.loadSummaryPanelExpandedState()
    @State private var summaryPanelExpandedHeight = Self.loadSummaryPanelExpandedHeight()
    @State private var summaryTargetLanguage = "en"
    @State private var summaryDetailLevel: AISummaryDetailLevel = .medium
    @State private var summaryAutoEnabled = false
    @State private var summaryText = ""
    @State private var summaryRenderedText = AttributedString("")
    @State private var summaryUpdatedAt: Date?
    @State private var summaryDurationMs: Int?
    @State private var isSummaryLoading = false
    @State private var isSummaryRunning = false
    @State private var summaryActivePhase: AgentRunPhase?
    @State private var hasAnyPersistedSummaryForCurrentEntry = false
    @State private var summaryShouldFollowTail = true
    @State private var summaryScrollViewportHeight: Double = 0
    @State private var summaryScrollBottomMaxY: Double = 0
    @State private var summaryIgnoreScrollStateUntil = Date.distantPast
    @State private var summaryRunStartTask: Task<Void, Never>?
    @State private var summaryTaskId: UUID?
    @State private var summaryRunningEntryId: Int64?
    @State private var summaryRunningSlotKey: SummarySlotKey?
    @State private var summaryRunningOwner: AgentRunOwner?
    @State private var summaryPendingRunTriggers: [AgentRunOwner: SummaryRunTrigger] = [:]
    @State private var summaryStreamingStates: [SummarySlotKey: SummaryStreamingCacheState] = [:]
    @State private var summaryDisplayEntryId: Int64?
    @State private var autoSummaryDebounceTask: Task<Void, Never>?
    @State private var showAutoSummaryEnableRiskAlert = false
    @State private var summaryPlaceholderText = "No summary"
    @State private var summaryFetchRetryEntryId: Int64?
    @State private var translationMode: AITranslationMode = .original
    @State private var translationCurrentSlotKey: AITranslationSlotKey?
    @State private var translationManualStartRequestedEntryId: Int64?
    @State private var translationRunningOwner: AgentRunOwner?
    @State private var translationPendingRunRequests: [AgentRunOwner: TranslationQueuedRunRequest] = [:]
    @State private var translationStatusBySlot: [AITranslationSlotKey: String] = [:]
    @State private var hasPersistedTranslationForCurrentSlot = false
    @State private var topErrorBannerText: String?

    var body: some View {
        bodyWithAlert
    }

    private var bodyWithNavigation: some View {
        mainContent
            .navigationTitle(selectedEntry?.title ?? "Reader")
            .toolbar {
                entryToolbar
            }
    }

    private var bodyWithLifecycle: some View {
        AnyView(bodyWithNavigation)
            .onExitCommand {
                guard isThemePanelPresented else { return }
                isThemePanelPresented = false
            }
            .onChange(of: isSummaryPanelExpanded) { _, expanded in
                UserDefaults.standard.set(expanded, forKey: Self.summaryPanelExpandedKey)
            }
            .onChange(of: summaryTargetLanguage) { _, _ in
                Task {
                    await loadSummaryRecordForCurrentSlot(entryId: selectedEntry?.id)
                }
            }
            .onChange(of: summaryDetailLevel) { _, _ in
                Task {
                    await loadSummaryRecordForCurrentSlot(entryId: selectedEntry?.id)
                }
            }
            .onChange(of: selectedEntry?.id) { _, newEntryId in
                let previousEntryId = summaryDisplayEntryId
                summaryDisplayEntryId = newEntryId
                topErrorBannerText = nil
                hasPersistedTranslationForCurrentSlot = false
                translationCurrentSlotKey = nil
                translationMode = .original
                translationManualStartRequestedEntryId = nil
                if let previousEntryId {
                    Task {
                        await abandonTranslationWaiting(for: previousEntryId, nextSelectedEntryId: newEntryId)
                    }
                }
                sourceReaderHTML = nil
                setReaderHTML(nil)
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
                    summaryPlaceholderText = "No summary"
                }
                if let previousEntryId {
                    Task {
                        await abandonAutoSummaryWaiting(for: previousEntryId, nextSelectedEntryId: newEntryId)
                    }
                }
            }
            .onChange(of: readingModeRaw) { _, newValue in
                let mode = ReadingMode(rawValue: newValue) ?? .reader
                if mode != .reader {
                    translationMode = .original
                }
            }
        .onReceive(NotificationCenter.default.publisher(for: .summaryAgentDefaultsDidChange)) { _ in
            Task {
                await syncSummaryControlsWithAgentDefaultsIfNeeded()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .translationAgentDefaultsDidChange)) { _ in
            Task {
                await syncTranslationPresentationForCurrentEntry()
                await refreshTranslationClearAvailabilityForCurrentEntry()
            }
        }
            .onChange(of: summaryText) { _, newText in
                summaryRenderedText = Self.renderMarkdownSummaryText(newText)
            }
    }

    private var bodyWithAlert: some View {
        AnyView(bodyWithLifecycle)
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
    }

    private var mainContent: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let entry = selectedEntry {
                    readingContent(for: entry)
                } else {
                    emptyState
                }
            }

            if isThemePanelPresented {
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture {
                        isThemePanelPresented = false
                    }

                themePanelView
                    .padding(.top, 8)
                    .padding(.trailing, 12)
            }
        }
    }

    @ViewBuilder
    private func readingContent(for entry: Entry) -> some View {
        let needsReader = (ReadingMode(rawValue: readingModeRaw) ?? .reader) != .web
        let parsedURL = parseEntryURL(entry)
        let collapsedHeight: Double = 44
        let minExpandedHeight: Double = 220
        let maxExpandedHeight: Double = 520
        let clampedExpandedHeight = min(max(summaryPanelExpandedHeight, minExpandedHeight), maxExpandedHeight)
        let summaryHeight = isSummaryPanelExpanded ? clampedExpandedHeight : collapsedHeight

        VStack(spacing: 0) {
            if let topErrorBannerText,
               topErrorBannerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                topErrorBanner(message: topErrorBannerText)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 8)
            }

            topPaneContent(parsedURL: parsedURL)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

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

            summaryPanel(entry: entry)
                .frame(height: summaryHeight)
        }
        .task(id: readerTaskKey(entryId: entry.id, needsReader: needsReader)) {
            guard needsReader else { return }
            await loadReader(entry: entry, theme: effectiveReaderTheme)
        }
        .task(id: entry.id) {
            await refreshSummaryForSelectedEntry(entry.id)
            scheduleAutoSummaryForSelectedEntry()
        }
    }

    private func topErrorBanner(message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.subheadline)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button {
                topErrorBannerText = nil
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var readerUnavailableContent: some View {
        VStack(spacing: 12) {
            Image(systemName: "link.badge.plus")
                .imageScale(.large)
                .foregroundStyle(.secondary)
            Text("No valid article URL")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func parseEntryURL(_ entry: Entry) -> (url: URL, urlString: String)? {
        guard let urlString = entry.url,
              let url = URL(string: urlString) else {
            return nil
        }
        return (url: url, urlString: urlString)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .imageScale(.large)
                .foregroundStyle(.secondary)
            Text("Select an entry to read")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ToolbarContentBuilder
    private var entryToolbar: some ToolbarContent {
        if selectedEntry != nil {
            ToolbarItem(placement: .primaryAction) {
                modeToolbar(readingMode: Binding(
                    get: { ReadingMode(rawValue: readingModeRaw) ?? .reader },
                    set: { readingModeRaw = $0.rawValue }
                ))
            }

            // macOS 26 only
            // ToolbarSpacer(.fixed)

            if shouldShowTranslationToolbarButton {
                ToolbarItemGroup(placement: .primaryAction) {
                    translationToolbarButton
                    translationClearToolbarButton
                }
            }

            // macOS 26 only
            // ToolbarSpacer(.fixed)

            ToolbarItemGroup(placement: .primaryAction) {
                themePreviewMenu
                if let urlString = selectedEntry?.url,
                   let url = URL(string: urlString) {
                    shareToolbarMenu(url: url, urlString: urlString)
                }
            }
        }

        if let onOpenDebugIssues {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    onOpenDebugIssues()
                } label: {
                    Image(systemName: "ladybug")
                }
                .help("Open debug issues")
            }
        }
    }

    private func modeToolbar(readingMode: Binding<ReadingMode>) -> some View {
        Picker("", selection: readingMode) {
            ForEach(ReadingMode.allCases) { mode in
                Text(mode.label)
                    .tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 220)
        .labelsHidden()
    }

    private var shouldShowTranslationToolbarButton: Bool {
        let readingMode = ReadingMode(rawValue: readingModeRaw) ?? .reader
        return TranslationModePolicy.isToolbarButtonVisible(readingMode: readingMode)
    }

    private var translationToolbarButton: some View {
        Button {
            toggleTranslationMode()
        } label: {
            Image(systemName: TranslationModePolicy.toolbarButtonIconName(for: translationMode))
        }
        .accessibilityLabel(translationMode == .original ? "Switch to Translation" : "Return to Original")
        .help(translationMode == .original ? "Switch to Translation" : "Return to Original")
    }

    private var translationClearToolbarButton: some View {
        Button {
            Task {
                await clearTranslationForCurrentEntry()
            }
        } label: {
            Image(systemName: "eraser")
        }
        .disabled(canClearTranslation == false)
        .accessibilityLabel("Clear Translation")
        .help("Clear saved translation for current language")
    }

    private var canClearTranslation: Bool {
        hasPersistedTranslationForCurrentSlot
    }

    private func toggleTranslationMode() {
        let nextMode = TranslationModePolicy.toggledMode(from: translationMode)
        translationMode = nextMode
        if nextMode == .bilingual {
            translationManualStartRequestedEntryId = selectedEntry?.id
            clearTranslationTerminalStatuses()
        } else {
            translationManualStartRequestedEntryId = nil
            if let slotKey = translationCurrentSlotKey {
                let owner = makeTranslationRunOwner(slotKey: slotKey)
                translationPendingRunRequests.removeValue(forKey: owner)
                Task {
                    await appModel.agentRunCoordinator.abandonWaiting(owner: owner)
                    await MainActor.run {
                        if translationStatusBySlot[slotKey] == AITranslationSegmentStatusText.waitingForPreviousRun.rawValue {
                            translationStatusBySlot[slotKey] = AITranslationGlobalStatusText.noTranslationYet
                        }
                    }
                }
            }
        }
        Task {
            await syncTranslationPresentationForCurrentEntry()
        }
    }

    @MainActor
    private func clearTranslationForCurrentEntry() async {
        guard let entryId = selectedEntry?.id,
              let sourceReaderHTML else {
            return
        }

        let snapshot: ReaderSourceSegmentsSnapshot
        let headerSourceText = translationHeaderSourceText(for: selectedEntry, renderedHTML: sourceReaderHTML)
        do {
            let baseSnapshot = try TranslationSegmentExtractor.extractFromRenderedHTML(
                entryId: entryId,
                renderedHTML: sourceReaderHTML
            )
            snapshot = makeTranslationSnapshot(
                baseSnapshot: baseSnapshot,
                headerSourceText: headerSourceText
            )
        } catch {
            return
        }

        let targetLanguage = appModel.loadTranslationAgentDefaults().targetLanguage
        let slotKey = appModel.makeTranslationSlotKey(
            entryId: entryId,
            targetLanguage: targetLanguage,
            sourceContentHash: snapshot.sourceContentHash,
            segmenterVersion: snapshot.segmenterVersion
        )
        translationCurrentSlotKey = slotKey

        do {
            let deleted = try await appModel.deleteTranslationRecord(slotKey: slotKey)
            if deleted == false {
                hasPersistedTranslationForCurrentSlot = false
                return
            }
            let owner = makeTranslationRunOwner(slotKey: slotKey)
            translationPendingRunRequests.removeValue(forKey: owner)
            translationStatusBySlot[slotKey] = nil
            hasPersistedTranslationForCurrentSlot = false
            await syncTranslationPresentationForCurrentEntry()
            await refreshTranslationClearAvailabilityForCurrentEntry()
        } catch {
            appModel.reportDebugIssue(
                title: "Clear Translation Failed",
                detail: error.localizedDescription,
                category: .task
            )
        }
    }

    private var themePreviewMenu: some View {
        Button {
            isThemePanelPresented.toggle()
        } label: {
            Image(systemName: "paintpalette")
        }
        .help(isThemePanelPresented ? "Close reader theme preview" : "Open reader theme preview")
    }

    private func shareToolbarMenu(url: URL, urlString: String) -> some View {
        Menu {
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(urlString, forType: .string)
            }
            Button("Open in Default Browser") {
                NSWorkspace.shared.open(url)
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .menuIndicator(.hidden)
        .help("Share")
    }

    private var themePanelView: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text(ReaderThemeControlText.themeSection)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ReaderThemePresetPicker(label: ReaderThemeControlText.themeSection, selection: $readerThemePresetIDRaw)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(ReaderThemeControlText.appearance)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ReaderThemeModePicker(label: ReaderThemeControlText.appearance, selection: $readerThemeModeRaw)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(ReaderThemeControlText.quickStyle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ReaderThemeQuickStylePicker(label: ReaderThemeControlText.quickStyle, selection: $readerThemeQuickStylePresetIDRaw)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(ReaderThemeControlText.fontFamily)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ReaderThemeFontFamilyPicker(label: ReaderThemeControlText.fontFamily, selection: $readerThemeOverrideFontFamilyRaw)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Font Size")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    fontStepButton(systemName: "minus") {
                        decreaseFontSize()
                    }
                    Text("\(Int(currentFontSize))")
                        .font(.body.monospacedDigit())
                        .frame(minWidth: 30)
                    fontStepButton(systemName: "plus") {
                        increaseFontSize()
                    }
                }
            }

            Button("Reset") {
                resetPreviewOverrides()
            }
            .padding(.top, 8)
            .disabled(
                ReaderThemeRules.hasAnyOverrides(
                    fontSizeOverride: readerThemeOverrideFontSize,
                    lineHeightOverride: readerThemeOverrideLineHeight,
                    contentWidthOverride: readerThemeOverrideContentWidth,
                    fontFamilyOptionRaw: readerThemeOverrideFontFamilyRaw,
                    quickStylePresetRaw: readerThemeQuickStylePresetIDRaw
                ) == false
            )
        }
        .padding(10)
        .frame(width: 228)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 4)
        .onTapGesture {
        }
    }

    private func fontStepButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var currentFontSize: Double {
        readerThemeOverrideFontSize > 0 ? readerThemeOverrideFontSize : ReaderThemeRules.defaultFontSizeFallback
    }

    private func decreaseFontSize() {
        readerThemeOverrideFontSize = ReaderThemeRules.clampFontSize(currentFontSize - 1)
    }

    private func increaseFontSize() {
        readerThemeOverrideFontSize = ReaderThemeRules.clampFontSize(currentFontSize + 1)
    }

    private func resetPreviewOverrides() {
        let reset = ReaderThemeRules.resetOverrideStorage
        readerThemeOverrideFontSize = reset.fontSizeOverride
        readerThemeOverrideLineHeight = reset.lineHeightOverride
        readerThemeOverrideContentWidth = reset.contentWidthOverride
        readerThemeOverrideFontFamilyRaw = reset.fontFamilyOptionRaw
        readerThemeQuickStylePresetIDRaw = reset.quickStylePresetRaw
    }

    private func webContent(url: URL, urlString: String) -> some View {
        VStack(spacing: 0) {
            webUrlBar(urlString)
            Divider()
            WebView(url: url)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func topPaneContent(parsedURL: (url: URL, urlString: String)?) -> some View {
        if let parsedURL {
            let mode = ReadingMode(rawValue: readingModeRaw) ?? .reader
            let showsReaderPane = mode != .web
            let showsWebPane = mode != .reader
            GeometryReader { geometry in
                let totalWidth = max(geometry.size.width, 0)
                let readerWidth: Double = mode == .web ? 0 : (mode == .dual ? totalWidth / 2 : totalWidth)
                let webWidth: Double = mode == .reader ? 0 : (mode == .dual ? totalWidth / 2 : totalWidth)

                HStack(spacing: 0) {
                    readerPaneSlot(baseURL: parsedURL.url, isVisible: showsReaderPane)
                        .frame(width: readerWidth)
                        .opacity(readerWidth > 0 ? 1 : 0)
                        .allowsHitTesting(readerWidth > 0)
                        .clipped()

                    Divider()
                        .frame(width: mode == .dual ? 1 : 0)
                        .opacity(mode == .dual ? 1 : 0)

                    webPaneSlot(url: parsedURL.url, urlString: parsedURL.urlString, isVisible: showsWebPane)
                        .frame(width: webWidth)
                        .opacity(webWidth > 0 ? 1 : 0)
                        .allowsHitTesting(webWidth > 0)
                        .clipped()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            readerUnavailableContent
        }
    }

    @ViewBuilder
    private func readerPaneSlot(baseURL: URL, isVisible: Bool) -> some View {
        if isVisible {
            readerContent(baseURL: baseURL, webViewIdentity: readerWebViewIdentity)
        } else {
            Color(nsColor: .textBackgroundColor)
        }
    }

    @ViewBuilder
    private func webPaneSlot(url: URL, urlString: String, isVisible: Bool) -> some View {
        if isVisible {
            webContent(url: url, urlString: urlString)
        } else {
            Color(nsColor: .windowBackgroundColor)
        }
    }

    private func webUrlBar(_ urlString: String) -> some View {
        HStack(spacing: 8) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(urlString, forType: .string)
            } label: {
                Image(systemName: "link")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Copy URL")
            Text(urlString)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func readerContent(baseURL: URL, webViewIdentity: String) -> some View {
        ZStack {
            Group {
                if let readerHTML {
                    WebView(html: readerHTML, baseURL: baseURL)
                        .id(webViewIdentity)
                } else {
                    readerPlaceholder
                }
            }

            if isLoadingReader {
                ProgressView("Loading…")
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var readerWebViewIdentity: String {
        "\(selectedEntry?.id ?? 0)-\(effectiveReaderTheme.cacheThemeID)"
    }

    private func setReaderHTML(_ html: String?) {
        if readerHTML == html {
            return
        }
        readerHTML = html
    }

    private var readerPlaceholder: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(readerError ?? "")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func loadReader(entry: Entry, theme: EffectiveReaderTheme) async {
        isLoadingReader = true
        readerError = nil
        defer { isLoadingReader = false }

        let result = await loadReaderHTML(entry, theme)
        if Task.isCancelled { return }

        if let html = result.html {
            sourceReaderHTML = html
            setReaderHTML(html)
            readerError = nil
            await syncTranslationPresentationForCurrentEntry()
            await refreshTranslationClearAvailabilityForCurrentEntry()
        } else {
            sourceReaderHTML = nil
            setReaderHTML(nil)
            readerError = result.errorMessage ?? "Failed to build reader content."
            hasPersistedTranslationForCurrentSlot = false
        }
    }

    private func readerTaskKey(entryId: Int64?, needsReader: Bool) -> String {
        "\(entryId ?? 0)-\(needsReader)-\(readingModeRaw)-\(effectiveReaderTheme.cacheThemeID)"
    }

    @MainActor
    private func syncTranslationPresentationForCurrentEntry() async {
        guard translationMode == .bilingual else {
            if let sourceReaderHTML {
                setReaderHTML(sourceReaderHTML)
            }
            return
        }

        guard let entryId = selectedEntry?.id,
              let sourceReaderHTML else {
            return
        }

        let snapshot: ReaderSourceSegmentsSnapshot
        let headerSourceText = translationHeaderSourceText(for: selectedEntry, renderedHTML: sourceReaderHTML)
        do {
            let baseSnapshot = try TranslationSegmentExtractor.extractFromRenderedHTML(
                entryId: entryId,
                renderedHTML: sourceReaderHTML
            )
            snapshot = makeTranslationSnapshot(
                baseSnapshot: baseSnapshot,
                headerSourceText: headerSourceText
            )
        } catch {
            setReaderHTML(sourceReaderHTML)
            return
        }

        let targetLanguage = appModel.loadTranslationAgentDefaults().targetLanguage
        let slotKey = appModel.makeTranslationSlotKey(
            entryId: entryId,
            targetLanguage: targetLanguage,
            sourceContentHash: snapshot.sourceContentHash,
            segmenterVersion: snapshot.segmenterVersion
        )
        translationCurrentSlotKey = slotKey

        await runTranslationActivation(
            entryId: entryId,
            slotKey: slotKey,
            snapshot: snapshot,
            sourceReaderHTML: sourceReaderHTML,
            headerSourceText: headerSourceText,
            targetLanguage: targetLanguage
        )
    }

    @MainActor
    private func runTranslationActivation(
        entryId: Int64,
        slotKey: AITranslationSlotKey,
        snapshot: ReaderSourceSegmentsSnapshot,
        sourceReaderHTML: String,
        headerSourceText: String?,
        targetLanguage: String
    ) async {
        var persistedRecord: AITranslationStoredRecord?
        let context = AgentEntryActivationContext(
            autoEnabled: translationManualStartRequestedEntryId == entryId,
            displayedEntryId: selectedEntry?.id,
            candidateEntryId: entryId
        )

        await AgentEntryActivationCoordinator.run(
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
                guard selectedEntry?.id == entryId else {
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
                translationStatusBySlot[slotKey] = nil
            },
            onRequestRun: {
                guard selectedEntry?.id == entryId else {
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
                guard selectedEntry?.id == entryId else {
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
                guard selectedEntry?.id == entryId else {
                    return
                }
                hasPersistedTranslationForCurrentSlot = false
                topErrorBannerText = AITranslationGlobalStatusText.fetchFailedRetry
                translationStatusBySlot[slotKey] = AITranslationGlobalStatusText.noTranslationYet
                applyTranslationProjection(
                    entryId: entryId,
                    slotKey: slotKey,
                    sourceReaderHTML: sourceReaderHTML,
                    translatedBySegmentID: [:],
                    missingStatusText: AITranslationGlobalStatusText.noTranslationYet,
                    headerTranslatedText: nil,
                    headerStatusText: headerSourceText == nil ? nil : AITranslationGlobalStatusText.noTranslationYet
                )
            }
        )
    }

    @MainActor
    private func renderTranslationMissingState(
        entryId: Int64,
        slotKey: AITranslationSlotKey,
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
            missingStatusText = await currentTranslationMissingStatusText(for: owner, slotKey: slotKey)
            translationStatusBySlot[slotKey] = missingStatusText
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
        guard let entryId = selectedEntry?.id,
              let sourceReaderHTML else {
            hasPersistedTranslationForCurrentSlot = false
            return
        }

        let snapshot: ReaderSourceSegmentsSnapshot
        let headerSourceText = translationHeaderSourceText(for: selectedEntry, renderedHTML: sourceReaderHTML)
        do {
            let baseSnapshot = try TranslationSegmentExtractor.extractFromRenderedHTML(
                entryId: entryId,
                renderedHTML: sourceReaderHTML
            )
            snapshot = makeTranslationSnapshot(
                baseSnapshot: baseSnapshot,
                headerSourceText: headerSourceText
            )
        } catch {
            hasPersistedTranslationForCurrentSlot = false
            return
        }

        let targetLanguage = appModel.loadTranslationAgentDefaults().targetLanguage
        let slotKey = appModel.makeTranslationSlotKey(
            entryId: entryId,
            targetLanguage: targetLanguage,
            sourceContentHash: snapshot.sourceContentHash,
            segmenterVersion: snapshot.segmenterVersion
        )
        translationCurrentSlotKey = slotKey

        do {
            hasPersistedTranslationForCurrentSlot = try await appModel.loadTranslationRecord(slotKey: slotKey) != nil
        } catch {
            hasPersistedTranslationForCurrentSlot = false
        }
    }

    @MainActor
    private func requestTranslationRun(
        owner: AgentRunOwner,
        slotKey: AITranslationSlotKey,
        snapshot: ReaderSourceSegmentsSnapshot,
        targetLanguage: String
    ) async -> String {
        let request = TranslationQueuedRunRequest(
            owner: owner,
            slotKey: slotKey,
            snapshot: snapshot,
            targetLanguage: targetLanguage
        )
        let decision = await appModel.agentRunCoordinator.requestStart(owner: owner)
        switch decision {
        case .startNow:
            translationPendingRunRequests.removeValue(forKey: owner)
            startTranslationRun(request)
            translationStatusBySlot[slotKey] = AITranslationSegmentStatusText.requesting.rawValue
            return AITranslationSegmentStatusText.requesting.rawValue
        case .queuedWaiting, .alreadyWaiting:
            translationPendingRunRequests[owner] = request
            let waitingText = AITranslationSegmentStatusText.waitingForPreviousRun.rawValue
            translationStatusBySlot[slotKey] = waitingText
            return waitingText
        case .alreadyActive:
            let status = translationStatusBySlot[slotKey] ?? AITranslationSegmentStatusText.generating.rawValue
            translationStatusBySlot[slotKey] = status
            return status
        }
    }

    @MainActor
    private func currentTranslationMissingStatusText(
        for owner: AgentRunOwner,
        slotKey: AITranslationSlotKey
    ) async -> String {
        if let state = await appModel.agentRunCoordinator.state(for: owner) {
            if let status = state.statusText, status.isEmpty == false {
                return status
            }

            if state.phase == .failed || state.phase == .timedOut {
                return AITranslationGlobalStatusText.noTranslationYet
            }
            if state.phase == .completed || state.phase == .cancelled {
                return AITranslationGlobalStatusText.noTranslationYet
            }

            let input = AgentDisplayProjectionInput(
                hasContent: false,
                isLoading: false,
                hasFetchFailure: false,
                hasPendingRequest: state.phase == .waiting,
                activePhase: state.phase
            )
            return AgentDisplayProjection.placeholderText(
                input: input,
                strings: AgentDisplayStrings(
                    noContent: AITranslationGlobalStatusText.noTranslationYet,
                    loading: AITranslationSegmentStatusText.generating.rawValue,
                    waiting: AITranslationSegmentStatusText.waitingForPreviousRun.rawValue,
                    requesting: AITranslationSegmentStatusText.requesting.rawValue,
                    generating: AITranslationSegmentStatusText.generating.rawValue,
                    persisting: AITranslationSegmentStatusText.persisting.rawValue,
                    fetchFailedRetry: AITranslationGlobalStatusText.fetchFailedRetry
                )
            )
        }

        if let cachedStatus = translationStatusBySlot[slotKey],
           Self.translationTransientStatuses.contains(cachedStatus) {
            return AITranslationGlobalStatusText.noTranslationYet
        }
        return translationStatusBySlot[slotKey] ?? AITranslationGlobalStatusText.noTranslationYet
    }

    @MainActor
    private func startTranslationRun(_ request: TranslationQueuedRunRequest) {
        translationRunningOwner = request.owner
        translationStatusBySlot[request.slotKey] = AITranslationSegmentStatusText.requesting.rawValue
        topErrorBannerText = nil

        Task {
            _ = await appModel.startTranslationRun(
                request: AITranslationRunRequest(
                    entryId: request.snapshot.entryId,
                    targetLanguage: request.targetLanguage,
                    sourceSnapshot: request.snapshot
                ),
                onEvent: { event in
                    await MainActor.run {
                        handleTranslationRunEvent(event, request: request)
                    }
                }
            )
        }
    }

    @MainActor
    private func handleTranslationRunEvent(
        _ event: AITranslationRunEvent,
        request: TranslationQueuedRunRequest
    ) {
        switch event {
        case .started:
            translationStatusBySlot[request.slotKey] = AITranslationSegmentStatusText.requesting.rawValue
            Task {
                await appModel.agentRunCoordinator.updatePhase(owner: request.owner, phase: .requesting)
                await syncTranslationPresentationForCurrentEntry()
            }
        case .strategySelected:
            translationStatusBySlot[request.slotKey] = AITranslationSegmentStatusText.generating.rawValue
            Task {
                await appModel.agentRunCoordinator.updatePhase(owner: request.owner, phase: .generating)
                await syncTranslationPresentationForCurrentEntry()
            }
        case .token:
            if translationStatusBySlot[request.slotKey] != AITranslationSegmentStatusText.generating.rawValue {
                translationStatusBySlot[request.slotKey] = AITranslationSegmentStatusText.generating.rawValue
            }
        case .persisting:
            translationStatusBySlot[request.slotKey] = AITranslationSegmentStatusText.persisting.rawValue
            Task {
                await appModel.agentRunCoordinator.updatePhase(owner: request.owner, phase: .persisting)
                await syncTranslationPresentationForCurrentEntry()
            }
        case .completed:
            translationStatusBySlot[request.slotKey] = nil
            topErrorBannerText = nil
            if translationRunningOwner == request.owner {
                translationRunningOwner = nil
            }
            Task {
                let promoted = await appModel.agentRunCoordinator.finish(owner: request.owner, terminalPhase: .completed)
                await syncTranslationPresentationForCurrentEntry()
                await refreshTranslationClearAvailabilityForCurrentEntry()
                await processPromotedTranslationOwner(promoted)
            }
        case .failed(_, let failureReason):
            if translationRunningOwner == request.owner {
                translationRunningOwner = nil
            }
            topErrorBannerText = AgentFailureMessageProjection.message(
                for: failureReason,
                taskKind: .translation
            )
            translationStatusBySlot[request.slotKey] = AITranslationGlobalStatusText.noTranslationYet
            Task {
                let terminalPhase: AgentRunPhase = failureReason == .timedOut ? .timedOut : .failed
                let promoted = await appModel.agentRunCoordinator.finish(owner: request.owner, terminalPhase: terminalPhase)
                await syncTranslationPresentationForCurrentEntry()
                await processPromotedTranslationOwner(promoted)
            }
        case .cancelled:
            if translationRunningOwner == request.owner {
                translationRunningOwner = nil
            }
            translationStatusBySlot[request.slotKey] = AITranslationGlobalStatusText.noTranslationYet
            Task {
                let promoted = await appModel.agentRunCoordinator.finish(owner: request.owner, terminalPhase: .cancelled)
                await syncTranslationPresentationForCurrentEntry()
                await processPromotedTranslationOwner(promoted)
            }
        }
    }

    private func clearTranslationTerminalStatuses() {
        let blockedStatuses: Set<String> = [
            AITranslationGlobalStatusText.noTranslationYet,
            AITranslationGlobalStatusText.fetchFailedRetry
        ]
        translationStatusBySlot = translationStatusBySlot.filter { _, status in
            blockedStatuses.contains(status) == false
        }
    }

    private func makeTranslationRunOwner(slotKey: AITranslationSlotKey) -> AgentRunOwner {
        AgentRunOwner(
            taskKind: .translation,
            entryId: slotKey.entryId,
            slotKey: "\(slotKey.targetLanguage)|\(slotKey.sourceContentHash)|\(slotKey.segmenterVersion)"
        )
    }

    private func applyTranslationProjection(
        entryId: Int64,
        slotKey: AITranslationSlotKey,
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
                detail: "entryId=\(entryId)\nslot=\(slotKey.targetLanguage)|\(slotKey.sourceContentHash)|\(slotKey.segmenterVersion)\nreason=\(error.localizedDescription)",
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

    private static let translationTransientStatuses: Set<String> = [
        AITranslationSegmentStatusText.waitingForPreviousRun.rawValue,
        AITranslationSegmentStatusText.requesting.rawValue,
        AITranslationSegmentStatusText.generating.rawValue,
        AITranslationSegmentStatusText.persisting.rawValue
    ]

    private func processPromotedTranslationOwner(_ initialOwner: AgentRunOwner?) async {
        var nextOwner = initialOwner
        while let owner = nextOwner {
            guard let request = await MainActor.run(body: {
                translationPendingRunRequests.removeValue(forKey: owner)
            }) else {
                nextOwner = await appModel.agentRunCoordinator.finish(owner: owner, terminalPhase: .cancelled)
                continue
            }

            let selectedEntryId = await MainActor.run { selectedEntry?.id }
            guard selectedEntryId == owner.entryId else {
                nextOwner = await appModel.agentRunCoordinator.finish(owner: owner, terminalPhase: .cancelled)
                continue
            }

            await MainActor.run {
                startTranslationRun(request)
            }
            break
        }
    }

    private func abandonTranslationWaiting(for previousEntryId: Int64, nextSelectedEntryId: Int64?) async {
        guard previousEntryId != nextSelectedEntryId else {
            return
        }
        await appModel.agentRunCoordinator.abandonWaiting(taskKind: .translation, entryId: previousEntryId)
        await MainActor.run {
            let ownersToDrop = translationPendingRunRequests.keys.filter { $0.entryId == previousEntryId }
            for owner in ownersToDrop {
                translationPendingRunRequests.removeValue(forKey: owner)
            }
            translationStatusBySlot = translationStatusBySlot.filter { slotKey, status in
                guard status == AITranslationSegmentStatusText.waitingForPreviousRun.rawValue else {
                    return true
                }
                return slotKey.entryId != previousEntryId
            }
        }
    }

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

    private var effectiveReaderTheme: EffectiveReaderTheme {
        let presetID = ReaderThemePresetID(rawValue: readerThemePresetIDRaw) ?? .classic
        let mode = ReaderThemeMode(rawValue: readerThemeModeRaw) ?? .auto
        return ReaderThemeResolver.resolve(
            presetID: presetID,
            mode: mode,
            isSystemDark: colorScheme == .dark,
            override: readerThemeOverride
        )
    }

    private var resolvedReaderThemeVariant: ReaderThemeVariant {
        let mode = ReaderThemeMode(rawValue: readerThemeModeRaw) ?? .auto
        return ReaderThemeResolver.resolveVariant(mode: mode, isSystemDark: colorScheme == .dark)
    }

    private var readerThemeOverride: ReaderThemeOverride? {
        ReaderThemeRules.makeOverride(
            variant: resolvedReaderThemeVariant,
            quickStylePresetRaw: readerThemeQuickStylePresetIDRaw,
            fontSizeOverride: readerThemeOverrideFontSize,
            lineHeightOverride: readerThemeOverrideLineHeight,
            contentWidthOverride: readerThemeOverrideContentWidth,
            fontFamilyOptionRaw: readerThemeOverrideFontFamilyRaw
        )
    }

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
                                ForEach(SummaryLanguageOption.supported) { option in
                                    Text(option.nativeName).tag(option.code)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .fixedSize()

                            Picker("", selection: $summaryDetailLevel) {
                                ForEach(AISummaryDetailLevel.allCases, id: \.self) { level in
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
                                    requestSummaryRun(for: entry, trigger: .manual)
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

    private func refreshSummaryForSelectedEntry(_ entryId: Int64?) async {
        guard let entryId else {
            hasAnyPersistedSummaryForCurrentEntry = false
            summaryText = ""
            summaryUpdatedAt = nil
            summaryDurationMs = nil
            summaryPlaceholderText = "No summary"
            applySummaryAgentDefaults()
            return
        }

        summaryDisplayEntryId = entryId
        pruneSummaryStreamingStates()

        if isSummaryRunning,
           let runningSlot = summaryRunningSlotKey,
           runningSlot.entryId == entryId {
            hasAnyPersistedSummaryForCurrentEntry = false
            let resolved = SummaryAutoPolicy.resolveControlSelection(
                selectedEntryId: entryId,
                runningSlot: SummaryRuntimeSlot(
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
            summaryPlaceholderText = summaryText.isEmpty ? "Generating..." : ""
            return
        }

        isSummaryLoading = true
        if summaryText.isEmpty {
            summaryPlaceholderText = "Loading..."
        }
        defer { isSummaryLoading = false }

        do {
            if let latest = try await appModel.loadLatestSummaryRecord(entryId: entryId) {
                hasAnyPersistedSummaryForCurrentEntry = true
                summaryFetchRetryEntryId = nil
                let normalizedLatestLanguage = SummaryLanguageOption.normalizeCode(latest.result.targetLanguage)
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
            summaryPlaceholderText = "No summary"
            return
        }

        let targetLanguage = SummaryLanguageOption.normalizeCode(summaryTargetLanguage)
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
            summaryPlaceholderText = summaryText.isEmpty ? "Generating..." : ""
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
                if SummaryAutoPolicy.shouldShowWaitingPlaceholder(
                    summaryTextIsEmpty: true,
                    hasPendingRequestForSelectedEntry: hasPendingSummaryRequest(for: entryId)
                ) {
                    summaryPlaceholderText = "Waiting for last generation to finish..."
                } else {
                    summaryPlaceholderText = "No summary"
                }
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
                summaryPlaceholderText = "No summary"
            }
        }
    }

    private func requestSummaryRun(for entry: Entry, trigger: SummaryRunTrigger) {
        guard let entryId = entry.id else { return }
        let targetLanguage = SummaryLanguageOption.normalizeCode(summaryTargetLanguage)
        if summaryTargetLanguage != targetLanguage {
            summaryTargetLanguage = targetLanguage
        }
        let detailLevel = summaryDetailLevel
        let owner = makeSummaryRunOwner(
            entryId: entryId,
            targetLanguage: targetLanguage,
            detailLevel: detailLevel
        )

        Task {
            let decision = await appModel.agentRunCoordinator.requestStart(owner: owner)
            await MainActor.run {
                switch decision {
                case .startNow:
                    summaryPendingRunTriggers.removeValue(forKey: owner)
                    startSummaryRun(
                        for: entry,
                        owner: owner,
                        targetLanguage: targetLanguage,
                        detailLevel: detailLevel
                    )
                case .queuedWaiting, .alreadyWaiting:
                    let existing = summaryPendingRunTriggers.mapValues(\.waitingTrigger)
                    let decision = SummaryWaitingPolicy.decide(
                        queuedOwner: owner,
                        queuedTrigger: trigger.waitingTrigger,
                        displayedEntryId: summaryDisplayEntryId,
                        existingWaiting: existing
                    )
                    if decision.shouldKeepCurrent {
                        summaryPendingRunTriggers[owner] = trigger
                    }
                    let ownersToCancel = decision.ownersToCancel
                    for ownerToCancel in ownersToCancel {
                        summaryPendingRunTriggers.removeValue(forKey: ownerToCancel)
                    }
                    cancelSummaryWaitingOwners(ownersToCancel)
                    if summaryDisplayEntryId == entryId &&
                        summaryText.isEmpty &&
                        hasPendingSummaryRequest(for: entryId) {
                        summaryPlaceholderText = "Waiting for last generation to finish..."
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
        detailLevel: AISummaryDetailLevel
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
        if summaryDisplayEntryId == entryId {
            summaryPlaceholderText = "Requesting..."
        }

        summaryRunStartTask = Task {
            let source = await resolveSummarySourceText(for: entry)
            if Task.isCancelled { return }

            let request = AISummaryRunRequest(
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
        let pendingOwners = Array(summaryPendingRunTriggers.keys)
        summaryPendingRunTriggers.removeAll()
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
                _ = await appModel.agentRunCoordinator.finish(owner: runningOwner, terminalPhase: .cancelled)
            }
            for owner in pendingOwners {
                _ = await appModel.agentRunCoordinator.finish(owner: owner, terminalPhase: .cancelled)
            }
        }
        if summaryDisplayEntryId != nil, summaryText.isEmpty {
            summaryPlaceholderText = "Cancelled."
        }
    }

    private func clearSummary(for entry: Entry) {
        abortSummary()
        summaryText = ""
        summaryUpdatedAt = nil
        summaryDurationMs = nil

        guard let entryId = entry.id else { return }
        let targetLanguage = SummaryLanguageOption.normalizeCode(summaryTargetLanguage)
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

    private func handleSummaryRunEvent(_ event: AISummaryRunEvent, entryId: Int64) {
        let runningSlotKey = summaryRunningSlotKey
        let runningOwner = summaryRunningOwner

        switch event {
        case .started(let taskId):
            summaryTaskId = taskId
            summaryActivePhase = .generating
            if let runningOwner {
                Task {
                    await appModel.agentRunCoordinator.updatePhase(owner: runningOwner, phase: .requesting)
                }
            }
            if let runningSlotKey,
               isShowingSummarySlot(runningSlotKey),
               summaryText.isEmpty {
                summaryPlaceholderText = "Generating..."
            }
        case .token(let token):
            summaryActivePhase = .generating
            if let runningOwner {
                Task {
                    await appModel.agentRunCoordinator.updatePhase(owner: runningOwner, phase: .generating)
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
            if SummaryAutoPolicy.shouldMarkCurrentEntryPersistedOnCompletion(
                completedEntryId: entryId,
                displayedEntryId: summaryDisplayEntryId
            ) {
                hasAnyPersistedSummaryForCurrentEntry = true
                Task {
                    await loadSummaryRecordForCurrentSlot(entryId: entryId)
                }
            }
            pruneSummaryStreamingStates()
            Task {
                let promoted: AgentRunOwner?
                if let runningOwner {
                    promoted = await appModel.agentRunCoordinator.finish(owner: runningOwner, terminalPhase: .completed)
                } else {
                    promoted = nil
                }
                await processPromotedSummaryOwner(promoted)
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
            let shouldShowFailureMessage = summaryDisplayEntryId == entryId && summaryText.isEmpty
            pruneSummaryStreamingStates()
            Task {
                let promoted: AgentRunOwner?
                if let runningOwner {
                    promoted = await appModel.agentRunCoordinator.finish(owner: runningOwner, terminalPhase: .failed)
                } else {
                    promoted = nil
                }
                await processPromotedSummaryOwner(promoted)
            }
            if shouldShowFailureMessage, isSummaryRunning == false {
                topErrorBannerText = AgentFailureMessageProjection.message(
                    for: failureReason,
                    taskKind: .summary
                )
                summaryPlaceholderText = "No summary"
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
            let shouldShowCancelledMessage = summaryDisplayEntryId == entryId && summaryText.isEmpty
            pruneSummaryStreamingStates()
            Task {
                let promoted: AgentRunOwner?
                if let runningOwner {
                    promoted = await appModel.agentRunCoordinator.finish(owner: runningOwner, terminalPhase: .cancelled)
                } else {
                    promoted = nil
                }
                await processPromotedSummaryOwner(promoted)
            }
            if shouldShowCancelledMessage, isSummaryRunning == false {
                summaryPlaceholderText = "Cancelled."
            } else {
                syncSummaryPlaceholderForCurrentState()
            }
        }
    }

    private func syncSummaryControlsWithAgentDefaultsIfNeeded() async {
        guard hasAnyPersistedSummaryForCurrentEntry == false else {
            return
        }
        applySummaryAgentDefaults()
        await loadSummaryRecordForCurrentSlot(entryId: selectedEntry?.id)
    }

    private func applySummaryControls(targetLanguage: String, detailLevel: AISummaryDetailLevel) {
        summaryTargetLanguage = SummaryLanguageOption.normalizeCode(targetLanguage)
        summaryDetailLevel = detailLevel
    }

    private func applySummaryAgentDefaults() {
        let defaults = appModel.loadSummaryAgentDefaults()
        applySummaryControls(
            targetLanguage: defaults.targetLanguage,
            detailLevel: defaults.detailLevel
        )
    }

    private func makeSummarySlotKey(entryId: Int64, targetLanguage: String, detailLevel: AISummaryDetailLevel) -> SummarySlotKey {
        SummarySlotKey(
            entryId: entryId,
            targetLanguage: SummaryLanguageOption.normalizeCode(targetLanguage),
            detailLevel: detailLevel
        )
    }

    private func makeSummaryRunOwner(entryId: Int64, targetLanguage: String, detailLevel: AISummaryDetailLevel) -> AgentRunOwner {
        AgentRunOwner(
            taskKind: .summary,
            entryId: entryId,
            slotKey: "\(SummaryLanguageOption.normalizeCode(targetLanguage))|\(detailLevel.rawValue)"
        )
    }

    private func decodeSummaryRunOwnerControls(_ owner: AgentRunOwner) -> (targetLanguage: String, detailLevel: AISummaryDetailLevel)? {
        let parts = owner.slotKey.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            return nil
        }
        let targetLanguage = SummaryLanguageOption.normalizeCode(String(parts[0]))
        let detailLevel = AISummaryDetailLevel(rawValue: String(parts[1])) ?? .medium
        return (targetLanguage: targetLanguage, detailLevel: detailLevel)
    }

    private func processPromotedSummaryOwner(_ initialOwner: AgentRunOwner?) async {
        var nextOwner = initialOwner
        while let owner = nextOwner {
            let trigger = await MainActor.run { () -> SummaryRunTrigger? in
                if let trigger = summaryPendingRunTriggers.removeValue(forKey: owner) {
                    return trigger
                }
                return nil
            }
            guard let trigger else {
                appModel.reportDebugIssue(
                    title: "Summary Queue Trigger Missing",
                    detail: "Promoted summary owner has no pending trigger. owner=\(owner)",
                    category: .task
                )
                nextOwner = await appModel.agentRunCoordinator.finish(owner: owner, terminalPhase: .cancelled)
                continue
            }
            if trigger == .auto {
                let selectedEntryId = await MainActor.run { summaryDisplayEntryId }
                if selectedEntryId != owner.entryId {
                    nextOwner = await appModel.agentRunCoordinator.finish(owner: owner, terminalPhase: .cancelled)
                    continue
                }
                let hasPersisted = ((try? await appModel.loadLatestSummaryRecord(entryId: owner.entryId)) ?? nil) != nil
                if hasPersisted {
                    nextOwner = await appModel.agentRunCoordinator.finish(owner: owner, terminalPhase: .cancelled)
                    continue
                }
            }

            guard let controls = decodeSummaryRunOwnerControls(owner) else {
                nextOwner = await appModel.agentRunCoordinator.finish(owner: owner, terminalPhase: .failed)
                continue
            }

            let entryFromSelection = await MainActor.run { () -> Entry? in
                guard let selectedEntry else { return nil }
                return selectedEntry.id == owner.entryId ? selectedEntry : nil
            }
            let entry: Entry?
            if let entryFromSelection {
                entry = entryFromSelection
            } else {
                entry = await appModel.entryStore.loadEntry(id: owner.entryId)
            }
            guard let entry else {
                nextOwner = await appModel.agentRunCoordinator.finish(owner: owner, terminalPhase: .failed)
                continue
            }

            await MainActor.run {
                startSummaryRun(
                    for: entry,
                    owner: owner,
                    targetLanguage: controls.targetLanguage,
                    detailLevel: controls.detailLevel
                )
            }
            break
        }
    }

    private func abandonAutoSummaryWaiting(for previousEntryId: Int64, nextSelectedEntryId: Int64?) async {
        guard previousEntryId != nextSelectedEntryId else {
            return
        }
        let ownersToAbandon = await MainActor.run { () -> [AgentRunOwner] in
            summaryPendingRunTriggers.compactMap { owner, trigger in
                guard owner.taskKind == .summary,
                      owner.entryId == previousEntryId,
                      trigger == .auto else {
                    return nil
                }
                return owner
            }
        }

        for owner in ownersToAbandon {
            await appModel.agentRunCoordinator.abandonWaiting(owner: owner)
            _ = await MainActor.run {
                summaryPendingRunTriggers.removeValue(forKey: owner)
            }
        }
    }

    private func isShowingSummarySlot(_ slotKey: SummarySlotKey) -> Bool {
        guard summaryDisplayEntryId == slotKey.entryId else {
            return false
        }
        let currentLanguage = SummaryLanguageOption.normalizeCode(summaryTargetLanguage)
        return currentLanguage == slotKey.targetLanguage && summaryDetailLevel == slotKey.detailLevel
    }

    private func currentDisplayedSummarySlotKey() -> SummarySlotKey? {
        guard let entryId = summaryDisplayEntryId else {
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
        if isSummaryRunning, summaryRunningEntryId == summaryDisplayEntryId {
            activePhase = summaryActivePhase
        } else {
            activePhase = nil
        }
        let input = AgentDisplayProjectionInput(
            hasContent: summaryText.isEmpty == false,
            isLoading: isSummaryLoading,
            hasFetchFailure: summaryFetchRetryEntryId == summaryDisplayEntryId,
            hasPendingRequest: SummaryAutoPolicy.shouldShowWaitingPlaceholder(
                summaryTextIsEmpty: true,
                hasPendingRequestForSelectedEntry: hasPendingSummaryRequest(for: summaryDisplayEntryId)
            ),
            activePhase: activePhase
        )
        summaryPlaceholderText = AgentDisplayProjection.placeholderText(
            input: input,
            strings: AgentDisplayStrings(
                noContent: "No summary",
                loading: "Loading...",
                waiting: "Waiting for last generation to finish...",
                requesting: "Requesting...",
                generating: "Generating...",
                persisting: "Persisting...",
                fetchFailedRetry: "No summary"
            )
        )
    }

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

        guard let entry = selectedEntry, entry.id != nil else {
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
                displayedEntryId: summaryDisplayEntryId,
                candidateEntryId: entryId
            )
        }

        await AgentEntryActivationCoordinator.run(
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
                    requestSummaryRun(for: entry, trigger: .auto)
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

    private func hasPendingSummaryRequest(for entryId: Int64?) -> Bool {
        guard let entryId else { return false }
        return summaryPendingRunTriggers.keys.contains { $0.entryId == entryId }
    }

    private func cancelSummaryWaitingOwners(_ owners: [AgentRunOwner]) {
        guard owners.isEmpty == false else { return }
        Task {
            for owner in owners {
                await appModel.agentRunCoordinator.abandonWaiting(owner: owner)
            }
        }
    }

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
