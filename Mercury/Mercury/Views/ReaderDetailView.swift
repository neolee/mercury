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

    var body: some View {
        Group {
            if let entry = selectedEntry, let urlString = entry.url, let url = URL(string: urlString) {
                readingContent(for: url, urlString: urlString)
            } else {
                emptyState
            }
        }
        .navigationTitle(selectedEntry?.title ?? "Reader")
        .toolbar {
            entryToolbar
        }
    }

    @ViewBuilder
    private func readingContent(for url: URL, urlString: String) -> some View {
        switch ReadingMode(rawValue: readingModeRaw) ?? .reader {
        case .reader:
            readerPlaceholder
        case .web:
            webContent(url: url, urlString: urlString)
        case .dual:
            HStack(spacing: 0) {
                readerPlaceholder
                Divider()
                webContent(url: url, urlString: urlString)
            }
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

    private var readerPlaceholder: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Reader mode")
                    .font(.title2)
                Text("Clean content will appear here once HTML cleaning and Markdown rendering are wired up.")
                    .foregroundStyle(.secondary)
                Text("This view will support typography controls and themes in a later step.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor))
    }
}
