//
//  ReaderDetailView.swift
//  Mercury
//
//  Created by Neo on 2026/2/4.
//

import AppKit
import SwiftUI

struct ReaderDetailView: View {
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
    }

    @ViewBuilder
    private func readingContent(for entry: Entry, url: URL, urlString: String) -> some View {
        let needsReader = (ReadingMode(rawValue: readingModeRaw) ?? .reader) != .web
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
        .task(id: readerTaskKey(entryId: entry.id, needsReader: needsReader)) {
            guard needsReader else { return }
            await loadReader(entry: entry)
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
                Text("Theme")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Theme", selection: $readerThemePresetIDRaw) {
                    Text("Classic").tag(ReaderThemePresetID.classic.rawValue)
                    Text("Paper").tag(ReaderThemePresetID.paper.rawValue)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Appearance")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Appearance", selection: $readerThemeModeRaw) {
                    Text("Auto").tag(ReaderThemeMode.auto.rawValue)
                    Text("Light").tag(ReaderThemeMode.forceLight.rawValue)
                    Text("Dark").tag(ReaderThemeMode.forceDark.rawValue)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Quick Style")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Quick Style", selection: $readerThemeQuickStylePresetIDRaw) {
                    Text("Use Preset").tag(ReaderThemeQuickStylePresetID.none.rawValue)
                    Text("Warm Paper").tag(ReaderThemeQuickStylePresetID.warm.rawValue)
                    Text("Cool Blue").tag(ReaderThemeQuickStylePresetID.cool.rawValue)
                    Text("Slate Graphite").tag(ReaderThemeQuickStylePresetID.slate.rawValue)
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Font Family")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Font Family", selection: $readerThemeOverrideFontFamilyRaw) {
                    Text("Use Preset").tag(ReaderThemeFontFamilyOptionID.usePreset.rawValue)
                    Text("System Sans").tag(ReaderThemeFontFamilyOptionID.systemSans.rawValue)
                    Text("Reading Serif").tag(ReaderThemeFontFamilyOptionID.readingSerif.rawValue)
                    Text("Rounded Sans").tag(ReaderThemeFontFamilyOptionID.roundedSans.rawValue)
                    Text("Monospace").tag(ReaderThemeFontFamilyOptionID.mono.rawValue)
                }
                .labelsHidden()
                .pickerStyle(.menu)
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
            .disabled(
                readerThemeOverrideFontSize <= 0
                && readerThemeOverrideLineHeight <= 0
                && readerThemeOverrideContentWidth <= 0
                && readerThemeQuickStylePresetIDRaw == ReaderThemeQuickStylePresetID.none.rawValue
                && readerThemeOverrideFontFamilyRaw == ReaderThemeFontFamilyOptionID.usePreset.rawValue
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
        readerThemeOverrideFontSize > 0 ? readerThemeOverrideFontSize : 17
    }

    private func decreaseFontSize() {
        readerThemeOverrideFontSize = max(13, currentFontSize - 1)
    }

    private func increaseFontSize() {
        readerThemeOverrideFontSize = min(28, currentFontSize + 1)
    }

    private func resetPreviewOverrides() {
        readerThemeOverrideFontSize = 0
        readerThemeOverrideLineHeight = 0
        readerThemeOverrideContentWidth = 0
        readerThemeOverrideFontFamilyRaw = ReaderThemeFontFamilyOptionID.usePreset.rawValue
        readerThemeQuickStylePresetIDRaw = ReaderThemeQuickStylePresetID.none.rawValue
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
}
