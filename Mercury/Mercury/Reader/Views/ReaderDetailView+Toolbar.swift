//
//  ReaderDetailView+Toolbar.swift
//  Mercury
//
//  Created by Neo on 2026/2/4.
//

import SwiftUI
import AppKit

extension ReaderDetailView {

    // MARK: - Toolbar

    @ToolbarContentBuilder
    var entryToolbar: some ToolbarContent {
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
                        Label(translationToggleButtonText, systemImage: translationToggleButtonIconName)
                    }
                    .disabled(isTranslationToolbarToggleDisabled)
                    .labelStyle(.iconOnly)
                    .help(translationToggleButtonText)

                    Button {
                        translationClearRequested = true
                    } label: {
                        Label(String(localized: "Clear Translation", bundle: bundle), systemImage: "eraser")
                    }
                    .disabled(hasPersistedTranslationForCurrentSlot == false || isCurrentEntryReaderPipelineRebuilding)
                    .labelStyle(.iconOnly)
                    .help(String(localized: "Clear saved translation for current language", bundle: bundle))
                }
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    toggleToolbarPanel(.tags)
                } label: {
                    Label(String(localized: "Tags", bundle: bundle), systemImage: "tag")
                }
                .labelStyle(.iconOnly)
                .help(tagsPanelHelpText)

                Button {
                    toggleToolbarPanel(.note)
                } label: {
                    noteToolbarIcon
                }
                .labelStyle(.iconOnly)
                .help(notePanelHelpText)

                themePreviewMenu
                if let urlString = selectedEntry?.url,
                   let url = URL(string: urlString) {
                    shareToolbarMenu(url: url, urlString: urlString)
                }
            }
        }

        if let onOpenDebugIssues {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(action: onOpenDebugIssues) {
                        Text("Show Debug Issues", bundle: bundle)
                    }

                    Divider()

                    Button {
                        Task { await rerunReaderPipeline(target: .all) }
                    } label: {
                        Text("Re-run Pipeline: All", bundle: bundle)
                    }
                    .disabled(debugPipelineActionsDisabled)

                    Button {
                        Task { await rerunReaderPipeline(target: .readability) }
                    } label: {
                        Text("Re-run Pipeline: Readability", bundle: bundle)
                    }
                    .disabled(debugPipelineActionsDisabled)

                    Button {
                        Task { await rerunReaderPipeline(target: .markdown) }
                    } label: {
                        Text("Re-run Pipeline: Markdown", bundle: bundle)
                    }
                    .disabled(debugPipelineActionsDisabled)

                    Button {
                        Task { await rerunReaderPipeline(target: .readerHTML) }
                    } label: {
                        Text("Re-run Pipeline: Reader HTML", bundle: bundle)
                    }
                    .disabled(debugPipelineActionsDisabled)
                } label: {
                    Label(String(localized: "Debug", bundle: bundle), systemImage: "ladybug")
                }
                .labelStyle(.iconOnly)
                .menuIndicator(.hidden)
                .help(String(localized: "Debug", bundle: bundle))
            }
        }
    }

    func modeToolbar(readingMode: Binding<ReadingMode>) -> some View {
        Picker("", selection: readingMode) {
            ForEach(ReadingMode.allCases) { mode in
                Image(systemName: mode.iconSystemName)
                    .accessibilityLabel(Text(mode.labelKey, bundle: bundle))
                    .tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 124)
        .labelsHidden()
        .help(String(localized: "Reading Layout", bundle: bundle))
    }

    var themePreviewMenu: some View {
        Button {
            toggleToolbarPanel(.theme)
        } label: {
            Label(String(localized: "Theme", bundle: bundle), systemImage: "paintpalette")
        }
        .labelStyle(.iconOnly)
        .help(themePanelHelpText)
    }

    func shareToolbarMenu(url: URL, urlString: String) -> some View {
        Menu {
            Button(action: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(urlString, forType: .string)
            }) { Text("Copy Link", bundle: bundle) }
            Button(action: {
                NSWorkspace.shared.open(url)
            }) { Text("Open in Default Browser", bundle: bundle) }

            if let selectedEntry {
                Divider()

                Button(action: {
                    presentShareDigestSheet(for: selectedEntry)
                }) { Text("Share Digest...", bundle: bundle) }
                .disabled(canShareDigest(entry: selectedEntry) == false)

                Button(action: {
                    presentExportDigestSheet(for: selectedEntry)
                }) { Text("Export Digest...", bundle: bundle) }
                .disabled(canShareDigest(entry: selectedEntry) == false)
            }
        } label: {
            Label(String(localized: "Share", bundle: bundle), systemImage: "square.and.arrow.up")
        }
        .labelStyle(.iconOnly)
        .menuIndicator(.hidden)
        .help(String(localized: "Share", bundle: bundle))
    }

    func canShareDigest(entry: Entry) -> Bool {
        DigestComposition.canShareSingleEntry(entry: entry)
    }

    func presentShareDigestSheet(for entry: Entry) {
        Task {
            cancelScheduledNoteFlush()
            if let snapshot = currentNoteSnapshot() {
                await commitEntryNote(snapshot: snapshot, trigger: .shareOrExportConsumption)
            }
            await MainActor.run {
                shareDigestEntry = entry
            }
        }
    }

    func presentExportDigestSheet(for entry: Entry) {
        Task {
            cancelScheduledNoteFlush()
            if let snapshot = currentNoteSnapshot() {
                await commitEntryNote(snapshot: snapshot, trigger: .shareOrExportConsumption)
            }
            await MainActor.run {
                exportDigestEntry = entry
            }
        }
    }

    // MARK: - Translation Toolbar Helpers

    var notePanelHelpText: String {
        if activeToolbarPanel == .note {
            return String(localized: "Close note panel", bundle: bundle)
        }
        return String(localized: "Open note panel", bundle: bundle)
    }

    var noteToolbarHasBadge: Bool {
        guard noteController.entryId == selectedEntry?.id else { return false }
        return noteController.hasBadge
    }

    var noteToolbarIcon: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: "note.text")
            if noteToolbarHasBadge {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 7, height: 7)
                    .offset(x: 4, y: -2)
            }
        }
        .accessibilityLabel(Text("Note", bundle: bundle))
    }

    var tagsPanelHelpText: String {
        if activeToolbarPanel == .tags {
            return String(localized: "Close tags panel", bundle: bundle)
        }
        return String(localized: "Open tags panel", bundle: bundle)
    }

    var themePanelHelpText: String {
        if activeToolbarPanel == .theme {
            return String(localized: "Close theme panel", bundle: bundle)
        }
        return String(localized: "Open theme panel", bundle: bundle)
    }

    var translationToggleButtonIconName: String {
        if isTranslationRunningForCurrentEntry {
            return "xmark.circle"
        }
        return TranslationModePolicy.toolbarButtonIconName(for: translationMode)
    }

    var translationToggleButtonText: String {
        if isTranslationRunningForCurrentEntry {
            return String(localized: "Cancel Translation", bundle: bundle)
        }
        if translationMode == .original,
           hasResumableTranslationCheckpointForCurrentSlot {
            return AgentRuntimeProjection.actionLabel(for: .resumeTranslation, bundle: bundle)
        }
        if translationMode == .original {
            return String(localized: "Switch to Translation", bundle: bundle)
        }
        return String(localized: "Return to Original", bundle: bundle)
    }

    var isTranslationToolbarToggleDisabled: Bool {
        isCurrentEntryReaderPipelineRebuilding && isTranslationRunningForCurrentEntry == false
    }

    var debugPipelineActionsDisabled: Bool {
        selectedEntry?.id == nil || isCurrentEntryReaderPipelineRebuilding
    }

}
