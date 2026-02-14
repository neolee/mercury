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
    let loadReaderHTML: (Entry) async -> ReaderBuildResult
    let onOpenDebugIssues: (() -> Void)?

    @State private var readerHTML: String?
    @State private var isLoadingReader = false
    @State private var readerError: String?

    var body: some View {
        Group {
            if let entry = selectedEntry, let urlString = entry.url, let url = URL(string: urlString) {
                readingContent(for: entry, url: url, urlString: urlString)
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
        "\(entryId ?? 0)-\(needsReader)-\(readingModeRaw)"
    }
}
