import Foundation

nonisolated struct DigestSingleEntryMarkdownContent: Equatable, Sendable {
    let digestTitle: String
    let articleTitle: String
    let articleAuthor: String
    let articleURL: String
    let summaryText: String?
    let summaryTargetLanguage: String?
    let summaryDetailLevel: SummaryDetailLevel?
    let noteText: String?
    let exportDate: Date
}

nonisolated struct DigestMultipleEntryMarkdownEntryContent: Equatable, Sendable {
    let articleTitle: String
    let articleAuthor: String
    let articleURL: String
    let summaryText: String?
    let noteText: String?
}

nonisolated struct DigestMultipleEntryMarkdownContent: Equatable, Sendable {
    let digestTitle: String
    let fileSlug: String
    let entries: [DigestMultipleEntryMarkdownEntryContent]
    let exportDate: Date
}

enum DigestExportError: LocalizedError {
    case exportDirectoryNotConfigured
    case exportDirectoryInvalid(String)

    var errorDescription: String? {
        switch self {
        case .exportDirectoryNotConfigured:
            return "Digest export directory is not configured."
        case let .exportDirectoryInvalid(path):
            return "Digest export directory is invalid: \(path)"
        }
    }
}

enum DigestExportPolicy {
    nonisolated private static let fallbackSlug = "digest"
    nonisolated private static let maxSlugLength = 80
    nonisolated private static let multipleEntrySlugSuffix = "digest"

