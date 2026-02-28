//
//  ReaderBuildUseCase.swift
//  Mercury
//

import Foundation
import Readability

struct ReaderBuildUseCaseOutput {
    let result: ReaderBuildResult
    let debugDetail: String?
}

struct ReaderBuildUseCase {
    let contentStore: ContentStore
    let jobRunner: JobRunner

    @MainActor
    func run(for entry: Entry, theme: EffectiveReaderTheme) async -> ReaderBuildUseCaseOutput {
        guard let entryId = entry.id else {
            return ReaderBuildUseCaseOutput(
                result: ReaderBuildResult(html: nil, errorMessage: "Missing entry ID"),
                debugDetail: nil
            )
        }

        let cacheThemeID = theme.cacheThemeID
        let cacheThemeKey = "\(theme.presetID.rawValue).\(theme.variant.rawValue)#\(theme.overrideHash)"

        var lastEvents: [String] = []
        func appendEvent(_ event: String) {
            lastEvents.append(event)
            if lastEvents.count > 10 {
                lastEvents.removeFirst(lastEvents.count - 10)
            }
        }

        #if DEBUG
        _ = theme.debugAssertCacheIdentity()
        appendEvent("[theme] cacheKey=\(cacheThemeKey)")
        #endif

        do {
            if let cached = try await contentStore.cachedHTML(for: entryId, themeId: cacheThemeID) {
                #if DEBUG
                appendEvent("[cache] hit")
                #endif
                return ReaderBuildUseCaseOutput(
                    result: ReaderBuildResult(html: cached.html, errorMessage: nil),
                    debugDetail: nil
                )
            }

            #if DEBUG
            appendEvent("[cache] miss")
            #endif

            let content = try await contentStore.content(for: entryId)
            if let markdown = content?.markdown, markdown.isEmpty == false {
                let html = try ReaderHTMLRenderer.render(markdown: markdown, theme: theme)
                try await contentStore.upsertCache(entryId: entryId, themeId: cacheThemeID, html: html)
                #if DEBUG
                appendEvent("[cache] wrote-from-markdown")
                #endif
                return ReaderBuildUseCaseOutput(
                    result: ReaderBuildResult(html: html, errorMessage: nil),
                    debugDetail: nil
                )
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

            let generatedMarkdown = try MarkdownConverter.markdownFromReadability(result)
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

            let renderedHTML = try ReaderHTMLRenderer.render(markdown: generatedMarkdown, theme: theme)
            try await contentStore.upsertCache(entryId: entryId, themeId: cacheThemeID, html: renderedHTML)
            #if DEBUG
            appendEvent("[cache] wrote-from-readability")
            #endif

            return ReaderBuildUseCaseOutput(
                result: ReaderBuildResult(html: renderedHTML, errorMessage: nil),
                debugDetail: nil
            )
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

            let debugDetail = [
                "Entry ID: \(entryId)",
                "URL: \(entry.url ?? "(missing)")",
                "Error: \(message)",
                "Recent Events:",
                lastEvents.isEmpty ? "(none)" : lastEvents.joined(separator: "\n")
            ].joined(separator: "\n")

            return ReaderBuildUseCaseOutput(
                result: ReaderBuildResult(html: nil, errorMessage: message),
                debugDetail: debugDetail
            )
        }
    }
}
