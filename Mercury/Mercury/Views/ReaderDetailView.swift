//
//  ReaderDetailView.swift
//  Mercury
//
//  Created by Neo on 2026/2/4.
//

import SwiftUI

private enum SummaryRunTrigger {
    case manual
    case auto
}

private struct PendingSummaryRun {
    let entry: Entry
    let trigger: SummaryRunTrigger
}

private struct SummarySlotKey: Hashable {
    let entryId: Int64
    let targetLanguage: String
    let detailLevel: AISummaryDetailLevel
}

private struct SummaryStreamingState {
    var text: String
}

struct ReaderDetailView: View {
    @EnvironmentObject var appModel: AppModel

    let selectedEntry: Entry?
    @Binding var readingModeRaw: String
    @Binding var readerThemePresetIDRaw: String
    @Binding var readerThemeModeRaw: String
    @Binding var readerThemeOverrideFontSize: Double
    @Binding var readerThemeOverrideLineHeight: Double
    @Binding var readerThemeOverrideContentWidth: Double
    @Binding var readerThemeOverrideFontFamilyRaw: String
    @Binding var readerThemeQuickStylePresetIDRaw: String
    let readerThemeIdentity: String
    let loadReaderHTML: (Entry) async -> ReaderBuildResult
    let onOpenDebugIssues: (() -> Void)?

    @State private var readerHTML: String?
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
    @State private var hasAnyPersistedSummaryForCurrentEntry = false
    @State private var summaryShouldFollowTail = true
    @State private var summaryScrollViewportHeight: Double = 0
    @State private var summaryScrollBottomMaxY: Double = 0
    @State private var summaryIgnoreScrollStateUntil = Date.distantPast
    @State private var summaryRunStartTask: Task<Void, Never>?
    @State private var summaryTaskId: UUID?
    @State private var summaryRunningEntryId: Int64?
    @State private var summaryRunningSlotKey: SummarySlotKey?
    @State private var summaryStreamingStates: [SummarySlotKey: SummaryStreamingState] = [:]
    @State private var summaryDisplayEntryId: Int64?
    @State private var queuedSummaryRun: PendingSummaryRun?
    @State private var autoSummaryDebounceTask: Task<Void, Never>?
    @State private var showAutoSummaryEnableRiskAlert = false
    @State private var summaryPlaceholderText = "No summary yet."

    var body: some View {
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
        .navigationTitle(selectedEntry?.title ?? "Reader")
        .toolbar {
            entryToolbar
        }
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
            summaryDisplayEntryId = newEntryId
            if isSummaryRunning,
               let runningEntryId = summaryRunningEntryId,
               runningEntryId != newEntryId {
                summaryText = ""
                summaryUpdatedAt = nil
                summaryDurationMs = nil
                summaryPlaceholderText = "Waiting for last generation to finish..."
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .summaryAgentDefaultsDidChange)) { _ in
            Task {
                await syncSummaryControlsWithAgentDefaultsIfNeeded()
            }
        }
        .onChange(of: summaryText) { _, newText in
            summaryRenderedText = Self.renderMarkdownSummaryText(newText)
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
            await loadReader(entry: entry)
        }
        .task(id: entry.id) {
            await refreshSummaryForSelectedEntry(entry.id)
            scheduleAutoSummaryForSelectedEntry()
        }
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

