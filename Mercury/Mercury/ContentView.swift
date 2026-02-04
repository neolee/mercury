//
//  ContentView.swift
//  Mercury
//
//  Created by Neo on 2026/2/3.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var selectedFeedId: Int64?
    @State private var selectedEntryId: Int64?
    @AppStorage("readingMode") private var readingModeRaw: String = ReadingMode.reader.rawValue
    @State private var isLoadingEntries = false
    @State private var editorState: FeedEditorState?
    @State private var pendingDeleteFeed: Feed?
    @State private var pendingImportURL: URL?
    @State private var isShowingImportOptions = false
    @State private var replaceOnImport = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationSplitView {
            sidebar
        } content: {
            entryList
        } detail: {
            detailView
        }
        .task {
            await appModel.feedStore.loadAll()
            appModel.refreshUnreadTotals()
            if selectedFeedId == nil {
                selectedFeedId = appModel.feedStore.feeds.first?.id
            }
            await loadEntries(for: selectedFeedId, selectFirst: selectedEntryId == nil)
            await appModel.bootstrapIfNeeded()
            await loadEntries(for: selectedFeedId, selectFirst: selectedEntryId == nil)
        }
        .task {
            await startAutoSyncLoop()
        }
        .onChange(of: selectedFeedId) { _, newValue in
            Task {
                await loadEntries(for: newValue, selectFirst: true)
            }
        }
        .onChange(of: selectedEntryId) { _, _ in
            guard let entry = selectedEntry else { return }
            Task {
                await appModel.markEntryRead(entry)
            }
        }
        .sheet(item: $editorState) { state in
            FeedEditorSheet(
                state: state,
                onCheck: { url in
                    try await appModel.fetchFeedTitle(for: url)
                },
                onSave: { result in
                    Task {
                        await handleFeedSave(result)
                    }
                },
                onError: { message in
                    errorMessage = message
                }
            )
        }
        .sheet(isPresented: $isShowingImportOptions) {
            ImportOPMLSheet(replaceExisting: $replaceOnImport) {
                Task {
                    await confirmImport()
                }
            }
        }
        .alert("Delete Feed", isPresented: Binding(
            get: { pendingDeleteFeed != nil },
            set: { if !$0 { pendingDeleteFeed = nil } }
        ), presenting: pendingDeleteFeed) { feed in
            Button("Delete", role: .destructive) {
                Task {
                    await deleteFeed(feed)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { feed in
            Text("Delete \"\(feed.title ?? feed.feedURL)\"? This also removes all associated entries.")
        }
        .alert("Operation Failed", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Unknown error.")
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Feeds")
                    .font(.headline)
                Spacer()
                Menu {
                    Button("Add Feed…") {
                        editorState = FeedEditorState(mode: .add)
                    }
                    Button("Import OPML…") {
                        Task {
                            await beginImportFlow()
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)

                Menu {
                    Button("Sync Now") {
                        Task {
                            await appModel.syncAllFeeds()
                            await loadEntries(for: selectedFeedId, selectFirst: selectedEntryId == nil)
                        }
                    }
                    Divider()
                    Button("Export OPML…") {
                        Task {
                            await exportOPML()
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            List(selection: $selectedFeedId) {
                ForEach(appModel.feedStore.feeds) { feed in
                    HStack(spacing: 8) {
                        Text(feed.title ?? feed.feedURL)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if feed.unreadCount > 0 {
                            Text("\(feed.unreadCount)")
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        }
                    }
                    .tag(feed.id)
                    .contextMenu {
                        Button("Edit…") {
                            editorState = FeedEditorState(mode: .edit(feed))
                        }
                        Button("Delete…", role: .destructive) {
                            pendingDeleteFeed = feed
                        }
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                statusView
            }
            .padding(8)
        }
        .frame(minWidth: 220)
    }

    private var entryList: some View {
        List(selection: $selectedEntryId) {
            if isLoadingEntries {
                ProgressView()
            }

            ForEach(appModel.entryStore.entries) { entry in
                HStack(alignment: .top, spacing: 8) {
                    if entry.isRead == false {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                            .padding(.top, 6)
                    } else {
                        Circle()
                            .fill(Color.clear)
                            .frame(width: 6, height: 6)
                            .padding(.top, 6)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.title ?? "(Untitled)")
                            .fontWeight(entry.isRead ? .regular : .semibold)
                            .foregroundStyle(entry.isRead ? .secondary : .primary)
                            .lineLimit(2)
                        if let publishedAt = entry.publishedAt {
                            Text(Self.dateFormatter.string(from: publishedAt))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .tag(entry.id)
            }
        }
        .navigationTitle("Entries")
    }

    private var detailView: some View {
        Group {
            if let entry = selectedEntry, let urlString = entry.url, let url = URL(string: urlString) {
                readingContent(for: url, urlString: urlString)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .imageScale(.large)
                        .foregroundStyle(.secondary)
                    Text("Select an entry to read")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    @ViewBuilder
    private var statusView: some View {
        switch appModel.bootstrapState {
        case .importing:
            Label("Syncing…", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        case .failed(let message):
            Text("Bootstrap failed: \(message)")
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        case .idle, .ready:
            statusForSyncState
        }
    }

    @ViewBuilder
    private var statusForSyncState: some View {
        switch appModel.syncState {
        case .syncing:
            Label("Syncing…", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        case .failed(let message):
            Text("Sync failed: \(message)")
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        case .idle:
            TimelineView(.everyMinute) { timeline in
                Text("Feeds: \(appModel.feedCount) · Entries: \(appModel.entryCount) · Unread: \(appModel.totalUnreadCount) · Last sync: \(lastSyncDescription(relativeTo: timeline.date))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private func lastSyncDescription(relativeTo now: Date) -> String {
        guard let lastSyncAt = appModel.lastSyncAt else {
            return "never"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: lastSyncAt, relativeTo: now)
    }

    private var selectedEntry: Entry? {
        guard let selectedEntryId else { return nil }
        return appModel.entryStore.entries.first { $0.id == selectedEntryId }
    }

    private func loadEntries(for feedId: Int64?, selectFirst: Bool) async {
        isLoadingEntries = true
        await appModel.entryStore.loadAll(for: feedId)
        if selectFirst {
            selectedEntryId = appModel.entryStore.entries.first?.id
        }
        isLoadingEntries = false
    }

    private func startAutoSyncLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            await appModel.autoSyncIfNeeded()
        }
    }

    @MainActor
    private func beginImportFlow() async {
        guard let url = selectOPMLFile() else { return }
        pendingImportURL = url
        replaceOnImport = false
        isShowingImportOptions = true
    }

    @MainActor
    private func confirmImport() async {
        guard let url = pendingImportURL else { return }
        isShowingImportOptions = false

        do {
            try await appModel.importOPML(from: url, replaceExisting: replaceOnImport)
            await reloadAfterFeedChange()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func exportOPML() async {
        guard let url = selectOPMLExportURL() else { return }
        do {
            try await appModel.exportOPML(to: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func handleFeedSave(_ result: FeedEditorResult) async {
        do {
            switch result {
            case .add(let title, let url):
                try await appModel.addFeed(title: title, feedURL: url, siteURL: nil)
            case .edit(let feed, let title, let url):
                try await appModel.updateFeed(feed, title: title, feedURL: url, siteURL: feed.siteURL)
            }
            await reloadAfterFeedChange()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func deleteFeed(_ feed: Feed) async {
        do {
            try await appModel.deleteFeed(feed)
            await reloadAfterFeedChange(keepSelection: false)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func reloadAfterFeedChange(keepSelection: Bool = true) async {
        await appModel.feedStore.loadAll()
        await appModel.refreshCounts()

        if keepSelection, let selectedFeedId,
           appModel.feedStore.feeds.contains(where: { $0.id == selectedFeedId }) {
            await loadEntries(for: selectedFeedId, selectFirst: selectedEntryId == nil)
        } else {
            selectedFeedId = appModel.feedStore.feeds.first?.id
            await loadEntries(for: selectedFeedId, selectFirst: true)
        }
    }

    @MainActor
    private func selectOPMLFile() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [opmlContentType]
        panel.title = "Import OPML"

        if let directory = SecurityScopedBookmarkStore.resolveDirectory() {
            panel.directoryURL = directory
        }

        if panel.runModal() == .OK {
            if let url = panel.url {
                SecurityScopedBookmarkStore.saveDirectory(url.deletingLastPathComponent())
            }
            return panel.url
        }

        return nil
    }

    @MainActor
    private func selectOPMLExportURL() -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [opmlContentType]
        panel.nameFieldStringValue = "mercury.opml"
        panel.title = "Export OPML"

        if let directory = SecurityScopedBookmarkStore.resolveDirectory() {
            panel.directoryURL = directory
        }

        if panel.runModal() == .OK {
            if let url = panel.url {
                SecurityScopedBookmarkStore.saveDirectory(url.deletingLastPathComponent())
            }
            return panel.url
        }

        return nil
    }

    private var opmlContentType: UTType {
        UTType(filenameExtension: "opml") ?? .xml
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

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

#Preview {
    ContentView()
        .environmentObject(AppModel())
}

private struct FeedEditorState: Identifiable {
    enum Mode {
        case add
        case edit(Feed)
    }

    let id = UUID()
    let mode: Mode
}

private enum ReadingMode: String, CaseIterable, Identifiable {
    case reader
    case web
    case dual

    var id: String { rawValue }

    var label: String {
        switch self {
        case .reader:
            return "Reader"
        case .web:
            return "Web"
        case .dual:
            return "Dual"
        }
    }
}

private enum FeedEditorResult {
    case add(title: String?, url: String)
    case edit(feed: Feed, title: String?, url: String)
}

private struct FeedEditorSheet: View {
    let state: FeedEditorState
    let onCheck: (String) async throws -> String?
    let onSave: (FeedEditorResult) -> Void
    let onError: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String = ""
    @State private var url: String = ""
    @State private var isChecking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(titleText)
                .font(.title3)

            VStack(alignment: .leading, spacing: 12) {
                TextField("Title (optional)", text: $title)
                HStack(spacing: 8) {
                    TextField("Feed URL", text: $url)
                    Button {
                        Task {
                            await checkFeedTitle()
                        }
                    } label: {
                        if isChecking {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "checkmark.circle")
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isChecking || url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Check feed and fetch title")
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button("Save") {
                    let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
                    switch state.mode {
                    case .add:
                        onSave(.add(title: title, url: trimmedURL))
                    case .edit(let feed):
                        onSave(.edit(feed: feed, title: title, url: trimmedURL))
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear {
            switch state.mode {
            case .add:
                title = ""
                url = ""
            case .edit(let feed):
                title = feed.title ?? ""
                url = feed.feedURL
            }
        }
    }

    @MainActor
    private func checkFeedTitle() async {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }

        isChecking = true
        defer { isChecking = false }

        do {
            if let fetched = try await onCheck(trimmed) {
                title = fetched
            }
        } catch {
            onError(error.localizedDescription)
        }
    }

    private var titleText: String {
        switch state.mode {
        case .add:
            return "Add Feed"
        case .edit:
            return "Edit Feed"
        }
    }
}

private struct ImportOPMLSheet: View {
    @Binding var replaceExisting: Bool
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import OPML")
                .font(.title3)
            Toggle("Replace existing feeds", isOn: $replaceExisting)
            Text("Merge is the default and will keep your current subscriptions. Replace will delete all existing feeds first.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button("Import") {
                    onConfirm()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
