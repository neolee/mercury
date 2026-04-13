import Foundation

struct ReaderPipelineBuildArtifacts: Sendable {
    let content: Content
    let markdown: String
}

protocol ReaderPipeline {
    var type: ReaderPipelineType { get }

    func rebuildAction(
        for content: Content?,
        cachedHTMLVersion: Int?,
        hasCachedHTML: Bool
    ) -> ReaderRebuildAction

    @MainActor
    func buildMarkdownFromSource(
        content: Content,
        entryURL: URL,
        appendEvent: @escaping (String) -> Void
    ) async throws -> ReaderPipelineBuildArtifacts

    @MainActor
    func buildMarkdownFromIntermediate(
        content: Content,
        appendEvent: @escaping (String) -> Void
    ) async throws -> ReaderPipelineBuildArtifacts
}

extension Content {
    var readerPipelineType: ReaderPipelineType {
        ReaderPipelineType(rawValue: pipelineType) ?? .default
    }
}

extension ReaderPipelineType {
    @MainActor
    func makePipeline(
        jobRunner: JobRunner,
        obsidianMarkdownFetcher: ReaderObsidianPipeline.MarkdownFetcher? = nil
    ) -> any ReaderPipeline {
        switch self {
        case .default:
            return ReaderDefaultPipeline(jobRunner: jobRunner)
        case .obsidian:
            if let obsidianMarkdownFetcher {
                return ReaderObsidianPipeline(markdownFetcher: obsidianMarkdownFetcher)
            }
            return ReaderObsidianPipeline()
        }
    }
}
