//
//  ReaderBuildPipeline.swift
//  Mercury
//

import Foundation
import Readability

private final class ReaderFetchRedirectDelegate: NSObject, URLSessionTaskDelegate {
    private let onUpgrade: @Sendable (URL, URL) -> Void

    init(onUpgrade: @escaping @Sendable (URL, URL) -> Void) {
        self.onUpgrade = onUpgrade
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let originalURL = task.currentRequest?.url ?? task.originalRequest?.url
        guard let upgradedRequest = ReaderFetchRedirectPolicy.upgradedRedirectRequest(
            originalURL: originalURL,
            redirectRequest: request
        ) else {
            completionHandler(request)
            return
        }

        if let redirectURL = request.url, let upgradedURL = upgradedRequest.url {
            onUpgrade(redirectURL, upgradedURL)
        }
        completionHandler(upgradedRequest)
    }
}

struct ReaderBuildPipelineOutput {
    let result: ReaderBuildResult
    let debugDetail: String?
}

struct ReaderArticleURLPreparation {
    let url: URL
    let didUpgradeEntryURL: Bool
}

struct ReaderBuildPipeline {
    let contentStore: ContentStore
    let entryStore: EntryStore
    let jobRunner: JobRunner

    @MainActor
    func run(for entry: Entry, theme: EffectiveReaderTheme) async -> ReaderBuildPipelineOutput {
        guard let entryId = entry.id else {
            return ReaderBuildPipelineOutput(
                result: ReaderBuildResult(html: nil, errorMessage: "Missing entry ID"),
                debugDetail: nil
            )
        }

        let cacheThemeID = theme.cacheThemeID

        var lastEvents: [String] = []
        func appendEvent(_ event: String) {
            lastEvents.append(event)
            if lastEvents.count > 10 {
                lastEvents.removeFirst(lastEvents.count - 10)
            }
        }

        #if DEBUG
        _ = theme.debugAssertCacheIdentity()
        let cacheThemeKey = "\(theme.presetID.rawValue).\(theme.variant.rawValue)#\(theme.overrideHash)"
        appendEvent("[theme] cacheKey=\(cacheThemeKey)")
        #endif

        do {
            let layerState = try await contentStore.layerState(for: entryId, themeId: cacheThemeID)
            let action = ReaderRebuildPolicy.action(for: layerState)

            #if DEBUG
            appendEvent("[policy] action=\(action)")
            #endif

            switch action {
            case .serveCachedHTML:
                let cached = try await contentStore.cachedHTML(for: entryId, themeId: cacheThemeID)
                if let cached {
                    #if DEBUG
                    appendEvent("[cache] served")
                    #endif
                    return ReaderBuildPipelineOutput(
                        result: ReaderBuildResult(html: cached.html, errorMessage: nil),
                        debugDetail: nil
                    )
                }
                fallthrough

            case .rerenderFromMarkdown:
                let content = try await contentStore.content(for: entryId)
                guard let markdown = content?.markdown, markdown.isEmpty == false else {
                    throw ReaderBuildError.emptyContent
                }
                let renderedHTML = try ReaderHTMLRenderer.render(markdown: markdown, theme: theme)
                try await contentStore.upsertCache(
                    entryId: entryId,
                    themeId: cacheThemeID,
                    html: renderedHTML,
                    readerRenderVersion: ReaderPipelineVersion.readerRender
                )
                #if DEBUG
                appendEvent("[cache] wrote-from-markdown")
                #endif
                return ReaderBuildPipelineOutput(
                    result: ReaderBuildResult(html: renderedHTML, errorMessage: nil),
                    debugDetail: nil
                )

            case .rebuildMarkdownAndRender:
                let content = try await contentStore.content(for: entryId)
                guard let cleanedHtml = content?.cleanedHtml, cleanedHtml.isEmpty == false else {
                    throw ReaderBuildError.emptyContent
                }
                let readabilityTitle = content?.readabilityTitle
                let readabilityByline = content?.readabilityByline
                return try await buildMarkdownAndRender(
                    entryId: entryId,
                    cacheThemeID: cacheThemeID,
                    theme: theme,
                    existingContent: content,
                    cleanedHtml: cleanedHtml,
                    readabilityTitle: readabilityTitle,
                    readabilityByline: readabilityByline,
                    didUpgradeEntryURL: false,
                    appendEvent: appendEvent
                )

            case .rerunReadabilityAndRebuild:
                let content = try await contentStore.content(for: entryId)
                guard let sourceHtml = content?.html, sourceHtml.isEmpty == false,
                      let articleURL = await prepareArticleURL(for: entry, appendEvent: appendEvent) else {
                    throw ReaderBuildError.invalidURL
                }
                return try await runReadabilityAndRebuild(
                    entryId: entryId,
                    cacheThemeID: cacheThemeID,
                    theme: theme,
                    existingContent: content,
                    sourceHtml: sourceHtml,
                    baseURL: articleURL.url,
                    didUpgradeEntryURL: articleURL.didUpgradeEntryURL,
                    appendEvent: appendEvent
                )

            case .fetchAndRebuildFull:
                guard let articleURL = await prepareArticleURL(for: entry, appendEvent: appendEvent) else {
                    throw ReaderBuildError.invalidURL
                }
                let content = try await contentStore.content(for: entryId)
                let fetchedHTML = try await fetchSourceHTML(url: articleURL.url, appendEvent: appendEvent)

                var contentWithSource = content ?? Content(
                    id: nil,
                    entryId: entryId,
                    html: nil,
                    cleanedHtml: nil,
                    readabilityTitle: nil,
                    readabilityByline: nil,
                    readabilityVersion: nil,
                    markdown: nil,
                    markdownVersion: nil,
                    displayMode: ContentDisplayMode.cleaned.rawValue,
                    createdAt: Date()
                )
                contentWithSource.html = fetchedHTML
                contentWithSource = try await contentStore.upsert(contentWithSource)

                return try await runReadabilityAndRebuild(
                    entryId: entryId,
                    cacheThemeID: cacheThemeID,
                    theme: theme,
                    existingContent: contentWithSource,
                    sourceHtml: fetchedHTML,
                    baseURL: articleURL.url,
                    didUpgradeEntryURL: articleURL.didUpgradeEntryURL,
                    appendEvent: appendEvent
                )
            }
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

            return ReaderBuildPipelineOutput(
                result: ReaderBuildResult(html: nil, errorMessage: message),
                debugDetail: debugDetail
            )
        }
    }

