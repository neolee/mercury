//
//  ReaderDetailView.swift
//  Mercury
//
//  Created by Neo on 2026/2/4.
//

import SwiftUI
import AppKit

struct ReaderDetailView: View {
    // MARK: - Environment

    @EnvironmentObject var appModel: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openSettings) private var openSettings
    @Environment(\.localizationBundle) var bundle

    // MARK: - Inputs

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
    let onTagsChanged: () async -> Void
    let onOpenDebugIssues: (() -> Void)?
    let onSelectEntry: ((Int64) -> Void)?

    // MARK: - Reader State

    @State private var readerHTML: String?
    @State private var sourceReaderHTML: String?
    @State private var isLoadingReader = false
    @State private var readerError: String?
    @State var activeToolbarPanel: ReaderToolbarPanelKind?
    @State private var displayedEntryId: Int64?
    @State private var topBannerMessage: ReaderBannerMessage?

    // MARK: - Translation Toolbar State

    // Translation toolbar state lifted from ReaderTranslationView so that all toolbar buttons
    // can be declared in one place in the correct order.
    @State var translationMode: TranslationMode = .original
    @State var hasPersistedTranslationForCurrentSlot = false
    @State var hasResumableTranslationCheckpointForCurrentSlot = false
    @State var translationToggleRequested = false
    @State var translationClearRequested = false
    @State private var translationActionURL: URL?
    @State var isTranslationRunningForCurrentEntry = false

    // MARK: - Tagging UI State

    @State private var entryTags: [Tag] = []
    @State private var relatedEntries: [EntryListItem] = []
    @State var shareDigestEntry: Entry?
    @State var exportDigestEntry: Entry?
    @AppStorage("Reader.RelatedContent.IsExpanded") private var isRelatedContentExpanded = true

    // MARK: - Note State

    @StateObject var noteController = DigestNoteController()

    // MARK: - Body

    var body: some View {
        bodyWithLifecycle
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
            .sheet(item: $shareDigestEntry) { entry in
                ReaderShareDigestSheetView(entry: entry) {
                    await loadNoteState(for: selectedEntry?.id)
                }
                .environmentObject(appModel)
            }
            .sheet(item: $exportDigestEntry) { entry in
                ReaderExportDigestSheetView(
                    entry: entry,
                    loadReaderHTML: loadReaderHTML,
                    effectiveReaderTheme: effectiveReaderTheme
                ) {
                    await loadNoteState(for: selectedEntry?.id)
                }
                .environmentObject(appModel)
            }
            .onExitCommand {
                guard activeToolbarPanel != nil else { return }
                closeActiveToolbarPanel()
            }
            .onChange(of: selectedEntry?.id) { oldEntryId, newEntryId in
                displayedEntryId = newEntryId
                topBannerMessage = nil
                sourceReaderHTML = nil
                setReaderHTML(nil)
                isTranslationRunningForCurrentEntry = false
                hasResumableTranslationCheckpointForCurrentSlot = false
                relatedEntries = []
                handleSelectedEntryChange(from: oldEntryId, to: newEntryId)
            }
            .onChange(of: effectiveReaderTheme) { _, _ in
                sourceReaderHTML = nil
                setReaderHTML(nil)
            }
            .onChange(of: appModel.tagMutationVersion) { _, _ in
                Task { await loadEntryTags() }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
                handleNoteAppBackgrounding()
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("NSWindowDidResignKeyNotification"))) { _ in
                handleNoteAppBackgrounding()
            }
    }

    // MARK: - Entry Shell

    private var mainContent: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let entry = selectedEntry {
                    readingContent(for: entry)
                } else {
                    emptyState
                }
            }

            ReaderToolbarPanelHostView(
                activePanel: activeToolbarPanel,
                onClose: { closeActiveToolbarPanel() }
            ) {
                if activeToolbarPanel == .note {
                    ReaderNotePanelView(
                        text: noteDraftBinding,
                        statusText: notePanelStatusText
                    )
                }

                if activeToolbarPanel == .tags, let entry = selectedEntry {
                    ReaderTaggingPanelView(
                        entry: entry,
                        entryTags: $entryTags,
                        topBannerMessage: $topBannerMessage,
                        onTagsChanged: onTagsChanged
                    )
                }

                if activeToolbarPanel == .theme {
                    ReaderThemePanelView(
                        presetIDRaw: $readerThemePresetIDRaw,
                        modeRaw: $readerThemeModeRaw,
                        quickStylePresetIDRaw: $readerThemeQuickStylePresetIDRaw,
                        fontSizeOverride: $readerThemeOverrideFontSize,
                        lineHeightOverride: $readerThemeOverrideLineHeight,
                        contentWidthOverride: $readerThemeOverrideContentWidth,
                        fontFamilyRaw: $readerThemeOverrideFontFamilyRaw
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func readingContent(for entry: Entry) -> some View {
        let needsReader = (ReadingMode(rawValue: readingModeRaw) ?? .reader) != .web
        let parsedURL = parseEntryURL(entry)

        VStack(spacing: 0) {
            if let topBannerMessage,
               let bannerModel = AgentMessageHostAdapter.readerBannerModel(from: topBannerMessage) {
                AgentReaderBannerHostView(
                    message: bannerModel,
                    onPrimaryAction: topBannerMessage.action?.handler,
                    onSecondaryAction: topBannerMessage.secondaryAction?.handler,
                    onDismiss: { self.topBannerMessage = nil }
                )
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 8)
            }

            entryHeader

            if relatedEntries.isEmpty == false && isRelatedContentExpanded {
                ReaderRelatedEntriesView(
                    entries: relatedEntries
                ) { entryId in
                    onSelectEntry?(entryId)
                }
            }

            topPaneContent(parsedURL: parsedURL)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            ReaderTranslationView(
                entry: entry,
                displayedEntryId: $displayedEntryId,
                readerHTML: $readerHTML,
                sourceReaderHTML: $sourceReaderHTML,
                topBannerMessage: $topBannerMessage,
                readingModeRaw: readingModeRaw,
                translationMode: $translationMode,
                hasPersistedTranslationForCurrentSlot: $hasPersistedTranslationForCurrentSlot,
                hasResumableTranslationCheckpointForCurrentSlot: $hasResumableTranslationCheckpointForCurrentSlot,
                translationToggleRequested: $translationToggleRequested,
                translationClearRequested: $translationClearRequested,
                translationActionURL: $translationActionURL,
                isTranslationRunningForCurrentEntry: $isTranslationRunningForCurrentEntry
            )
            .frame(height: 0)

            ReaderSummaryView(
                entry: entry,
                displayedEntryId: $displayedEntryId,
                topBannerMessage: $topBannerMessage,
                loadReaderHTML: loadReaderHTML,
                effectiveReaderTheme: effectiveReaderTheme
            )
        }
        .task(id: readerTaskKey(entryId: entry.id, needsReader: needsReader)) {
            guard needsReader else { return }
            await loadReader(entry: entry, theme: effectiveReaderTheme)
        }
        .task(id: entry.id) {
            await loadEntryTags()
            await loadRelatedEntries(for: entry.id)
            await loadNoteState(for: entry.id)
        }
    }

    // MARK: - Empty States

    private var readerUnavailableContent: some View {
        VStack(spacing: 12) {
            Image(systemName: "link.badge.plus")
                .imageScale(.large)
                .foregroundStyle(.secondary)
            Text("No valid article URL", bundle: bundle)
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
            Text("Select an entry to read", bundle: bundle)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Pane Layout

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
            .help(String(localized: "Copy URL", bundle: bundle))
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

    @ViewBuilder
    private var entryHeader: some View {
        if hasEntryHeaderContent {
            HStack(alignment: .center, spacing: 8) {
                if entryTags.isEmpty == false {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(entryTags, id: \.id) { tag in
                                Text(tag.name)
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                            }
                        }
                        .padding(.vertical, 1)
                    }
                }

                Spacer(minLength: 0)

                if relatedEntries.isEmpty == false {
                    Button {
                        isRelatedContentExpanded.toggle()
                    } label: {
                        Image(systemName: "sparkles")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help(
                        isRelatedContentExpanded
                        ? String(localized: "Hide related content", bundle: bundle)
                        : String(localized: "Show related content", bundle: bundle)
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)
        }
    }

    private var hasEntryHeaderContent: Bool {
        entryTags.isEmpty == false || relatedEntries.isEmpty == false
    }

    // MARK: - Reader Rendering

    private func readerContent(baseURL: URL, webViewIdentity: String) -> some View {
        VStack(spacing: 0) {
            ZStack {
                Group {
                    if let readerHTML {
                        WebView(
                            html: readerHTML,
                            baseURL: baseURL,
                            onActionURL: { url in
                                handleReaderActionURL(url)
                            }
                        )
                            .id(webViewIdentity)
                    } else {
                        readerPlaceholder
                    }
                }

                if isLoadingReader {
                    ProgressView(String(localized: "Loading...", bundle: bundle))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Translation Toolbar Helpers

    private var readerWebViewIdentity: String {
        "\(selectedEntry?.id ?? 0)-\(effectiveReaderTheme.cacheThemeID)"
    }

    private func handleReaderActionURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "mercury-action" else {
            return false
        }
        translationActionURL = url
        return true
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

    private func loadEntryTags() async {
        guard let entryId = selectedEntry?.id else {
            entryTags = []
            return
        }
        entryTags = await appModel.entryStore.fetchTags(for: entryId)
    }

    private func loadRelatedEntries(for entryId: Int64?) async {
        guard let entryId else { relatedEntries = []; return }
        relatedEntries = await appModel.entryStore.fetchRelatedEntries(for: entryId)
    }

    // MARK: - Reader Loading

    var isCurrentEntryReaderPipelineRebuilding: Bool {
        appModel.isReaderPipelineRebuilding(entryId: selectedEntry?.id)
    }

    private func loadReader(entry: Entry, theme: EffectiveReaderTheme) async {
        isLoadingReader = true
        readerError = nil
        defer { isLoadingReader = false }

        let result = await loadReaderHTML(entry, theme)
        if Task.isCancelled { return }
        applyReaderBuildResult(result)
    }

    func rerunReaderPipeline(target: ReaderPipelineTarget) async {
        guard let entry = selectedEntry else {
            return
        }

        let previousReaderHTML = readerHTML
        let previousSourceReaderHTML = sourceReaderHTML
        let previousReaderError = readerError

        isLoadingReader = true
        defer { isLoadingReader = false }

        let result = await appModel.rerunReaderPipeline(
            for: entry,
            theme: effectiveReaderTheme,
            target: target
        )
        if Task.isCancelled { return }

        if result.html != nil || previousReaderHTML == nil {
            applyReaderBuildResult(result)
            return
        }

        sourceReaderHTML = previousSourceReaderHTML
        setReaderHTML(previousReaderHTML)
        readerError = previousReaderError
    }

    private func applyReaderBuildResult(_ result: ReaderBuildResult) {
        if let html = result.html {
            sourceReaderHTML = html
            setReaderHTML(html)
            readerError = nil
            return
        }

        sourceReaderHTML = nil
        setReaderHTML(nil)
        readerError = result.errorMessage ?? "Failed to build reader content."
    }

    private func readerTaskKey(entryId: Int64?, needsReader: Bool) -> String {
        "\(entryId ?? 0)-\(needsReader)-\(readingModeRaw)-\(effectiveReaderTheme.cacheThemeID)"
    }

    // MARK: - Theme Resolution

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

}
