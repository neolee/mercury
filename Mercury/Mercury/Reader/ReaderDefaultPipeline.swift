import Foundation
import Readability

struct ReaderDefaultPipeline: ReaderPipeline {
    private struct BaseURLResolution {
        let url: URL
        let persistedValue: String?
    }

    let jobRunner: JobRunner

    var type: ReaderPipelineType { .default }

    func rebuildAction(
        for content: Content?,
        cachedHTMLVersion: Int?,
        hasCachedHTML: Bool
    ) -> ReaderRebuildAction {
        let state = ReaderLayerState(
            readabilityVersion: content?.readabilityVersion,
            markdownVersion: content?.markdownVersion,
            cachedHTMLVersion: cachedHTMLVersion,
            hasCleanedHtml: content?.cleanedHtml?.isEmpty == false,
            hasMarkdown: content?.markdown?.isEmpty == false,
            hasSourceHtml: content?.html?.isEmpty == false,
            hasCachedHTML: hasCachedHTML
        )
        return ReaderRebuildPolicy.action(for: state)
    }

    @MainActor
    func buildMarkdownFromSource(
        content: Content,
        entryURL: URL,
        appendEvent: @escaping (String) -> Void
    ) async throws -> ReaderPipelineBuildArtifacts {
        guard let sourceHTML = content.html, sourceHTML.isEmpty == false else {
            throw ReaderBuildError.invalidURL
        }

        let baseURL = try resolveBaseURL(content: content, sourceHTML: sourceHTML, entryURL: entryURL)
        let readabilityResult = try await jobRunner.run(
            label: "readability",
            timeout: 12,
            onEvent: { event in Task { @MainActor in appendEvent("[\(event.label)] \(event.message)") } }
        ) { report in
            let readability = try Readability(html: sourceHTML, baseURL: baseURL.url)
            let result = try readability.parse()
            report("parsed")
            return result
        }

        var updatedContent = content
        updatedContent.documentBaseURL = baseURL.persistedValue
        let cleanedHTML = readabilityResult.content
        let readabilityTitle = readabilityResult.title.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let readabilityByline = readabilityResult.byline?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        updatedContent.pipelineType = ReaderPipelineType.default.rawValue
        updatedContent.resolvedIntermediateContent = nil
        updatedContent.cleanedHtml = cleanedHTML
        updatedContent.readabilityTitle = readabilityTitle.isEmpty ? nil : readabilityTitle
        updatedContent.readabilityByline = readabilityByline?.isEmpty == false ? readabilityByline : nil
        updatedContent.readabilityVersion = ReaderPipelineVersion.readability

        appendEvent("[readability] cleaned-html prepared")
        return try await buildMarkdownFromIntermediate(content: updatedContent, appendEvent: appendEvent)
    }

    @MainActor
    func buildMarkdownFromIntermediate(
        content: Content,
        appendEvent: @escaping (String) -> Void
    ) async throws -> ReaderPipelineBuildArtifacts {
        guard let cleanedHTML = content.cleanedHtml, cleanedHTML.isEmpty == false else {
            throw ReaderBuildError.emptyContent
        }

        let markdown = try MarkdownConverter.markdownFromPersisted(
            contentHTML: cleanedHTML,
            title: content.readabilityTitle,
            byline: content.readabilityByline
        )
        guard markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw ReaderBuildError.emptyContent
        }

        var updatedContent = content
        updatedContent.pipelineType = ReaderPipelineType.default.rawValue
        updatedContent.resolvedIntermediateContent = nil
        updatedContent.markdown = markdown
        updatedContent.markdownVersion = ReaderPipelineVersion.markdown

        appendEvent("[markdown] prepared-from-cleaned-html")
        return ReaderPipelineBuildArtifacts(content: updatedContent, markdown: markdown)
    }

    private func resolveBaseURL(content: Content, sourceHTML: String, entryURL: URL) throws -> BaseURLResolution {
        if let persistedBaseURL = content.documentBaseURL.flatMap(URL.init(string:)) {
            return BaseURLResolution(
                url: persistedBaseURL,
                persistedValue: persistedBaseURL.absoluteString
            )
        }

        if let trustedStoredBaseURL = DocumentBaseURLResolver.trustedPersistedBaseURL(from: sourceHTML) {
            return BaseURLResolution(
                url: trustedStoredBaseURL,
                persistedValue: trustedStoredBaseURL.absoluteString
            )
        }

        if let fallbackResolved = DocumentBaseURLResolver.resolve(
            html: sourceHTML,
            responseURL: nil,
            fallbackURL: entryURL
        )?.url {
            return BaseURLResolution(url: fallbackResolved, persistedValue: nil)
        }

        throw ReaderBuildError.invalidURL
    }
}