    @MainActor
    func prepareArticleURL(
        for entry: Entry,
        appendEvent: ((String) -> Void)? = nil
    ) async -> ReaderArticleURLPreparation? {
        guard let urlString = entry.url,
              let originalURL = URL(string: urlString) else {
            return nil
        }

        let preferredURL = URLHTTPSUpgrade.preferredHTTPSURL(from: originalURL)
        let preferredURLString = preferredURL.absoluteString
        guard preferredURLString != urlString else {
            return ReaderArticleURLPreparation(url: preferredURL, didUpgradeEntryURL: false)
        }

        appendEvent?("[url] preferred \(urlString) -> \(preferredURLString)")

        guard let entryId = entry.id else {
            return ReaderArticleURLPreparation(url: preferredURL, didUpgradeEntryURL: false)
        }

        do {
            try await entryStore.updateURL(entryId: entryId, url: preferredURLString)
            appendEvent?("[entry] url upgraded")
            return ReaderArticleURLPreparation(url: preferredURL, didUpgradeEntryURL: true)
        } catch {
            appendEvent?("[entry] url upgrade persist failed: \(error.localizedDescription)")
            return ReaderArticleURLPreparation(url: preferredURL, didUpgradeEntryURL: false)
        }
    }

    // MARK: - Private helpers

