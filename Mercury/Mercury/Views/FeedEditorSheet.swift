//
//  FeedEditorSheet.swift
//  Mercury
//
//  Created by Neo on 2026/2/4.
//

import SwiftUI

struct FeedEditorState: Identifiable {
    enum Mode {
        case add
        case edit(Feed)
    }

    let id = UUID()
    let mode: Mode
}

enum FeedEditorResult {
    case add(title: String?, url: String)
    case edit(feed: Feed, title: String?, url: String)
}

struct FeedEditorSheet: View {
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
                TextField("Name (optional)", text: $title)
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
