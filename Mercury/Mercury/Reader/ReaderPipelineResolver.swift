import Foundation

struct ReaderPipelineResolution: Equatable, Sendable {
    let pipelineType: ReaderPipelineType
    let resolvedIntermediateContent: String?
}

enum ReaderPipelineResolver {
    nonisolated private static let obsidianBaseMarker = #"<base\s+href=["']https://publish\.obsidian\.md["']"#
    nonisolated private static let siteInfoMarker = #"window\.siteInfo\s*="#
    nonisolated private static let preloadPagePattern =
        #"window\.preloadPage\s*=\s*(?:fetch|f)\(\s*["']([^"']+)["']"#

    nonisolated static func resolve(
        entryURL: URL,
        fetchedDocument: ReaderFetchedDocument
    ) -> ReaderPipelineResolution {
        let html = fetchedDocument.html

        guard looksLikeObsidianPublishShell(html) else {
            return ReaderPipelineResolution(
                pipelineType: .default,
                resolvedIntermediateContent: nil
            )
        }

        guard let markdownURL = preloadPageURL(
            in: html,
            referenceURL: fetchedDocument.responseURL ?? entryURL
        ) else {
            return ReaderPipelineResolution(
                pipelineType: .default,
                resolvedIntermediateContent: nil
            )
        }

        return ReaderPipelineResolution(
            pipelineType: .obsidian,
            resolvedIntermediateContent: markdownURL.absoluteString
        )
    }

    nonisolated private static func looksLikeObsidianPublishShell(_ html: String) -> Bool {
        html.range(of: obsidianBaseMarker, options: .regularExpression) != nil &&
            html.range(of: siteInfoMarker, options: .regularExpression) != nil &&
            html.range(of: #"window\.preloadPage\s*="#, options: .regularExpression) != nil
    }

    nonisolated private static func preloadPageURL(in html: String, referenceURL: URL) -> URL? {
        guard let range = html.range(of: preloadPagePattern, options: .regularExpression) else {
            return nil
        }

        let match = String(html[range])
        guard let captureRange = match.range(of: #"["']([^"']+)["']"#, options: .regularExpression) else {
            return nil
        }

        let quotedValue = String(match[captureRange])
        let rawValue = quotedValue.dropFirst().dropLast()
        guard rawValue.isEmpty == false else {
            return nil
        }

        return URL(string: String(rawValue), relativeTo: referenceURL)?.absoluteURL
    }
}