    @MainActor
    private func fetchSourceHTML(url: URL, appendEvent: @escaping (String) -> Void) async throws -> String {
        try await jobRunner.run(label: "fetchHTML", timeout: 12, onEvent: { event in
            Task { @MainActor in appendEvent("[\(event.label)] \(event.message)") }
        }) { report in
            let delegate = ReaderFetchRedirectDelegate { redirectURL, upgradedURL in
                Task { @MainActor in
                    appendEvent("[redirect] upgraded \(redirectURL.absoluteString) -> \(upgradedURL.absoluteString)")
                }
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            defer { session.invalidateAndCancel() }

            let (data, _) = try await session.data(from: url)
            report("decoded")
            if let html = String(data: data, encoding: .utf8) {
                return html
            }
            return String(decoding: data, as: UTF8.self)
        }
    }

    @MainActor
    private func runReadabilityAndRebuild(
        entryId: Int64,
        cacheThemeID: String,
        theme: EffectiveReaderTheme,
        existingContent: Content?,
        sourceHtml: String,
        baseURL: URL,
        didUpgradeEntryURL: Bool,
        appendEvent: @escaping (String) -> Void
    ) async throws -> ReaderBuildPipelineOutput {
        let readabilityResult = try await jobRunner.run(
            label: "readability",
            timeout: 12,
            onEvent: { event in Task { @MainActor in appendEvent("[\(event.label)] \(event.message)") } }
        ) { report in
            let readability = try Readability(html: sourceHtml, baseURL: baseURL)
            let result = try readability.parse()
            report("parsed")
            return result
        }

        let cleanedHtml = readabilityResult.content
        let readabilityTitle = readabilityResult.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let readabilityByline = readabilityResult.byline?.trimmingCharacters(in: .whitespacesAndNewlines)

        var updatedContent = existingContent ?? Content(
            id: nil,
            entryId: entryId,
            html: nil,
            cleanedHtml: nil,
            readabilityTitle: nil,
            readabilityByline: nil,
            readabilityVersion: nil,
            markdown: nil,
            markdownVersion: nil,
            displayMode: ContentDisplayMode.cleaned.rawValue,
            createdAt: Date()
        )
        updatedContent.cleanedHtml = cleanedHtml
        updatedContent.readabilityTitle = readabilityTitle.isEmpty ? nil : readabilityTitle
        updatedContent.readabilityByline = readabilityByline?.isEmpty == false ? readabilityByline : nil
        updatedContent.readabilityVersion = ReaderPipelineVersion.readability
        updatedContent = try await contentStore.upsert(updatedContent)

        #if DEBUG
        appendEvent("[readability] cleaned-html persisted")
        #endif

        return try await buildMarkdownAndRender(
            entryId: entryId,
            cacheThemeID: cacheThemeID,
            theme: theme,
            existingContent: updatedContent,
            cleanedHtml: cleanedHtml,
            readabilityTitle: updatedContent.readabilityTitle,
            readabilityByline: updatedContent.readabilityByline,
            didUpgradeEntryURL: didUpgradeEntryURL,
            appendEvent: appendEvent
        )
    }

    @MainActor
    private func buildMarkdownAndRender(
        entryId: Int64,
        cacheThemeID: String,
        theme: EffectiveReaderTheme,
        existingContent: Content?,
        cleanedHtml: String,
        readabilityTitle: String?,
        readabilityByline: String?,
        didUpgradeEntryURL: Bool,
        appendEvent: @escaping (String) -> Void
    ) async throws -> ReaderBuildPipelineOutput {
        let generatedMarkdown = try MarkdownConverter.markdownFromPersisted(
            contentHTML: cleanedHtml,
            title: readabilityTitle,
            byline: readabilityByline
        )
        if generatedMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ReaderBuildError.emptyContent
        }

        var updatedContent = existingContent ?? Content(
            id: nil,
            entryId: entryId,
            html: nil,
            cleanedHtml: nil,
            readabilityTitle: nil,
            readabilityByline: nil,
            readabilityVersion: nil,
            markdown: nil,
            markdownVersion: nil,
            displayMode: ContentDisplayMode.cleaned.rawValue,
            createdAt: Date()
        )
        updatedContent.markdown = generatedMarkdown
        updatedContent.markdownVersion = ReaderPipelineVersion.markdown
        updatedContent = try await contentStore.upsert(updatedContent)

        #if DEBUG
        appendEvent("[markdown] persisted")
        #endif

        let renderedHTML = try ReaderHTMLRenderer.render(markdown: generatedMarkdown, theme: theme)
        try await contentStore.upsertCache(
            entryId: entryId,
            themeId: cacheThemeID,
            html: renderedHTML,
            readerRenderVersion: ReaderPipelineVersion.readerRender
        )

        #if DEBUG
        appendEvent("[cache] wrote-from-cleaned-html")
        #endif

        return ReaderBuildPipelineOutput(
            result: ReaderBuildResult(
                html: renderedHTML,
                errorMessage: nil,
                didUpgradeEntryURL: didUpgradeEntryURL
            ),
            debugDetail: nil
        )
    }
}
