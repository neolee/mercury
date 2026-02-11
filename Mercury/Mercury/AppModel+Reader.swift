//
//  AppModel+Reader.swift
//  Mercury
//

import Foundation
import Readability

extension AppModel {
    func readerBuildResult(for entry: Entry, themeId: String) async -> ReaderBuildResult {
        guard let entryId = entry.id else {
            return ReaderBuildResult(html: nil, errorMessage: "Missing entry ID")
        }

        var lastEvents: [String] = []
        func appendEvent(_ event: String) {
            lastEvents.append(event)
            if lastEvents.count > 10 {
                lastEvents.removeFirst(lastEvents.count - 10)
            }
        }

        do {
            if let cached = try await contentStore.cachedHTML(for: entryId, themeId: themeId) {
                return ReaderBuildResult(html: cached.html, errorMessage: nil)
            }

            let content = try await contentStore.content(for: entryId)
            if let markdown = content?.markdown, markdown.isEmpty == false {
                let html = try ReaderHTMLRenderer.render(markdown: markdown, themeId: themeId)
                try await contentStore.upsertCache(entryId: entryId, themeId: themeId, html: html)
                return ReaderBuildResult(html: html, errorMessage: nil)
            }

            guard let urlString = entry.url, let url = URL(string: urlString) else {
                throw ReaderBuildError.invalidURL
            }

            let fetchedHTML = try await jobRunner.run(label: "fetchHTML", timeout: 12, onEvent: { event in
                Task { @MainActor in
                    appendEvent("[\(event.label)] \(event.message)")
                }
            }) { report in
                let (data, _) = try await URLSession.shared.data(from: url)
                if let html = String(data: data, encoding: .utf8) {
                    report("decoded")
                    return html
                }
                report("decoded")
                return String(decoding: data, as: UTF8.self)
            }

            let result = try await jobRunner.run(label: "readability", timeout: 12, onEvent: { event in
                Task { @MainActor in
                    appendEvent("[\(event.label)] \(event.message)")
                }
            }) { report in
                let readability = try Readability(html: fetchedHTML, baseURL: url)
                let result = try readability.parse()
                report("parsed")
                return result
            }

            let generatedMarkdown = try ReaderMarkdownConverter.markdownFromReadability(result)
            if generatedMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ReaderBuildError.emptyContent
            }

            var updatedContent = content ?? Content(
                id: nil,
                entryId: entryId,
                html: nil,
                markdown: nil,
                displayMode: ContentDisplayMode.cleaned.rawValue,
                createdAt: Date()
            )
            updatedContent.html = fetchedHTML
            updatedContent.markdown = generatedMarkdown
            try await contentStore.upsert(updatedContent)

            let renderedHTML = try ReaderHTMLRenderer.render(markdown: generatedMarkdown, themeId: themeId)
            try await contentStore.upsertCache(entryId: entryId, themeId: themeId, html: renderedHTML)

            return ReaderBuildResult(html: renderedHTML, errorMessage: nil)
        } catch {
            let message: String
            switch error {
            case ReaderBuildError.timeout(let stage):
                message = "Timeout: \(stage)"
            case JobError.timeout(let label):
                message = "Timeout: \(label)"
            case ReaderBuildError.invalidURL:
                message = "Invalid URL"
            case ReaderBuildError.emptyContent:
                message = "Clean content is empty"
            default:
                message = error.localizedDescription
            }

            reportDebugIssue(
                title: "Reader Build Failure",
                detail: [
                    "Entry ID: \(entryId)",
                    "URL: \(entry.url ?? "(missing)")",
                    "Error: \(message)",
                    "Recent Events:",
                    lastEvents.isEmpty ? "(none)" : lastEvents.joined(separator: "\n")
                ].joined(separator: "\n"),
                category: .reader
            )
            return ReaderBuildResult(html: nil, errorMessage: message)
        }
    }
}
