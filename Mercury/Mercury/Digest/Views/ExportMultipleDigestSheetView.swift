import AppKit
import SwiftUI

struct ExportMultipleDigestSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @Environment(\.localizationBundle) private var bundle
    @EnvironmentObject private var appModel: AppModel
    @StateObject private var viewModel = ExportMultipleDigestSheetViewModel()

    let orderedEntryIDs: [Int64]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export Multiple Digest", bundle: bundle)
                .font(.title2)

            metadataSection

            if viewModel.exportDirectoryRecoveryMessage != nil {
                exportPathWarningSection
            }

            selectionSection

            Toggle(isOn: $viewModel.includeSummary) {
                Text("Include Summary", bundle: bundle)
            }
            .toggleStyle(.checkbox)

            Toggle(isOn: $viewModel.includeNote) {
                Text("Include Note", bundle: bundle)
            }
            .toggleStyle(.checkbox)

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
                    guard let markdown = viewModel.prepareCopyMarkdown() else {
                        return
                    }
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(markdown, forType: .string)
                }
                .disabled(viewModel.canCopyDigest == false)

                Button(String(localized: "Export", bundle: bundle)) {
                    Task {
                        if let _ = await viewModel.exportDigest() {
                            dismiss()
                        }
                    }
                }
                .disabled(viewModel.canExportDigest == false)
            }
        }
        .padding(20)
        .frame(width: 720)
        .task {
            await viewModel.bindIfNeeded(
                appModel: appModel,
                orderedEntryIDs: orderedEntryIDs,
                bundle: bundle
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
            viewModel.handleAppBackgrounding()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("NSWindowDidResignKeyNotification"))) { _ in
            viewModel.handleAppBackgrounding()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            viewModel.refreshExportDirectory()
        }
    }

    private var metadataSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                metadataRow(
                    label: String(localized: "Selected Entries", bundle: bundle),
                    value: String(viewModel.selectedEntries.count)
                )
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

    private var selectionSection: some View {
        GroupBox {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(viewModel.selectedEntries) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.articleTitle)
                                .font(.body.weight(.medium))
                            Text(entry.articleAuthor)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(entry.articleURL)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(minHeight: 96, maxHeight: 180)
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

    private var localizedExportFailureMessage: String? {
        guard case let .failed(message) = viewModel.exportState else {
            return nil
        }
        return message
    }

    private var actionRowMessage: String? {
        localizedExportFailureMessage ?? viewModel.templateNoticeMessage
    }
}
