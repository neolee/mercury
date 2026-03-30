import AppKit
import SwiftUI

struct ReaderShareDigestSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.localizationBundle) private var bundle
    @EnvironmentObject private var appModel: AppModel
    @StateObject private var viewModel = ReaderShareDigestSheetViewModel()

    let entry: Entry
    let onDismissed: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Share Digest", bundle: bundle)
                .font(.title2)

            metadataSection

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
                    placeholder: String(localized: "Write note about this entry...", bundle: bundle)
                )
            }

            previewSection

            HStack(alignment: .center) {
                if let actionMessage = viewModel.templateNoticeMessage {
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
                        guard let text = await viewModel.prepareCopyText() else {
                            return
                        }
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(text, forType: .string)
                    }
                }
                .disabled(viewModel.canShareDigest == false)

                ShareServicesButton(
                    title: String(localized: "Share", bundle: bundle),
                    isEnabled: viewModel.canShareDigest,
                    prepareItems: {
                        await viewModel.prepareShareItems()
                    }
                )
                .frame(width: 80, height: 30)
            }
        }
        .padding(20)
        .frame(width: 560)
        .task {
            await viewModel.bindIfNeeded(appModel: appModel, entry: entry)
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
    }

    private var metadataSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                metadataRow(label: String(localized: "Title", bundle: bundle), value: viewModel.articleTitle)
                metadataRow(label: String(localized: "Author", bundle: bundle), value: viewModel.articleAuthor)
                metadataRow(label: String(localized: "URL", bundle: bundle), value: viewModel.articleURL)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Preview", bundle: bundle)
                .font(.headline)

            ScrollView {
                Text(viewModel.sharePreviewText)
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
}
