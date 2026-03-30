import Foundation

struct DigestSingleEntryProjectionData: Equatable, Sendable {
    let articleTitle: String
    let articleAuthor: String
    let articleURL: String
    let digestTitle: String
}

@MainActor
enum DigestSingleEntryProjectionLoader {
    static func load(appModel: AppModel?, entry: Entry) async -> DigestSingleEntryProjectionData {
        let fallbackTitle = (entry.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackURL = (entry.url ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackAuthor = DigestComposition.resolvedAuthor(
            entryAuthor: entry.author,
            feedTitle: nil
        )

        guard let appModel, let entryId = entry.id else {
            return DigestSingleEntryProjectionData(
                articleTitle: fallbackTitle,
                articleAuthor: fallbackAuthor,
                articleURL: fallbackURL,
                digestTitle: fallbackTitle
            )
        }

        do {
            if let projection = try await appModel.loadSingleEntryDigestProjection(entryId: entryId) {
                let articleTitle = (projection.articleTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let articleURL = (projection.articleURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let articleAuthor = DigestComposition.resolvedAuthor(
                    entryAuthor: projection.entryAuthor,
                    readabilityByline: projection.readabilityByline,
                    feedTitle: projection.feedTitle
                )
                return DigestSingleEntryProjectionData(
                    articleTitle: articleTitle,
                    articleAuthor: articleAuthor,
                    articleURL: articleURL,
                    digestTitle: articleTitle
                )
            }
        } catch {
            appModel.reportDebugIssue(
                title: "Load Digest Projection Failed",
                detail: [
                    "entryId=\(entryId)",
                    "error=\(error.localizedDescription)"
                ].joined(separator: "\n"),
                category: .task
            )
        }

        return DigestSingleEntryProjectionData(
            articleTitle: fallbackTitle,
            articleAuthor: fallbackAuthor,
            articleURL: fallbackURL,
            digestTitle: fallbackTitle
        )
    }
}
