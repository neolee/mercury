//
//  ReaderDetailView.swift
//  Mercury
//
//  Created by Neo on 2026/2/4.
//

import AppKit
import SwiftUI

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
    @State private var summaryTargetLanguage = "en"
    @State private var summaryDetailLevel: AISummaryDetailLevel = .medium
    @State private var summaryAutoEnabled = false
    @State private var summaryText = ""
    @State private var summaryUpdatedAt: Date?
    @State private var summaryDurationMs: Int?
    @State private var isSummaryLoading = false
    @State private var isSummaryRunning = false
    @State private var hasPersistedSummaryForCurrentEntry = false
    @State private var summaryRunStartTask: Task<Void, Never>?
    @State private var summaryTaskId: UUID?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let entry = selectedEntry, let urlString = entry.url, let url = URL(string: urlString) {
                    readingContent(for: entry, url: url, urlString: urlString)
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
        .onReceive(NotificationCenter.default.publisher(for: .summaryAgentDefaultsDidChange)) { _ in
            Task {
                await syncSummaryControlsWithAgentDefaultsIfNeeded()
            }
        }
    }

    @ViewBuilder
    private func readingContent(for entry: Entry, url: URL, urlString: String) -> some View {
        let needsReader = (ReadingMode(rawValue: readingModeRaw) ?? .reader) != .web
        VStack(spacing: 0) {
            Group {
                switch ReadingMode(rawValue: readingModeRaw) ?? .reader {
                case .reader:
                    readerContent(baseURL: url)
                case .web:
                    webContent(url: url, urlString: urlString)
                case .dual:
                    HStack(spacing: 0) {
                        readerContent(baseURL: url)
                        Divider()
                        webContent(url: url, urlString: urlString)
                    }
                }
            }
            summaryPanel(entry: entry)
        }
        .task(id: readerTaskKey(entryId: entry.id, needsReader: needsReader)) {
            guard needsReader else { return }
            await loadReader(entry: entry)
        }
        .task(id: entry.id) {
            await refreshSummaryForSelectedEntry(entry.id)
        }
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
        Group {
            if isLoadingReader {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let readerHTML {
                WebView(html: readerHTML, baseURL: baseURL)
            } else {
                readerPlaceholder
            }
        }
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
        readerHTML = nil
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
            Divider()

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
                        TextField("Target language", text: $summaryTargetLanguage)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 160)

                        Picker("", selection: $summaryDetailLevel) {
                            ForEach(AISummaryDetailLevel.allCases, id: \.self) { level in
                                Text(level.rawValue.capitalized).tag(level)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 260)

                        Toggle("Auto-summary", isOn: $summaryAutoEnabled)
                            .toggleStyle(.checkbox)

                        Spacer(minLength: 0)

                        Button("Summary") {
                            startSummaryRun(for: entry)
                        }
                        .disabled(isSummaryRunning || entry.id == nil)

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
                    .controlSize(.small)

                    summaryMetaRow

                    ScrollView {
                        Text(summaryText.isEmpty ? "No summary yet." : summaryText)
                            .foregroundStyle(summaryText.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(10)
                    }
                    .frame(minHeight: 120, maxHeight: 220)
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
            hasPersistedSummaryForCurrentEntry = false
            summaryText = ""
            summaryUpdatedAt = nil
            summaryDurationMs = nil
            applySummaryAgentDefaults()
            return
        }

        isSummaryLoading = true
        defer { isSummaryLoading = false }

        do {
            if let latest = try await appModel.loadLatestSummaryRecord(entryId: entryId) {
                hasPersistedSummaryForCurrentEntry = true
                if summaryTargetLanguage != latest.result.targetLanguage {
                    summaryTargetLanguage = latest.result.targetLanguage
                }
                if summaryDetailLevel != latest.result.detailLevel {
                    summaryDetailLevel = latest.result.detailLevel
                }
                summaryText = latest.result.text
                summaryUpdatedAt = latest.result.updatedAt
                summaryDurationMs = latest.run.durationMs
                return
            }
        } catch {
            appModel.reportDebugIssue(
                title: "Load Summary Failed",
                detail: error.localizedDescription,
                category: .task
            )
        }

        hasPersistedSummaryForCurrentEntry = false
        applySummaryAgentDefaults()
        await loadSummaryRecordForCurrentSlot(entryId: entryId)
    }

    private func loadSummaryRecordForCurrentSlot(entryId: Int64?) async {
        guard let entryId else {
            summaryText = ""
            summaryUpdatedAt = nil
            summaryDurationMs = nil
            return
        }

        let targetLanguage = summaryTargetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard targetLanguage.isEmpty == false else {
            summaryText = ""
            summaryUpdatedAt = nil
            summaryDurationMs = nil
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
            hasPersistedSummaryForCurrentEntry = (record != nil)
        } catch {
            appModel.reportDebugIssue(
                title: "Load Summary Failed",
                detail: error.localizedDescription,
                category: .task
            )
        }
    }

    private func startSummaryRun(for entry: Entry) {
        guard let entryId = entry.id else { return }
        let targetLanguage = summaryTargetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard targetLanguage.isEmpty == false else {
            return
        }

        abortSummary()
        isSummaryRunning = true
        summaryText = ""
        summaryUpdatedAt = nil
        summaryDurationMs = nil
        hasPersistedSummaryForCurrentEntry = false

        let title = (entry.title ?? "Untitled").trimmingCharacters(in: .whitespacesAndNewlines)
        let source = (entry.summary ?? title).trimmingCharacters(in: .whitespacesAndNewlines)
        let request = AISummaryRunRequest(
            entryId: entryId,
            sourceText: source,
            targetLanguage: targetLanguage,
            detailLevel: summaryDetailLevel
        )

        summaryRunStartTask = Task {
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

    private func abortSummary() {
        summaryRunStartTask?.cancel()
        summaryRunStartTask = nil
        if let summaryTaskId {
            Task {
                await appModel.cancelTask(summaryTaskId)
            }
            self.summaryTaskId = nil
        }
        isSummaryRunning = false
    }

    private func clearSummary(for entry: Entry) {
        abortSummary()
        summaryText = ""
        summaryUpdatedAt = nil
        summaryDurationMs = nil
        hasPersistedSummaryForCurrentEntry = false

        guard let entryId = entry.id else { return }
        let targetLanguage = summaryTargetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard targetLanguage.isEmpty == false else { return }

        Task {
            do {
                _ = try await appModel.clearSummaryRecord(
                    entryId: entryId,
                    targetLanguage: targetLanguage,
                    detailLevel: summaryDetailLevel
                )
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
        switch event {
        case .started(let taskId):
            summaryTaskId = taskId
        case .token(let token):
            summaryText += token
        case .completed:
            isSummaryRunning = false
            summaryTaskId = nil
            summaryRunStartTask = nil
            Task {
                await loadSummaryRecordForCurrentSlot(entryId: entryId)
            }
        case .failed:
            isSummaryRunning = false
            summaryTaskId = nil
            summaryRunStartTask = nil
        case .cancelled:
            isSummaryRunning = false
            summaryTaskId = nil
            summaryRunStartTask = nil
        }
    }

    private func syncSummaryControlsWithAgentDefaultsIfNeeded() async {
        guard hasPersistedSummaryForCurrentEntry == false else {
            return
        }
        applySummaryAgentDefaults()
        await loadSummaryRecordForCurrentSlot(entryId: selectedEntry?.id)
    }

    private func applySummaryAgentDefaults() {
        let defaults = appModel.loadSummaryAgentDefaults()
        summaryTargetLanguage = defaults.targetLanguage
        summaryDetailLevel = defaults.detailLevel
    }

    private static let summaryDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static let summaryPanelExpandedKey = "ReaderSummaryPanelExpanded"

    private static func loadSummaryPanelExpandedState() -> Bool {
        UserDefaults.standard.object(forKey: summaryPanelExpandedKey) as? Bool ?? false
    }
}
