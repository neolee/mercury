import AppKit
import SwiftUI

struct ReaderExportDigestSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @Environment(\.localizationBundle) private var bundle
    @EnvironmentObject private var appModel: AppModel
    @StateObject private var viewModel = ReaderExportDigestSheetViewModel()

    let entry: Entry
    let loadReaderHTML: (Entry, EffectiveReaderTheme) async -> ReaderBuildResult
    let effectiveReaderTheme: EffectiveReaderTheme
    let onDismissed: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export Digest", bundle: bundle)
                .font(.title2)

            metadataSection

            if viewModel.exportDirectoryRecoveryMessage != nil {
                exportPathWarningSection
            }

            Toggle(isOn: $viewModel.includeSummary) {
                Text("Include Summary", bundle: bundle)
            }
            .toggleStyle(.checkbox)

            if viewModel.includeSummary {
                summarySection
            }

            Toggle(isOn: $viewModel.includeNote) {
                Text("Include Note", bundle: bundle)
            }
            .toggleStyle(.checkbox)

            if viewModel.includeNote {
                EntryNoteEditorView(
                    text: Binding(
                        get: { viewModel.noteDraftText },
                        set: { viewModel.updateNoteDraftText($0) }
                    ),
                    statusText: localizedNoteStatusText,
                    placeholder: String(localized: "Write note about this entry...", bundle: bundle),
                    autoFocus: false
                )
            }

            previewSection

            HStack(alignment: .center) {
                if let actionMessage = actionRowMessage {
                    Text(actionMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(String(localized: "Cancel", bundle: bundle), role: .cancel) {
                    dismiss()
                }

                Button(String(localized: "Copy", bundle: bundle)) {
                    Task {
                        guard let markdown = await viewModel.prepareCopyMarkdown() else {
                            return
                        }
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(markdown, forType: .string)
                    }
                }
                .disabled(viewModel.canCopyDigest == false)

                Button(String(localized: "Export", bundle: bundle)) {
                    Task {
                        if let _ = await viewModel.exportDigest() {
                            dismiss()
                        }
                    }
                }
                .disabled(viewModel.canExportDigest == false || viewModel.exportState == .exporting)
            }
        }
        .padding(20)
        .frame(width: 720)
        .task {
            await viewModel.bindIfNeeded(
                appModel: appModel,
                entry: entry,
                loadReaderHTML: loadReaderHTML,
                effectiveReaderTheme: effectiveReaderTheme,
                bundle: bundle
            )
        }
        .onDisappear {
            Task {
                await viewModel.handleSheetClose()
                await onDismissed()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
            Task { await viewModel.handleAppBackgrounding() }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("NSWindowDidResignKeyNotification"))) { _ in
            Task { await viewModel.handleAppBackgrounding() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            viewModel.refreshExportDirectory()
        }
    }

    private var metadataSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                metadataRow(label: String(localized: "Title", bundle: bundle), value: viewModel.articleTitle)
                metadataRow(label: String(localized: "Author", bundle: bundle), value: viewModel.articleAuthor)
                metadataRow(label: String(localized: "URL", bundle: bundle), value: viewModel.articleURL)
                metadataRow(label: String(localized: "Digest Title", bundle: bundle), value: viewModel.digestTitle)
                metadataRow(label: String(localized: "Export Filename", bundle: bundle), value: viewModel.exportFileName)
                metadataRow(
                    label: String(localized: "Export Folder", bundle: bundle),
                    value: viewModel.exportDirectoryPath.isEmpty
                        ? String(localized: "Not configured", bundle: bundle)
                        : viewModel.exportDirectoryPath
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var exportPathWarningSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if let recoveryMessage = viewModel.exportDirectoryRecoveryMessage {
                    Text(recoveryMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Button(String(localized: "Open Digest Settings", bundle: bundle)) {
                    AppSettingsNavigation.requestDigestTab()
                    openSettings()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var summarySection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Summary", bundle: bundle)
                    .font(.headline)

                HStack(spacing: 12) {
                    Picker(String(localized: "Target Language", bundle: bundle), selection: $viewModel.summaryTargetLanguage) {
                        ForEach(AgentLanguageOption.supported) { option in
                            Text(option.nativeName).tag(option.code)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 220, alignment: .leading)
                    .disabled(viewModel.isSummaryRunning || viewModel.isSummaryLoading)

                    Picker(String(localized: "Detail Level", bundle: bundle), selection: $viewModel.summaryDetailLevel) {
                        ForEach(SummaryDetailLevel.allCases, id: \.self) { level in
                            Text(level.labelKey, bundle: bundle).tag(level)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 320, alignment: .leading)
                    .disabled(viewModel.isSummaryRunning || viewModel.isSummaryLoading)

                    Spacer()

                    Button(String(localized: "Generate", bundle: bundle)) {
                        Task { await viewModel.generateSummary() }
                    }
                    .disabled(viewModel.isSummaryRunning || viewModel.isSummaryLoading)
                }

                ScrollView {
                    Text(
                        localizedSummarySectionText
                    )
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                }
                .frame(minHeight: 120, maxHeight: 220)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
            }
        }
        .onChange(of: viewModel.summaryTargetLanguage) { _, _ in
            Task { await viewModel.handleSummaryControlChange() }
        }
        .onChange(of: viewModel.summaryDetailLevel) { _, _ in
            Task { await viewModel.handleSummaryControlChange() }
        }
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Preview", bundle: bundle)
                .font(.headline)

            ScrollView {
                Text(viewModel.exportPreviewMarkdown)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(minHeight: 180, maxHeight: 280)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )
        }
    }

    private func metadataRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value.isEmpty ? " " : value)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var localizedNoteStatusText: String? {
        switch viewModel.noteSaveState {
        case .idle:
            return nil
        case .saving:
            return String(localized: "Saving...", bundle: bundle)
        case .saved:
            return String(localized: "Saved", bundle: bundle)
        case .failed:
            return String(localized: "Save failed", bundle: bundle)
        }
    }

    private var localizedExportFailureMessage: String? {
        switch viewModel.exportState {
        case .idle:
            return nil
        case .exporting:
            return String(localized: "Exporting...", bundle: bundle)
        case .failed(let message):
            return message
        }
    }

    private var actionRowMessage: String? {
        localizedExportFailureMessage ?? viewModel.templateNoticeMessage
    }

    private var localizedSummarySectionText: String {
        let normalizedSummary = viewModel.summaryText.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedSummary.isEmpty == false {
            return viewModel.summaryText
        }

        switch viewModel.summaryState {
        case .loading:
            return String(localized: "Loading...", bundle: bundle)
        case .generating:
            return String(localized: "Generating...", bundle: bundle)
        case .cancelled:
            return String(localized: "Cancelled", bundle: bundle)
        case .failed(let message):
            return message ?? String(localized: "Generation failed", bundle: bundle)
        case .idle, .saved:
            return String(localized: "No summary for the current summary settings.", bundle: bundle)
        }
    }
}
