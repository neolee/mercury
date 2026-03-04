//
//  ReaderTaggingPanelView.swift
//  Mercury
//
//  Created by Neo on 2026/2/4.
//

import SwiftUI

/// Self-contained floating panel for entry tag management.
///
/// The panel owns all tag-editor state except `entryTags`, which is shared with the parent so the
/// entry header can reflect tag changes without re-querying the database. All NLP, search, and
/// input state is scoped to the panel and resets automatically when the panel is dismissed.
struct ReaderTaggingPanelView: View {

    // MARK: - Environment

    @EnvironmentObject private var appModel: AppModel
    @Environment(\.localizationBundle) private var bundle

    // MARK: - Inputs

    let entry: Entry
    @Binding var entryTags: [Tag]
    @Binding var topBannerMessage: ReaderBannerMessage?
    let onTagsChanged: () async -> Void

    // MARK: - State

    @State private var availableTags: [Tag] = []
    @State private var searchableTags: [Tag] = []   // all tags including provisional; used for prefix search and fuzzy hints
    @State private var tagInputText = ""
    @State private var isTagEditorLoading = false
    @State private var nlpSuggestions: [String] = []
    @State private var isAISuggestionsLoading = false
    @State private var pendingSuggestion: TagInputSuggestion?

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Tags", bundle: bundle)
                    .font(.headline)
                Spacer()
                if isTagEditorLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            HStack(spacing: 8) {
                TextField(String(localized: "Type tags (comma-separated)", bundle: bundle), text: $tagInputText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        Task { await addTagsFromInput() }
                    }
                    .onChange(of: tagInputText) { oldValue, newValue in
                        // Detect word boundary: user just appended a single space or comma.
                        guard newValue.count == oldValue.count + 1,
                              let lastChar = newValue.last,
                              lastChar == " " || lastChar == ","
                        else {
                            pendingSuggestion = nil
                            return
                        }
                        computeInputSuggestion(separator: lastChar)
                    }

                Button(action: {
                    Task { await addTagsFromInput() }
                }) {
                    Text("Add", bundle: bundle)
                }
                .disabled(tagInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            tagInputSuggestionRow

            nlpSuggestionsSection

            existingTagSuggestions

            if entryTags.isEmpty {
                Text("No tags yet", bundle: bundle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(entryTags, id: \.id) { tag in
                            HStack(spacing: 8) {
                                Text(tag.name)
                                    .lineLimit(1)
                                Spacer()
                                Button(role: .destructive) {
                                    Task { await removeTag(tag) }
                                } label: {
                                    Image(systemName: "xmark.circle")
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: min(CGFloat(entryTags.count) * 36 + 12, 160))
            }
        }
        .padding(12)
        .frame(width: 280)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 4)
        .onTapGesture {}
        .onAppear {
            Task { await loadNLPSuggestions() }
            Task { await loadAvailableTags() }
            Task { await loadSearchableTags() }
            if appModel.isTaggingAgentAvailable
                && UserDefaults.standard.bool(forKey: "Agent.Tagging.Enabled") {
                Task { await startAITaggingSuggestions() }
            }
        }
        .onDisappear {
            guard let entryId = entry.id else { return }
            Task { await appModel.cancelTaggingPanelRun(entryId: entryId) }
        }
    }

    // MARK: - NLP Suggestions

    @ViewBuilder
    private var nlpSuggestionsSection: some View {
        let appliedNormed = Set(entryTags.map { $0.normalizedName })
        let candidates = nlpSuggestions
            .filter { appliedNormed.contains(TagNormalization.normalize($0)) == false }
            .prefix(TaggingPolicy.maxAIRecommendations)

        if isAISuggestionsLoading && candidates.isEmpty {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text("Generating suggestions...", bundle: bundle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if candidates.isEmpty == false {
            suggestionChipSection(
                title: "AI Suggested",
                items: Array(candidates).map { name in
                    SuggestionChipItem(
                        id: "ai-\(name)",
                        title: name,
                        fillOpacity: 0.1,
                        action: {
                            Task { await addSuggestedTag(name) }
                        }
                    )
                },
                showsLoadingIndicatorInTitle: isAISuggestionsLoading
            )
        }
    }

    // MARK: - AI Suggestions

    /// Load AI tag suggestions via the tagging agent if available.
    /// On completion, merges AI results with existing NLP results: AI suggestions appear first,
    /// followed by any NLP entities not already covered by the AI output.
    /// On failure or cancellation, silently retains NLP results only.
    private func startAITaggingSuggestions() async {
        guard let entryId = entry.id else { return }
        let title = entry.title ?? ""
        // Use Readability markdown body if available, fall back to summary.
        let body: String
        if let content = try? await appModel.contentStore.content(for: entryId),
           let markdown = content.markdown,
           markdown.isEmpty == false {
            body = String(markdown.prefix(800))
        } else {
            body = entry.summary ?? ""
        }

        isAISuggestionsLoading = true
        let request = TaggingPanelRequest(entryId: entryId, title: title, body: body)

        _ = await appModel.startTaggingPanelRun(request: request) { event in
            switch event {
            case .started:
                break
            case .notice(let message):
                await MainActor.run {
                    topBannerMessage = ReaderBannerMessage(
                        text: message,
                        secondaryAction: .openDebugIssues
                    )
                }
            case .completed(let tagNames):
                await MainActor.run {
                    // Merge: AI results first, then any NLP entities not already covered.
                    let aiNormed = Set(tagNames.map { TagNormalization.normalize($0) })
                    let nlpOnly = nlpSuggestions.filter { aiNormed.contains(TagNormalization.normalize($0)) == false }
                    nlpSuggestions = tagNames + nlpOnly
                }
            case .terminal:
                await MainActor.run {
                    isAISuggestionsLoading = false
                }
            }
        }
        // startTaggingPanelRun returns immediately after enqueuing.
        // isAISuggestionsLoading is reset via the .terminal event callback.
    }

    // MARK: - Existing Tag Suggestions

    @ViewBuilder
    private var existingTagSuggestions: some View {
        let normalizedCurrentTags = Set(entryTags.map { $0.normalizedName })
        let normalizedNLPSuggestions = Set(nlpSuggestions.prefix(TaggingPolicy.maxAIRecommendations).map { TagNormalization.normalize($0) })
        let excluded = normalizedCurrentTags.union(normalizedNLPSuggestions)
        let inputPrefix = TagNormalization.normalize(tagInputText)
        // When the user is typing, search all tags including provisional so recently-created
        // or batch-assigned tags are discoverable. When idle, show popular non-provisional only.
        let pool = inputPrefix.isEmpty ? availableTags : searchableTags
        let candidates = pool.filter {
            excluded.contains($0.normalizedName) == false &&
            (inputPrefix.isEmpty || $0.normalizedName.hasPrefix(inputPrefix))
        }

        if candidates.isEmpty == false {
            suggestionChipSection(
                title: "From existing tags",
                items: candidates
                    .prefix(TaggingPolicy.maxExistingTagChips)
                    .compactMap { tag in
                        guard let tagId = tag.id else { return nil }
                        return SuggestionChipItem(
                            id: "existing-\(tagId)",
                            title: tag.name,
                            fillOpacity: 0.15,
                            action: {
                                Task { await addExistingTag(tag) }
                            }
                        )
                    }
            )
        }
    }

    @ViewBuilder
    private func suggestionChipSection(
        title: LocalizedStringKey,
        items: [SuggestionChipItem],
        showsLoadingIndicatorInTitle: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(title, bundle: bundle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if showsLoadingIndicatorInTitle {
                    ProgressView()
                        .controlSize(.mini)
                }
            }

            TagSuggestionChipContainer {
                ForEach(items) { item in
                    Button(action: item.action) {
                        Text(item.title)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.accentColor.opacity(item.fillOpacity)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Tag Input Suggestions

    @ViewBuilder
    private var tagInputSuggestionRow: some View {
        if let suggestion = pendingSuggestion {
            HStack(spacing: 4) {
                Text("Did you mean:", bundle: bundle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    applyInputSuggestion(suggestion)
                } label: {
                    Text(suggestion.correctedText)
                        .font(.caption)
                        .underline()
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Extracts the token that triggered the word boundary and computes a `TagInputSuggestion`.
    private func computeInputSuggestion(separator: Character) {
        let text = tagInputText
        let token: String
        if separator == "," {
            // Entire last tag token (everything after the previous comma).
            let parts = text.dropLast().components(separatedBy: ",")
            token = (parts.last ?? "").trimmingCharacters(in: .whitespaces)
        } else {
            // Last single word before the space (spell-checks within a multi-word tag as user types).
            let words = text.dropLast().components(separatedBy: .whitespaces)
            token = words.last(where: { $0.isEmpty == false }) ?? ""
        }
        guard token.isEmpty == false else { return }
        let applied = Set(entryTags.map { $0.normalizedName })
        pendingSuggestion = TagInputSuggestionEngine.suggest(
            for: token,
            in: searchableTags,
            excluding: applied
        )
    }

    /// Replaces the triggering token in `tagInputText` with the accepted suggestion.
    /// Only the most-recently-typed occurrence of the original token is replaced.
    private func applyInputSuggestion(_ suggestion: TagInputSuggestion) {
        if let range = tagInputText.range(of: suggestion.original, options: [.caseInsensitive, .backwards]) {
            tagInputText.replaceSubrange(range, with: suggestion.correctedText)
        }
        pendingSuggestion = nil
    }

    // MARK: - Tag Actions

    private func addTagsFromInput() async {
        let names = parseTagInput(tagInputText)
        guard names.isEmpty == false else { return }
        guard let entryId = entry.id else { return }

        isTagEditorLoading = true
        defer { isTagEditorLoading = false }

        do {
            try await appModel.entryStore.assignTags(to: entryId, names: names, source: "manual")
            tagInputText = ""
            pendingSuggestion = nil
            await loadEntryTags()
            await loadAvailableTags()
            await onTagsChanged()
        } catch {
            topBannerMessage = ReaderBannerMessage(text: String(localized: "Tag update failed", bundle: bundle))
        }
    }

    private func addSuggestedTag(_ name: String) async {
        guard let entryId = entry.id else { return }
        isTagEditorLoading = true
        defer { isTagEditorLoading = false }
        do {
            try await appModel.entryStore.assignTags(to: entryId, names: [name], source: "manual")
            // Do not remove from nlpSuggestions here. The nlpSuggestionsSection filters out
            // applied tags at render time, so removing the tag later will restore the chip
            // automatically without needing to re-run NLTagger.
            await loadEntryTags()
            await loadAvailableTags()
            await onTagsChanged()
        } catch {
            topBannerMessage = ReaderBannerMessage(text: String(localized: "Tag update failed", bundle: bundle))
        }
    }

    private func addExistingTag(_ tag: Tag) async {
        guard let entryId = entry.id else { return }
        isTagEditorLoading = true
        defer { isTagEditorLoading = false }

        do {
            try await appModel.entryStore.assignTags(to: entryId, names: [tag.name], source: "manual")
            await loadEntryTags()
            await loadAvailableTags()
            await onTagsChanged()
        } catch {
            topBannerMessage = ReaderBannerMessage(text: String(localized: "Tag update failed", bundle: bundle))
        }
    }

    private func removeTag(_ tag: Tag) async {
        guard let tagId = tag.id, let entryId = entry.id else { return }

        isTagEditorLoading = true
        defer { isTagEditorLoading = false }

        do {
            try await appModel.entryStore.removeTag(from: entryId, tagId: tagId)
            await loadEntryTags()
            await loadAvailableTags()
            await onTagsChanged()
        } catch {
            topBannerMessage = ReaderBannerMessage(text: String(localized: "Tag update failed", bundle: bundle))
        }
    }

    private func parseTagInput(_ text: String) -> [String] {
        text
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
    }

    // MARK: - Data Loaders

    private func loadEntryTags() async {
        guard let entryId = entry.id else { entryTags = []; return }
        entryTags = await appModel.entryStore.fetchTags(for: entryId)
    }

    private func loadAvailableTags() async {
        availableTags = await appModel.entryStore.fetchTags(includeProvisional: false)
    }

    private func loadSearchableTags() async {
        searchableTags = await appModel.entryStore.fetchTags(includeProvisional: true)
    }

    /// Loads NLP-extracted entity suggestions into `nlpSuggestions` for display in the tagging
    /// panel. This method has no database side-effects; nothing is written until the user accepts
    /// a suggestion by tapping its chip.
    private func loadNLPSuggestions() async {
        guard entry.title != nil || entry.summary != nil else { return }
        let entities = await appModel.localTaggingService.extractEntities(
            title: entry.title,
            summary: entry.summary
        )
        nlpSuggestions = entities
    }

}

private struct SuggestionChipItem: Identifiable {
    let id: String
    let title: String
    let fillOpacity: Double
    let action: () -> Void
}

private struct TagSuggestionChipContainer<Content: View>: View {
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        TagChipFlowLayout(spacing: 6, rowSpacing: 6) {
            content
        }
        .padding(.vertical, 1)
    }
}

private struct TagChipFlowLayout: Layout {
    var spacing: CGFloat = 6
    var rowSpacing: CGFloat = 6

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var currentRowHeight: CGFloat = 0
        var widestRow: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX > 0 && currentX + size.width > maxWidth {
                widestRow = max(widestRow, currentX - spacing)
                currentX = 0
                currentY += currentRowHeight + rowSpacing
                currentRowHeight = 0
            }

            currentX += size.width + spacing
            currentRowHeight = max(currentRowHeight, size.height)
        }

        if subviews.isEmpty {
            return .zero
        }

        widestRow = max(widestRow, max(0, currentX - spacing))
        return CGSize(width: widestRow, height: currentY + currentRowHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let maxWidth = bounds.width
        var currentX = bounds.minX
        var currentY = bounds.minY
        var currentRowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX > bounds.minX && currentX + size.width > bounds.minX + maxWidth {
                currentX = bounds.minX
                currentY += currentRowHeight + rowSpacing
                currentRowHeight = 0
            }

            subview.place(
                at: CGPoint(x: currentX, y: currentY),
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
            currentX += size.width + spacing
            currentRowHeight = max(currentRowHeight, size.height)
        }
    }
}
