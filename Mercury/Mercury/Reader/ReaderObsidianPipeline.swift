import Foundation

struct ReaderObsidianPipeline: ReaderPipeline {
    typealias MarkdownFetcher = @Sendable (URL) async throws -> String
    typealias ResourceIndexFetcher = @Sendable (URL) async throws -> Set<String>

    private struct PublishContext {
        let accessRootURL: URL
        let cacheIndexURL: URL
    }

    private struct EmbedReference {
        let originalMarkup: String
        let target: String
        let label: String?
        let isImage: Bool
    }

    let markdownFetcher: MarkdownFetcher
    let resourceIndexFetcher: ResourceIndexFetcher

    init() {
        self.init(
            markdownFetcher: Self.fetchMarkdown,
            resourceIndexFetcher: Self.fetchResourceIndex
        )
    }

    init(markdownFetcher: @escaping MarkdownFetcher) {
        self.init(
            markdownFetcher: markdownFetcher,
            resourceIndexFetcher: Self.fetchResourceIndex
        )
    }

    init(
        markdownFetcher: @escaping MarkdownFetcher,
        resourceIndexFetcher: @escaping ResourceIndexFetcher
    ) {
        self.markdownFetcher = markdownFetcher
        self.resourceIndexFetcher = resourceIndexFetcher
    }

    var type: ReaderPipelineType { .obsidian }

    func rebuildAction(
        for content: Content?,
        cachedHTMLVersion: Int?,
        hasCachedHTML: Bool
    ) -> ReaderRebuildAction {
        let hasIntermediate = content?.resolvedIntermediateContent?.isEmpty == false
        let hasMarkdown = content?.markdown?.isEmpty == false
        let markdownCurrent = hasIntermediate && hasMarkdown &&
            content?.markdownVersion == ReaderPipelineVersion.markdown
        let renderedHTMLCurrent = markdownCurrent &&
            hasCachedHTML &&
            cachedHTMLVersion == ReaderPipelineVersion.readerRender

        if renderedHTMLCurrent {
            return .serveCachedHTML
        }

        if markdownCurrent {
            return .rerenderFromMarkdown
        }

        if hasIntermediate {
            return .rebuildMarkdownAndRender
        }

        if content?.html?.isEmpty == false {
            return .rerunReadabilityAndRebuild
        }

        return .fetchAndRebuildFull
    }

    @MainActor
    func buildMarkdownFromSource(
        content: Content,
        entryURL: URL,
        appendEvent: @escaping ReaderEventSink
    ) async throws -> ReaderPipelineBuildArtifacts {
        guard let sourceHTML = content.html, sourceHTML.isEmpty == false else {
            throw ReaderBuildError.invalidURL
        }

        let resolution = ReaderPipelineResolver.resolve(
            entryURL: entryURL,
            fetchedDocument: ReaderFetchedDocument(
                html: sourceHTML,
                responseURL: nil
            )
        )
        guard resolution.pipelineType == .obsidian,
              let resolvedIntermediateContent = resolution.resolvedIntermediateContent,
              resolvedIntermediateContent.isEmpty == false else {
            throw ReaderBuildError.emptyContent
        }

        var updatedContent = content
        updatedContent.pipelineType = ReaderPipelineType.obsidian.rawValue
        updatedContent.resolvedIntermediateContent = resolvedIntermediateContent
        updatedContent.cleanedHtml = nil
        updatedContent.readabilityTitle = nil
        updatedContent.readabilityByline = nil
        updatedContent.readabilityVersion = nil

        appendEvent("[obsidian] resolved markdown URL")
        return try await buildMarkdownFromIntermediate(content: updatedContent, appendEvent: appendEvent)
    }

    @MainActor
    func buildMarkdownFromIntermediate(
        content: Content,
        appendEvent: @escaping ReaderEventSink
    ) async throws -> ReaderPipelineBuildArtifacts {
        guard let intermediate = content.resolvedIntermediateContent,
              intermediate.isEmpty == false,
              let markdownURL = URL(string: intermediate) else {
            throw ReaderBuildError.invalidURL
        }

        let markdown = try await markdownFetcher(markdownURL)
        guard markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw ReaderBuildError.emptyContent
        }
        let normalizedMarkdown = await normalizeEmbeddedMediaIfNeeded(
            in: markdown,
            markdownURL: markdownURL,
            appendEvent: appendEvent
        )