    nonisolated private static let fileDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    nonisolated private static let multipleEntryDigestTitleDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "yyyy年MM月dd日"
        return formatter
    }()

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    nonisolated static func makeSingleEntryMarkdownContent(
        articleTitle: String,
        articleAuthor: String,
        articleURL: String,
        summaryText: String?,
        summaryTargetLanguage: String?,
        summaryDetailLevel: SummaryDetailLevel?,
        noteText: String?,
        exportDate: Date = Date()
    ) -> DigestSingleEntryMarkdownContent? {
        let normalizedTitle = normalizeRequiredText(articleTitle)
        let normalizedURL = normalizeRequiredText(articleURL)
        guard normalizedTitle.isEmpty == false, normalizedURL.isEmpty == false else {
            return nil
        }

        return DigestSingleEntryMarkdownContent(
            digestTitle: normalizedTitle,
            articleTitle: normalizedTitle,
            articleAuthor: normalizeRequiredText(articleAuthor),
            articleURL: normalizedURL,
            summaryText: normalizeOptionalText(summaryText),
            summaryTargetLanguage: normalizeOptionalText(summaryTargetLanguage),
            summaryDetailLevel: summaryDetailLevel,
            noteText: normalizeOptionalText(noteText),
            exportDate: exportDate
        )
    }

    nonisolated static func makeSingleEntryFileSlug(title: String) -> String {
        let normalized = normalizeRequiredText(title)
        guard normalized.isEmpty == false else {
            return fallbackSlug
        }

        var scalars: [UnicodeScalar] = []
        var previousWasHyphen = false

        for scalar in normalized.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if scalar.isASCII {
                    let lowercased = UnicodeScalar(String(scalar).lowercased()) ?? scalar
                    scalars.append(lowercased)
                } else {
                    scalars.append(scalar)
                }
                previousWasHyphen = false
                continue
            }

            if CharacterSet.whitespacesAndNewlines.contains(scalar) || "-_/+:.|".unicodeScalars.contains(scalar) {
                if previousWasHyphen == false, scalars.isEmpty == false {
                    scalars.append("-")
                    previousWasHyphen = true
                }
            }
        }

        var slug = String(String.UnicodeScalarView(scalars))
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.count > maxSlugLength {
            slug = String(slug.prefix(maxSlugLength)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        }

        return slug.isEmpty ? fallbackSlug : slug
    }

    nonisolated static func makeSingleEntryFileName(digestTitle: String, exportDate: Date) -> String {
        let datePrefix = fileDateFormatter.string(from: exportDate)
        let slug = makeSingleEntryFileSlug(title: digestTitle)
        return "\(datePrefix)-\(slug).md"
    }

    nonisolated static func makeMultipleEntryDigestTitle(exportDate: Date) -> String {
        let dateString = multipleEntryDigestTitleDateFormatter.string(from: exportDate)
        return "推荐阅读（\(dateString)）"
    }

    nonisolated static func makeMultipleEntryFileSlug(exportDate: Date) -> String {
        let datePrefix = fileDateFormatter.string(from: exportDate)
        return "\(datePrefix)-\(multipleEntrySlugSuffix)"
    }

    nonisolated static func makeMultipleEntryFileName(exportDate: Date) -> String {
        "\(makeMultipleEntryFileSlug(exportDate: exportDate)).md"
    }

    nonisolated static func makeMultipleEntryMarkdownContent(
        entries: [DigestMultipleEntryMarkdownEntryContent],
        includeSummary: Bool,
        includeNote: Bool,
        exportDate: Date = Date()
    ) -> DigestMultipleEntryMarkdownContent? {
        guard entries.isEmpty == false else {
            return nil
        }

        var normalizedEntries: [DigestMultipleEntryMarkdownEntryContent] = []
        normalizedEntries.reserveCapacity(entries.count)

        for entry in entries {
            let normalizedTitle = normalizeRequiredText(entry.articleTitle)
            let normalizedURL = normalizeRequiredText(entry.articleURL)
            guard normalizedTitle.isEmpty == false, normalizedURL.isEmpty == false else {
                return nil
            }

            normalizedEntries.append(
                DigestMultipleEntryMarkdownEntryContent(
                    articleTitle: normalizedTitle,
                    articleAuthor: normalizeRequiredText(entry.articleAuthor),
                    articleURL: normalizedURL,
                    summaryText: includeSummary ? normalizeOptionalText(entry.summaryText) : nil,
                    noteText: includeNote ? normalizeOptionalText(entry.noteText) : nil
                )
            )
        }

        return DigestMultipleEntryMarkdownContent(
            digestTitle: makeMultipleEntryDigestTitle(exportDate: exportDate),
            fileSlug: makeMultipleEntryFileSlug(exportDate: exportDate),
            entries: normalizedEntries,
            exportDate: exportDate
        )
    }

    nonisolated static func uniqueFileURL(
        in directory: URL,
        preferredFileName: String,
        fileManager: FileManager = .default
    ) -> URL {
        let preferredURL = directory.appendingPathComponent(preferredFileName)
        guard fileManager.fileExists(atPath: preferredURL.path) else {
            return preferredURL
        }

        let fileExtension = preferredURL.pathExtension
        let baseName = preferredURL.deletingPathExtension().lastPathComponent
        var suffix = 2

        while true {
            let candidateName: String
            if fileExtension.isEmpty {
                candidateName = "\(baseName)-\(suffix)"
            } else {
                candidateName = "\(baseName)-\(suffix).\(fileExtension)"
            }

            let candidateURL = directory.appendingPathComponent(candidateName)
            if fileManager.fileExists(atPath: candidateURL.path) == false {
                return candidateURL
            }
            suffix += 1
        }
    }

    nonisolated static func validateExportDirectory(
        _ directory: URL?,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard let directory else {
            throw DigestExportError.exportDirectoryNotConfigured
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw DigestExportError.exportDirectoryInvalid(directory.path)
        }

        return directory
    }

    static func singleEntryTemplateContext(
        _ content: DigestSingleEntryMarkdownContent,
        bundle: Bundle
    ) -> DigestTemplateRenderContext {
        let noteText = content.noteText ?? ""
        let summaryText = content.summaryText ?? ""

        return DigestTemplateRenderContext(
            scalars: [
                "exportDateTimeISO8601": iso8601Formatter.string(from: content.exportDate),
                "digestTitle": content.digestTitle,
                "fileSlug": makeSingleEntryFileSlug(title: content.digestTitle),
                "articleTitle": content.articleTitle,
                "articleAuthor": content.articleAuthor,
                "articleURL": content.articleURL,
                "includeSummary": summaryText.isEmpty ? "" : "true",
                "summaryTextBlockquote": blockquoteBody(summaryText),
                "summaryTargetLanguage": content.summaryTargetLanguage ?? "",
                "summaryDetailLevel": content.summaryDetailLevel?.rawValue ?? "",
                "includeNote": noteText.isEmpty ? "" : "true",
                "noteText": noteText,
                "labelSource": String(localized: "Source", bundle: bundle),
                "labelAuthor": String(localized: "Author", bundle: bundle),
                "labelNote": String(localized: "My Take", bundle: bundle),
                "labelSummaryGeneratedByPrefix": String(localized: "Generated by", bundle: bundle),
                "labelSummaryGeneratedBySuffix": String(localized: "in", bundle: bundle)
            ]
        )
    }

    static func multipleEntryTemplateContext(
        _ content: DigestMultipleEntryMarkdownContent,
        bundle: Bundle
    ) -> DigestTemplateRenderContext {
        let entryContexts = content.entries.map { entry in
            let summaryText = entry.summaryText ?? ""
            let noteText = entry.noteText ?? ""

            return DigestTemplateRenderContext(
                scalars: [
                    "articleTitle": entry.articleTitle,
                    "articleAuthor": entry.articleAuthor,
                    "articleURL": entry.articleURL,
                    "includeSummary": summaryText.isEmpty ? "" : "true",
                    "summaryTextBlockquote": blockquoteBody(summaryText),
                    "includeNote": noteText.isEmpty ? "" : "true",
                    "noteText": noteText,
                    "labelSource": String(localized: "Source", bundle: bundle),
                    "labelAuthor": String(localized: "Author", bundle: bundle),
                    "labelNote": String(localized: "My Take", bundle: bundle)
                ]
            )
        }

        return DigestTemplateRenderContext(
            scalars: [
                "exportDateTimeISO8601": iso8601Formatter.string(from: content.exportDate),
                "digestTitle": content.digestTitle,
                "fileSlug": content.fileSlug
            ],
            repeatedSections: [
                "entries": entryContexts
            ]
        )
    }

    nonisolated static func normalizeMarkdownLayout(_ markdown: String) -> String {
        let normalizedNewlines = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        guard let regex = try? NSRegularExpression(pattern: "\n[ \t]*\n(?:[ \t]*\n)+") else {
            return normalizedNewlines.trimmingCharacters(in: .newlines)
        }

        let range = NSRange(normalizedNewlines.startIndex..<normalizedNewlines.endIndex, in: normalizedNewlines)
        let collapsed = regex.stringByReplacingMatches(
            in: normalizedNewlines,
            options: [],
            range: range,
            withTemplate: "\n\n"
        )
        return collapsed.trimmingCharacters(in: .newlines)
    }

    static func writeMarkdownFile(
        content: String,
        preferredFileName: String,
        directory: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let validatedDirectory = try validateExportDirectory(directory, fileManager: fileManager)
        let targetURL = uniqueFileURL(in: validatedDirectory, preferredFileName: preferredFileName, fileManager: fileManager)

        try SecurityScopedBookmarkStore.access(validatedDirectory) {
            try content.write(to: targetURL, atomically: true, encoding: .utf8)
        }
        return targetURL
    }

    nonisolated private static func blockquoteBody(_ text: String) -> String {
        text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n> ")
    }

    nonisolated private static func normalizeRequiredText(_ text: String?) -> String {
        (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func normalizeOptionalText(_ text: String?) -> String? {
        let normalized = normalizeRequiredText(text)
        return normalized.isEmpty ? nil : normalized
    }
}
