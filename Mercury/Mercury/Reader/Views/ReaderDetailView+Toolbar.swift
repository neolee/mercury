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
                    .labelStyle(.iconOnly)
                    .help(translationToggleButtonText)

                    Button {
                        translationClearRequested = true
                    } label: {
                        Label(String(localized: "Clear Translation", bundle: bundle), systemImage: "eraser")
                    }
                    .disabled(hasPersistedTranslationForCurrentSlot == false)
                    .labelStyle(.iconOnly)
                    .help(String(localized: "Clear saved translation for current language", bundle: bundle))
                }
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    isTagPanelPresented.toggle()
                } label: {
                    Label(String(localized: "Tags", bundle: bundle), systemImage: "tag")
                }
                .labelStyle(.iconOnly)
                .help(tagsPanelHelpText)

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
                    Label(String(localized: "Debug Issues", bundle: bundle), systemImage: "ladybug")
                }
                .labelStyle(.iconOnly)
                .help(String(localized: "Open Debug Issues", bundle: bundle))
            }
        }
    }

    func modeToolbar(readingMode: Binding<ReadingMode>) -> some View {
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

    var themePreviewMenu: some View {
        Button {
            isThemePanelPresented.toggle()
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
        } label: {
            Label(String(localized: "Share", bundle: bundle), systemImage: "square.and.arrow.up")
        }
        .labelStyle(.iconOnly)
        .menuIndicator(.hidden)
        .help(String(localized: "Share", bundle: bundle))
    }

    // MARK: - Translation Toolbar Helpers

    var tagsPanelHelpText: String {
        if isTagPanelPresented {
            return String(localized: "Close tags panel", bundle: bundle)
        }
        return String(localized: "Open tags panel", bundle: bundle)
    }

    var themePanelHelpText: String {
        if isThemePanelPresented {
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

}