        var updatedContent = content
        updatedContent.pipelineType = ReaderPipelineType.obsidian.rawValue
        updatedContent.cleanedHtml = nil
        updatedContent.readabilityTitle = nil
        updatedContent.readabilityByline = nil
        updatedContent.readabilityVersion = nil
        updatedContent.markdown = normalizedMarkdown
        updatedContent.markdownVersion = ReaderPipelineVersion.markdown

        appendEvent("[obsidian] fetched markdown content")
        return ReaderPipelineBuildArtifacts(content: updatedContent, markdown: normalizedMarkdown)
    }

    @MainActor
    private func normalizeEmbeddedMediaIfNeeded(
        in markdown: String,
        markdownURL: URL,
        appendEvent: @escaping ReaderEventSink
    ) async -> String {
        let embedReferences = Self.embeddedMediaReferences(in: markdown)
        guard embedReferences.isEmpty == false else {
            return markdown
        }

        guard let context = Self.publishContext(for: markdownURL) else {
            appendEvent("[obsidian] unable to derive publish context; preserving embeds")
            return markdown
        }

        let resourceIndex: Set<String>
        do {
            resourceIndex = try await resourceIndexFetcher(context.cacheIndexURL)
        } catch {
            appendEvent("[obsidian] failed to fetch resource index; preserving embeds")
            return markdown
        }

        let rewriteResult = Self.rewriteEmbeddedMedia(
            in: markdown,
            embeds: embedReferences,
            accessRootURL: context.accessRootURL,
            resourceIndex: resourceIndex
        )
        if rewriteResult.rewrittenCount > 0 {
            appendEvent("[obsidian] rewrote \(rewriteResult.rewrittenCount) embedded media reference(s)")
        }
        return rewriteResult.markdown
    }

    private static func publishContext(for markdownURL: URL) -> PublishContext? {
        guard let scheme = markdownURL.scheme,
              let host = markdownURL.host else {
            return nil
        }

        let pathComponents = markdownURL.path.split(separator: "/").map(String.init)
        guard pathComponents.count >= 2,
              pathComponents[0] == "access" else {
            return nil
        }

        let uid = pathComponents[1]
        var rootComponents = URLComponents()
        rootComponents.scheme = scheme
        rootComponents.host = host
        rootComponents.port = markdownURL.port
        guard let rootURL = rootComponents.url else {
            return nil
        }

        let accessRootURL = rootURL
            .appendingPathComponent("access")
            .appendingPathComponent(uid, isDirectory: true)
        let cacheIndexURL = rootURL
            .appendingPathComponent("cache")
            .appendingPathComponent(uid)

        return PublishContext(accessRootURL: accessRootURL, cacheIndexURL: cacheIndexURL)
    }

    private static func embeddedMediaReferences(in markdown: String) -> [EmbedReference] {
        let pattern = #"!\[\[([^\]\n]+)\]\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let nsMarkdown = markdown as NSString
        return regex.matches(in: markdown, range: NSRange(location: 0, length: nsMarkdown.length)).compactMap { match in
            guard match.numberOfRanges == 2,
                  let fullRange = Range(match.range(at: 0), in: markdown),
                  let targetRange = Range(match.range(at: 1), in: markdown) else {
                return nil
            }

            let rawTarget = String(markdown[targetRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard rawTarget.isEmpty == false else {
                return nil
            }

            let components = rawTarget.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            let targetComponent = String(components[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let labelComponent: String?
            if components.count > 1 {
                let candidate = String(components[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                labelComponent = candidate.isEmpty ? nil : candidate
            } else {
                labelComponent = nil
            }

            let targetWithoutAnchor = String(
                targetComponent.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard targetWithoutAnchor.isEmpty == false,
                  isLikelyMediaReference(targetWithoutAnchor) else {
                return nil
            }

            return EmbedReference(
                originalMarkup: String(markdown[fullRange]),
                target: targetWithoutAnchor,
                label: labelComponent,
                isImage: isLikelyImageReference(targetWithoutAnchor)
            )
        }
    }

    private static func rewriteEmbeddedMedia(
        in markdown: String,
        embeds: [EmbedReference],
        accessRootURL: URL,
        resourceIndex: Set<String>
    ) -> (markdown: String, rewrittenCount: Int) {
        var rewrittenMarkdown = markdown
        var rewrittenCount = 0

        for embed in embeds {
            guard let resourcePath = resolveResourcePath(for: embed.target, resourceIndex: resourceIndex),
                  let replacement = replacementMarkdown(
                    for: embed,
                    resourcePath: resourcePath,
                    accessRootURL: accessRootURL
                  ),
                  let range = rewrittenMarkdown.range(of: embed.originalMarkup) else {
                continue
            }

            rewrittenMarkdown.replaceSubrange(range, with: replacement)
            rewrittenCount += 1
        }

        return (rewrittenMarkdown, rewrittenCount)
    }

    private static func resolveResourcePath(for target: String, resourceIndex: Set<String>) -> String? {
        let cleanedTarget = normalizeLookupTarget(target)
        let decodedTarget = cleanedTarget.removingPercentEncoding ?? cleanedTarget

        if resourceIndex.contains(cleanedTarget) {
            return cleanedTarget
        }

        if decodedTarget != cleanedTarget, resourceIndex.contains(decodedTarget) {
            return decodedTarget
        }

        let exactSuffixMatches = resourceIndex.filter {
            $0.hasSuffix("/\(cleanedTarget)") || $0.hasSuffix("/\(decodedTarget)")
        }
        if exactSuffixMatches.count == 1 {
            return exactSuffixMatches.first
        }

        let basename = ((decodedTarget as NSString).lastPathComponent)
        guard basename.isEmpty == false else {
            return nil
        }

        let basenameMatches = resourceIndex.filter {
            (($0 as NSString).lastPathComponent).caseInsensitiveCompare(basename) == .orderedSame
        }
        if basenameMatches.count == 1 {
            return basenameMatches.first
        }

        return nil
    }

    private static func replacementMarkdown(
        for embed: EmbedReference,
        resourcePath: String,
        accessRootURL: URL
    ) -> String? {
        let absoluteURL = absoluteResourceURL(resourcePath: resourcePath, accessRootURL: accessRootURL)
        let label = embed.label ?? defaultLabel(for: embed.target)

        if embed.isImage {
            return "![\(label)](\(absoluteURL.absoluteString))"
        }

        return "[\(label)](\(absoluteURL.absoluteString))"
    }

    private static func absoluteResourceURL(resourcePath: String, accessRootURL: URL) -> URL {
        resourcePath
            .split(separator: "/", omittingEmptySubsequences: true)
            .reduce(accessRootURL) { partialURL, component in
                partialURL.appendingPathComponent(String(component))
            }
    }

    private static func defaultLabel(for target: String) -> String {
        let basename = (normalizeLookupTarget(target) as NSString).lastPathComponent
        let stem = ((basename as NSString).deletingPathExtension)
        return stem.isEmpty ? basename : stem
    }

    private static func normalizeLookupTarget(_ target: String) -> String {
        target
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: "\\", with: "/")
    }

    private static func isLikelyMediaReference(_ target: String) -> Bool {
        let ext = (target as NSString).pathExtension.lowercased()
        return [
            "png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "tif", "tiff", "avif", "heic", "heif",
            "mp4", "webm", "mov", "m4v", "mp3", "m4a", "wav", "ogg", "pdf"
        ].contains(ext)
    }

    private static func isLikelyImageReference(_ target: String) -> Bool {
        let ext = (target as NSString).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "tif", "tiff", "avif", "heic", "heif"].contains(ext)
    }

    private static func fetchMarkdown(url: URL) async throws -> String {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let (data, _) = try await session.data(from: url)
        if let decoded = String(data: data, encoding: .utf8) {
            return decoded
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func fetchResourceIndex(url: URL) async throws -> Set<String> {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let (data, _) = try await session.data(from: url)
        let object = try JSONSerialization.jsonObject(with: data)

        if let dictionary = object as? [String: Any] {
            return Set(dictionary.keys)
        }

        return []
    }
}