            ToolbarItem(placement: .primaryAction) {
                themePreviewMenu
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

    private var themePreviewMenu: some View {
        Button {
            isThemePanelPresented = true
        } label: {
            Image(systemName: "paintpalette")
        }
        .help("Reader theme preview")
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
            readerContent(baseURL: baseURL)
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

    private func readerContent(baseURL: URL) -> some View {
        ZStack {
            Group {
                if let readerHTML {
                    WebView(html: readerHTML, baseURL: baseURL)
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

    private var readerPlaceholder: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Reader mode")
                    .font(.title2)
                Text(readerError ?? "Clean content is not available yet.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func loadReader(entry: Entry) async {
        isLoadingReader = true
        readerError = nil
        defer { isLoadingReader = false }

        let result = await loadReaderHTML(entry)
        if Task.isCancelled { return }

        if let html = result.html {
            readerHTML = html
            readerError = nil
        } else {
            readerHTML = nil
            readerError = result.errorMessage ?? "Failed to build reader content."
        }
    }

    private func readerTaskKey(entryId: Int64?, needsReader: Bool) -> String {
        "\(entryId ?? 0)-\(needsReader)-\(readingModeRaw)-\(readerThemeIdentity)"
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
            summaryPlaceholderText = "No summary yet."
            applySummaryAgentDefaults()
            return
        }

        summaryDisplayEntryId = entryId

        if isSummaryRunning,
           let runningSlot = summaryRunningSlotKey,
           runningSlot.entryId == entryId {
            hasAnyPersistedSummaryForCurrentEntry = false
            applySummaryControls(
                targetLanguage: runningSlot.targetLanguage,
                detailLevel: runningSlot.detailLevel
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
                let normalizedLatestLanguage = SummaryLanguageOption.normalizeCode(latest.result.targetLanguage)
                applySummaryControls(
                    targetLanguage: normalizedLatestLanguage,
                    detailLevel: latest.result.detailLevel
                )
                summaryText = latest.result.text
                summaryUpdatedAt = latest.result.updatedAt
                summaryDurationMs = latest.run.durationMs
                summaryPlaceholderText = latest.result.text.isEmpty ? "No summary yet." : ""
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
            summaryPlaceholderText = "No summary yet."
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
            summaryText = record?.result.text ?? ""
            summaryUpdatedAt = record?.result.updatedAt
            summaryDurationMs = record?.run.durationMs
            if record != nil {
                summaryStreamingStates[currentSlotKey] = nil
            }
            if summaryText.isEmpty {
                if isSummaryRunning,
                   let runningEntryId = summaryRunningEntryId,
                   runningEntryId != entryId {
                    summaryPlaceholderText = "Waiting for last generation to finish..."
                } else {
                    summaryPlaceholderText = "No summary yet."
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
                summaryPlaceholderText = "Failed to load summary."
            }
        }
    }

    private func requestSummaryRun(for entry: Entry, trigger: SummaryRunTrigger) {
        if isSummaryRunning {
            switch trigger {
            case .manual:
                queuedSummaryRun = PendingSummaryRun(entry: entry, trigger: .manual)
            case .auto:
                if queuedSummaryRun?.trigger != .manual {
                    queuedSummaryRun = PendingSummaryRun(entry: entry, trigger: .auto)
                }
            }
            return
        }
        startSummaryRun(for: entry)
    }

    private func startSummaryRun(for entry: Entry) {
        guard let entryId = entry.id else { return }
        let targetLanguage = SummaryLanguageOption.normalizeCode(summaryTargetLanguage)
        if summaryTargetLanguage != targetLanguage {
            summaryTargetLanguage = targetLanguage
        }
        let slotKey = makeSummarySlotKey(
            entryId: entryId,
            targetLanguage: targetLanguage,
            detailLevel: summaryDetailLevel
        )

        isSummaryRunning = true
        summaryRunningEntryId = entryId
        summaryRunningSlotKey = slotKey
        summaryStreamingStates[slotKey] = SummaryStreamingState(text: "")
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
                detailLevel: summaryDetailLevel
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

        _ = await loadReaderHTML(entry)
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
        queuedSummaryRun = nil
        summaryRunStartTask?.cancel()
        summaryRunStartTask = nil
        if let summaryTaskId {
            Task {
                await appModel.cancelTask(summaryTaskId)
            }
            self.summaryTaskId = nil
        }
        isSummaryRunning = false
        summaryRunningEntryId = nil
        summaryRunningSlotKey = nil
        if summaryDisplayEntryId == selectedEntry?.id, summaryText.isEmpty {
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

        switch event {
        case .started(let taskId):
            summaryTaskId = taskId
            if let runningSlotKey,
               isShowingSummarySlot(runningSlotKey),
               summaryText.isEmpty {
                summaryPlaceholderText = "Generating..."
            }
        case .token(let token):
            if let runningSlotKey {
                var state = summaryStreamingStates[runningSlotKey] ?? SummaryStreamingState(text: "")
                state.text += token
                summaryStreamingStates[runningSlotKey] = state
                if isShowingSummarySlot(runningSlotKey) {
                    summaryText = state.text
                }
                if summaryText.isEmpty == false {
                    summaryPlaceholderText = ""
                }
            }
        case .completed:
            isSummaryRunning = false
            summaryTaskId = nil
            summaryRunStartTask = nil
            summaryRunningEntryId = nil
            summaryRunningSlotKey = nil
            hasAnyPersistedSummaryForCurrentEntry = true
            if summaryDisplayEntryId == entryId {
                Task {
                    await loadSummaryRecordForCurrentSlot(entryId: entryId)
                }
            }
            runQueuedSummaryIfNeeded()
        case .failed:
            isSummaryRunning = false
            summaryTaskId = nil
            summaryRunStartTask = nil
            summaryRunningEntryId = nil
            summaryRunningSlotKey = nil
            if summaryDisplayEntryId == entryId, summaryText.isEmpty {
                summaryPlaceholderText = "Failed. Check Debug Issues."
            }
            if queuedSummaryRun?.trigger == .auto,
               queuedSummaryRun?.entry.id == entryId {
                queuedSummaryRun = nil
            }
            runQueuedSummaryIfNeeded()
        case .cancelled:
            isSummaryRunning = false
            summaryTaskId = nil
            summaryRunStartTask = nil
            summaryRunningEntryId = nil
            summaryRunningSlotKey = nil
            if summaryDisplayEntryId == entryId, summaryText.isEmpty {
                summaryPlaceholderText = "Cancelled."
            }
            runQueuedSummaryIfNeeded()
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

    private func isShowingSummarySlot(_ slotKey: SummarySlotKey) -> Bool {
        guard summaryDisplayEntryId == slotKey.entryId else {
            return false
        }
        let currentLanguage = SummaryLanguageOption.normalizeCode(summaryTargetLanguage)
        return currentLanguage == slotKey.targetLanguage && summaryDetailLevel == slotKey.detailLevel
    }

    private func handleAutoSummaryToggleChange(_ enabled: Bool) {
        if enabled == false {
            summaryAutoEnabled = false
            autoSummaryDebounceTask?.cancel()
            autoSummaryDebounceTask = nil
            if queuedSummaryRun?.trigger == .auto {
                queuedSummaryRun = nil
            }
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
        guard isSummaryRunning == false else {
            if let selectedEntry {
                queuedSummaryRun = PendingSummaryRun(entry: selectedEntry, trigger: .auto)
                if summaryText.isEmpty,
                   let runningEntryId = summaryRunningEntryId,
                   runningEntryId != selectedEntry.id {
                    summaryPlaceholderText = "Waiting for last generation to finish..."
                }
            }
            return
        }
        guard hasAnyPersistedSummaryForCurrentEntry == false else {
            return
        }
        guard let entry = selectedEntry, entry.id != nil else {
            return
        }

        autoSummaryDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard Task.isCancelled == false else { return }
            await MainActor.run {
                guard summaryAutoEnabled else { return }
                guard isSummaryRunning == false else {
                    queuedSummaryRun = PendingSummaryRun(entry: entry, trigger: .auto)
                    return
                }
                guard selectedEntry?.id == entry.id else { return }
                guard hasAnyPersistedSummaryForCurrentEntry == false else { return }
                requestSummaryRun(for: entry, trigger: .auto)
            }
        }
    }

    private func runQueuedSummaryIfNeeded() {
        guard isSummaryRunning == false else {
            return
        }
        guard let queued = queuedSummaryRun else {
            return
        }

        queuedSummaryRun = nil
        switch queued.trigger {
        case .manual:
            requestSummaryRun(for: queued.entry, trigger: .manual)
        case .auto:
            if summaryAutoEnabled == false {
                return
            }
            guard selectedEntry?.id == queued.entry.id else {
                return
            }
            scheduleAutoSummaryForSelectedEntry()
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
