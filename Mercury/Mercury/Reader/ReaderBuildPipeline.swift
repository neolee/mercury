//
//  ReaderBuildPipeline.swift
//  Mercury
//

import Foundation

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
    private let sourceDocumentFetcher: (URL, @escaping ReaderEventSink) async throws -> ReaderFetchedDocument
    private let sourceDocumentLoader: ReaderSourceDocumentLoader?
    private let pipelineResolver: (URL, ReaderFetchedDocument) -> ReaderPipelineResolution
    private let obsidianMarkdownFetcher: ReaderObsidianPipeline.MarkdownFetcher?

    init(
        contentStore: ContentStore,
        entryStore: EntryStore,
        jobRunner: JobRunner,
        sourceDocumentFetcher: ((URL, @escaping ReaderEventSink) async throws -> ReaderFetchedDocument)? = nil,
        pipelineResolver: @escaping (URL, ReaderFetchedDocument) -> ReaderPipelineResolution = ReaderPipelineResolver.resolve,
        obsidianMarkdownFetcher: ReaderObsidianPipeline.MarkdownFetcher? = nil
    ) {
        self.contentStore = contentStore
        self.entryStore = entryStore
        self.jobRunner = jobRunner
        self.pipelineResolver = pipelineResolver
        self.obsidianMarkdownFetcher = obsidianMarkdownFetcher
        if let sourceDocumentFetcher {
            self.sourceDocumentLoader = nil
            self.sourceDocumentFetcher = sourceDocumentFetcher
        } else {
            let sourceDocumentLoader = ReaderSourceDocumentLoader(jobRunner: jobRunner)
            self.sourceDocumentLoader = sourceDocumentLoader
            self.sourceDocumentFetcher = { url, appendEvent in
                try await sourceDocumentLoader.fetch(
                    url: url,
                    appendEvent: appendEvent
                )
            }
        }
    }

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
        let appendEvent: ReaderEventSink = { event in
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
            let content = try await contentStore.content(for: entryId)
            let cached = try await contentStore.cachedHTML(for: entryId, themeId: cacheThemeID)
            let activePipeline = pipeline(for: content?.readerPipelineType ?? .default)
            let action = activePipeline.rebuildAction(
                for: content,
                cachedHTMLVersion: cached?.readerRenderVersion,
                hasCachedHTML: cached != nil
            )

            #if DEBUG
            appendEvent("[pipeline] type=\(activePipeline.type.rawValue)")
            appendEvent("[policy] action=\(action)")
            #endif

            switch action {
            case .serveCachedHTML:
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
                guard let content else {
                    throw ReaderBuildError.emptyContent
                }
                let artifacts = try await activePipeline.buildMarkdownFromIntermediate(
                    content: content,
                    appendEvent: appendEvent
                )
                return try await persistArtifactsAndRender(
                    entryId: entryId,
                    cacheThemeID: cacheThemeID,
                    theme: theme,
                    artifacts: artifacts,
                    didUpgradeEntryURL: false,
                    appendEvent: appendEvent
                )

            case .rerunReadabilityAndRebuild:
                guard let sourceHtml = content?.html, sourceHtml.isEmpty == false else {
                    throw ReaderBuildError.invalidURL
                }
                let preparedArticleURL = await prepareArticleURL(for: entry, appendEvent: appendEvent)
                let didUpgradeEntryURL = preparedArticleURL?.didUpgradeEntryURL ?? false
                guard let content else {
                    throw ReaderBuildError.invalidURL
                }
                let effectiveEntryURL = try resolvedSourceEntryURL(
                    content: content,
                    sourceHTML: sourceHtml,
                    preparedArticleURL: preparedArticleURL,
                    appendEvent: appendEvent
                )
                let artifacts = try await activePipeline.buildMarkdownFromSource(
                    content: content,
                    entryURL: effectiveEntryURL,
                    appendEvent: appendEvent
                )
                return try await persistArtifactsAndRender(
                    entryId: entryId,
                    cacheThemeID: cacheThemeID,
                    theme: theme,
                    artifacts: artifacts,
                    didUpgradeEntryURL: didUpgradeEntryURL,
                    appendEvent: appendEvent
                )

            case .fetchAndRebuildFull:
                guard let articleURL = await prepareArticleURL(for: entry, appendEvent: appendEvent) else {
                    throw ReaderBuildError.invalidURL
                }
                let fetchedDocument = try await sourceDocumentFetcher(articleURL.url, appendEvent)
                let resolution = pipelineResolver(articleURL.url, fetchedDocument)

                #if DEBUG
                appendEvent("[resolve] pipeline=\(resolution.pipelineType.rawValue)")
                #endif

                let resolvedBaseURL = DocumentBaseURLResolver.resolve(
                    html: fetchedDocument.html,
                    responseURL: fetchedDocument.responseURL,
                    fallbackURL: articleURL.url
                )
                if let resolvedBaseURL {
                    appendEvent("[base-url] source=\(resolvedBaseURL.source)")
                }

                var contentWithSource = content ?? makeEmptyContent(entryId: entryId)
                contentWithSource.html = fetchedDocument.html
                contentWithSource.documentBaseURL = resolvedBaseURL?.isPersistable == true
                    ? resolvedBaseURL?.url.absoluteString
                    : nil
                contentWithSource.pipelineType = resolution.pipelineType.rawValue
                contentWithSource.resolvedIntermediateContent = resolution.resolvedIntermediateContent
                contentWithSource = try await contentStore.upsert(contentWithSource)

                let resolvedPipeline = pipeline(for: resolution.pipelineType)
                let artifacts: ReaderPipelineBuildArtifacts
                if let resolvedIntermediateContent = resolution.resolvedIntermediateContent,
                   resolvedIntermediateContent.isEmpty == false {
                    artifacts = try await resolvedPipeline.buildMarkdownFromIntermediate(
                        content: contentWithSource,
                        appendEvent: appendEvent
                    )
                } else {
                    artifacts = try await resolvedPipeline.buildMarkdownFromSource(
                        content: contentWithSource,
                        entryURL: articleURL.url,
                        appendEvent: appendEvent
                    )
                }

                return try await persistArtifactsAndRender(
                    entryId: entryId,
                    cacheThemeID: cacheThemeID,
                    theme: theme,
                    artifacts: artifacts,
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
        appendEvent: ReaderEventSink? = nil
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
    private func pipeline(for type: ReaderPipelineType) -> any ReaderPipeline {
        type.makePipeline(
            jobRunner: jobRunner,
            obsidianMarkdownFetcher: obsidianMarkdownFetcher
        )
    }

    private func persistedDocumentBaseURL(from content: Content?) -> URL? {
        guard let value = content?.documentBaseURL else {
            return nil
        }
        return URL(string: value)
    }

    private func makeEmptyContent(entryId: Int64) -> Content {
        Content(
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
            createdAt: Date(),
            documentBaseURL: nil
        )
    }

    private func resolvedSourceEntryURL(
        content: Content,
        sourceHTML: String,
        preparedArticleURL: ReaderArticleURLPreparation?,
        appendEvent: @escaping ReaderEventSink
    ) throws -> URL {
        if let preparedArticleURL {
            return preparedArticleURL.url
        }

        if let persistedBaseURL = persistedDocumentBaseURL(from: content) {
            appendEvent("[base-url] using persisted document base URL")
            return persistedBaseURL
        }

        if let trustedStoredBaseURL = DocumentBaseURLResolver.trustedPersistedBaseURL(from: sourceHTML) {
            appendEvent("[base-url] backfilled trusted <base href> from stored HTML")
            return trustedStoredBaseURL
        }

        throw ReaderBuildError.invalidURL
    }

    @MainActor
    private func persistArtifactsAndRender(
        entryId: Int64,
        cacheThemeID: String,
        theme: EffectiveReaderTheme,
        artifacts: ReaderPipelineBuildArtifacts,
        didUpgradeEntryURL: Bool,
        appendEvent: @escaping ReaderEventSink
    ) async throws -> ReaderBuildPipelineOutput {
        var updatedContent = artifacts.content
        updatedContent.entryId = entryId
        updatedContent = try await contentStore.upsert(updatedContent)

        #if DEBUG
        appendEvent("[markdown] persisted")
        #endif

        let renderedHTML = try ReaderHTMLRenderer.render(markdown: artifacts.markdown, theme: theme)
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
            result: ReaderBuildResult(
                html: renderedHTML,
                errorMessage: nil,
                didUpgradeEntryURL: didUpgradeEntryURL
            ),
            debugDetail: nil
        )
    }
}
