//
//  ReaderDetailView.swift
//  Mercury
//
//  Created by Neo on 2026/2/4.
//

import SwiftUI
import AppKit

struct ReaderDetailView: View {
    @EnvironmentObject var appModel: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openSettings) private var openSettings
    @Environment(\.localizationBundle) var bundle

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
    @State private var displayedEntryId: Int64?
    @State private var topBannerMessage: ReaderBannerMessage?

    // Translation toolbar state lifted from ReaderTranslationView so that all toolbar buttons
    // can be declared in one place in the correct order.
    @State private var translationMode: TranslationMode = .original
    @State private var hasPersistedTranslationForCurrentSlot = false
    @State private var hasResumableTranslationCheckpointForCurrentSlot = false
    @State private var translationToggleRequested = false
    @State private var translationClearRequested = false
    @State private var translationActionURL: URL?
    @State private var isTranslationRunningForCurrentEntry = false

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
            .onChange(of: selectedEntry?.id) { _, newEntryId in
                displayedEntryId = newEntryId
                topBannerMessage = nil
                sourceReaderHTML = nil
                setReaderHTML(nil)
                isTranslationRunningForCurrentEntry = false
                hasResumableTranslationCheckpointForCurrentSlot = false
            }
            .onChange(of: effectiveReaderTheme) { _, _ in
                sourceReaderHTML = nil
                setReaderHTML(nil)
            }
    }

    private var bodyWithAlert: some View {
        AnyView(bodyWithLifecycle)
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

        VStack(spacing: 0) {
            if let topBannerMessage,
               topBannerMessage.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                topErrorBanner(topBannerMessage)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 8)
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
    }

    private func topErrorBanner(_ banner: ReaderBannerMessage) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(banner.text)
                .font(.subheadline)
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            if let secondaryAction = banner.secondaryAction {
                Button(secondaryAction.label, action: secondaryAction.handler)
                    .buttonStyle(.link)
                    .font(.subheadline)
            }
            if let action = banner.action {
                Button(action.label, action: action.handler)
                    .buttonStyle(.link)
                    .font(.subheadline)
            }
            Button {
                topBannerMessage = nil
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

    @ToolbarContentBuilder
    private var entryToolbar: some ToolbarContent {
        if selectedEntry != nil {
            ToolbarItem(placement: .primaryAction) {
                modeToolbar(readingMode: Binding(
                    get: { ReadingMode(rawValue: readingModeRaw) ?? .reader },
                    set: { readingModeRaw = $0.rawValue }
                ))
            }

            if TranslationModePolicy.isToolbarButtonVisible(
                readingMode: ReadingMode(rawValue: readingModeRaw) ?? .reader
            ) {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        translationToggleRequested = true
                    } label: {
                        Image(systemName: translationToggleButtonIconName)
                    }
                    .accessibilityLabel(Text(translationToggleButtonText))
                    .help(translationToggleButtonText)

                    Button {
                        translationClearRequested = true
                    } label: {
                        Image(systemName: "eraser")
                    }
                    .disabled(hasPersistedTranslationForCurrentSlot == false)
                    .accessibilityLabel(Text("Clear Translation", bundle: bundle))
                    .help(String(localized: "Clear saved translation for current language", bundle: bundle))
                }
            }

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
                .help(String(localized: "Open debug issues", bundle: bundle))
            }
        }
    }

    private func modeToolbar(readingMode: Binding<ReadingMode>) -> some View {
        Picker("", selection: readingMode) {
            ForEach(ReadingMode.allCases) { mode in
                Text(mode.labelKey, bundle: bundle)
                    .tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 220)
        .labelsHidden()
    }

    private var themePreviewMenu: some View {
        Button {
            isThemePanelPresented.toggle()
        } label: {
            Image(systemName: "paintpalette")
        }
        .help(isThemePanelPresented ? "Close theme panel" : "Open theme panel")
    }

    private func shareToolbarMenu(url: URL, urlString: String) -> some View {
        Menu {
            Button(action: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(urlString, forType: .string)
            }) { Text("Copy Link", bundle: bundle) }
            Button(action: {
                NSWorkspace.shared.open(url)
            }) { Text("Open in Default Browser", bundle: bundle) }
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .menuIndicator(.hidden)
        .help(String(localized: "Share", bundle: bundle))
    }

    private var themePanelView: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Theme", bundle: bundle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ReaderThemePresetPicker(label: ReaderThemeControlText.themeSection, selection: $readerThemePresetIDRaw)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Appearance", bundle: bundle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ReaderThemeModePicker(label: ReaderThemeControlText.appearance, selection: $readerThemeModeRaw)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Quick Style", bundle: bundle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ReaderThemeQuickStylePicker(label: ReaderThemeControlText.quickStyle, selection: $readerThemeQuickStylePresetIDRaw)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Font Family", bundle: bundle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ReaderThemeFontFamilyPicker(label: ReaderThemeControlText.fontFamily, selection: $readerThemeOverrideFontFamilyRaw)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Font Size", bundle: bundle)
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

            Button(action: { resetPreviewOverrides() }) {
                Text("Reset", bundle: bundle)
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

    private func readerContent(baseURL: URL, webViewIdentity: String) -> some View {
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
                ProgressView(String(localized: "Loading…", bundle: bundle))
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

    private var translationToggleButtonIconName: String {
        if isTranslationRunningForCurrentEntry {
            return "xmark.circle"
        }
        return TranslationModePolicy.toolbarButtonIconName(for: translationMode)
    }

    private var translationToggleButtonText: String {
        if isTranslationRunningForCurrentEntry {
            return String(localized: "Cancel Translation", bundle: bundle)
        }
        if translationMode == .original,
           hasResumableTranslationCheckpointForCurrentSlot {
            return String(localized: "Resume Translation", bundle: bundle)
        }
        if translationMode == .original {
            return String(localized: "Switch to Translation", bundle: bundle)
        }
        return String(localized: "Return to Original", bundle: bundle)
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
        } else {
            sourceReaderHTML = nil
            setReaderHTML(nil)
            readerError = result.errorMessage ?? "Failed to build reader content."
        }
    }

    private func readerTaskKey(entryId: Int64?, needsReader: Bool) -> String {
        "\(entryId ?? 0)-\(needsReader)-\(readingModeRaw)-\(effectiveReaderTheme.cacheThemeID)"
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


}
