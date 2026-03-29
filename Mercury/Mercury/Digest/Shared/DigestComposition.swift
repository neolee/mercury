import Foundation

nonisolated struct SingleEntryDigestTextShareContent: Equatable, Sendable {
    let articleTitle: String
    let articleAuthor: String
    let articleURL: String
    let noteText: String?
}

enum DigestComposition {
    nonisolated static func resolvedAuthor(
        entryAuthor: String?,
        readabilityByline: String? = nil,
        feedTitle: String?
    ) -> String {
        let normalizedAuthor = normalizeRequiredText(entryAuthor)
        if normalizedAuthor.isEmpty == false {
            return normalizedAuthor
        }

        let normalizedByline = normalizeRequiredText(readabilityByline)
        if normalizedByline.isEmpty == false {
            return normalizedByline
        }

        return normalizeRequiredText(feedTitle)
    }

    nonisolated static func canShareSingleEntry(entry: Entry) -> Bool {
        normalizeRequiredText(entry.title).isEmpty == false &&
        normalizeRequiredText(entry.url).isEmpty == false
    }

    nonisolated static func singleEntryTextShareContent(
        entry: Entry,
        readabilityByline: String? = nil,
        feedTitle: String?,
        noteText: String?,
        includeNote: Bool
    ) -> SingleEntryDigestTextShareContent? {
        singleEntryTextShareContent(
            articleTitle: entry.title,
            articleAuthor: resolvedAuthor(
                entryAuthor: entry.author,
                readabilityByline: readabilityByline,
                feedTitle: feedTitle
            ),
            articleURL: entry.url,
            noteText: noteText,
            includeNote: includeNote
        )
    }

    nonisolated static func singleEntryTextShareContent(
        articleTitle: String?,
        articleAuthor: String?,
        articleURL: String?,
        noteText: String?,
        includeNote: Bool
    ) -> SingleEntryDigestTextShareContent? {
        let title = normalizeRequiredText(articleTitle)
        let url = normalizeRequiredText(articleURL)

        guard title.isEmpty == false, url.isEmpty == false else {
            return nil
        }

        let includedNote = includeNote ? normalizeOptionalText(noteText) : nil

        return SingleEntryDigestTextShareContent(
            articleTitle: title,
            articleAuthor: normalizeRequiredText(articleAuthor),
            articleURL: url,
            noteText: includedNote
        )
    }

    nonisolated static func singleEntryTextTemplateContext(
        _ content: SingleEntryDigestTextShareContent
    ) -> DigestTemplateRenderContext {
        DigestTemplateRenderContext(
            scalars: [
                "articleTitle": content.articleTitle,
                "articleAuthor": content.articleAuthor,
                "articleURL": content.articleURL,
                "includeNote": content.noteText == nil ? "" : "true",
                "noteText": content.noteText ?? ""
            ]
        )
    }

    nonisolated static func renderSingleEntryTextShareFallback(_ content: SingleEntryDigestTextShareContent) -> String {
        var parts: [String] = [content.articleTitle]
        if content.articleAuthor.isEmpty == false {
            parts.append("by")
            parts.append(content.articleAuthor)
        }
        parts.append(content.articleURL)

        var rendered = parts.joined(separator: " ")
        if let noteText = content.noteText {
            rendered += " \(noteText)"
        }
        return rendered
    }

    nonisolated private static func normalizeRequiredText(_ text: String?) -> String {
        (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func normalizeOptionalText(_ text: String?) -> String? {
        let value = text ?? ""
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
    }
}
