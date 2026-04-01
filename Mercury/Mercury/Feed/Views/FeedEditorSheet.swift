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
    let onCheck: (String) async throws -> FeedLoadUseCase.VerifiedFeed
    let onSave: (FeedEditorResult, FeedLoadUseCase.VerifiedFeed?) async throws -> Void
    let onCheckError: (String) -> Void
    let onSaveError: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.localizationBundle) var bundle
    @State private var title: String = ""
    @State private var url: String = ""
    @State private var isChecking = false
    @State private var isSaving = false
    @State private var validationError: String?
    @State private var verifiedFeed: FeedLoadUseCase.VerifiedFeed?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(titleKey(bundle: bundle))
                .font(.title3)

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    TextField(String(localized: "Feed URL", bundle: bundle), text: $url)
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
                    .disabled(isChecking || isSaving || url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Check feed and fetch title")
                }
                TextField(String(localized: "Name (optional)", bundle: bundle), text: $title)
                if let validationError, validationError.isEmpty == false {
                    Text(validationError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            HStack {
                Spacer()
                Button(action: { dismiss() }) { Text("Cancel", bundle: bundle) }
                Button(action: { Task { await save() } }) { Text("Save", bundle: bundle) }
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving || isChecking || url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onChange(of: url) { _, _ in
            validationError = nil
            verifiedFeed = nil
        }
        .onChange(of: title) { _, _ in
            validationError = nil
        }
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
            let verifiedFeed = try await onCheck(trimmed)
            self.verifiedFeed = verifiedFeed
            if let fetchedTitle = verifiedFeed.title {
                title = fetchedTitle
            }
            validationError = nil
        } catch {
            verifiedFeed = nil
            validationError = error.localizedDescription
            if (error as? FeedEditError) == nil {
                onCheckError(error.localizedDescription)
            }
        }
    }

    @MainActor
    private func save() async {
        guard isSaving == false else { return }

        isSaving = true
        defer { isSaving = false }

        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let result: FeedEditorResult
        switch state.mode {
        case .add:
            result = .add(title: title, url: trimmedURL)
        case .edit(let feed):
            result = .edit(feed: feed, title: title, url: trimmedURL)
        }

        do {
            let cachedVerifiedFeed: FeedLoadUseCase.VerifiedFeed?
            if let normalizedURL = try? FeedInputValidator.validateFeedURL(trimmedURL),
               verifiedFeed?.feedURL == normalizedURL {
                cachedVerifiedFeed = verifiedFeed
            } else {
                cachedVerifiedFeed = nil
            }
            try await onSave(result, cachedVerifiedFeed)
            dismiss()
        } catch {
            validationError = error.localizedDescription
            if (error as? FeedEditError) == nil {
                onSaveError(error.localizedDescription)
            }
        }
    }

    private func titleKey(bundle: Bundle) -> String {
        switch state.mode {
        case .add:
            return String(localized: "Add Feed", bundle: bundle)
        case .edit:
            return String(localized: "Edit Feed", bundle: bundle)
        }
    }
}
