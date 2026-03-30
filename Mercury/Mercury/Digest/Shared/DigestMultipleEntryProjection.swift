import Foundation

struct DigestMultipleEntryProjectionData: Equatable, Sendable, Identifiable {
    let id: Int64
    let articleTitle: String
    let articleAuthor: String
    let articleURL: String
    let summaryText: String?
    let noteText: String?
}

@MainActor
enum DigestMultipleEntryProjectionLoader {
    static func load(appModel: AppModel, entryIDs: [Int64]) async -> [DigestMultipleEntryProjectionData] {
        var projections: [DigestMultipleEntryProjectionData] = []
        projections.reserveCapacity(entryIDs.count)

        for entryId in entryIDs {
            guard let entry = await appModel.entryStore.loadEntry(id: entryId) else {
                continue
            }

            let singleEntryProjection = await DigestSingleEntryProjectionLoader.load(appModel: appModel, entry: entry)

            let summaryText: String?
            do {
                summaryText = try await appModel.loadLatestSummaryRecord(entryId: entryId)?.result.text
            } catch {
                summaryText = nil
                appModel.reportDebugIssue(
                    title: "Load Digest Summary Failed",
                    detail: [
                        "entryId=\(entryId)",
                        "error=\(error.localizedDescription)"
                    ].joined(separator: "\n"),
                    category: .task
                )
            }

            let noteText: String?
            do {
                noteText = try await appModel.loadEntryNote(entryId: entryId)?.markdownText
            } catch {
                noteText = nil
                appModel.reportDebugIssue(
                    title: "Load Digest Note Failed",
                    detail: [
                        "entryId=\(entryId)",
                        "error=\(error.localizedDescription)"
                    ].joined(separator: "\n"),
                    category: .task
                )
            }

            projections.append(
                DigestMultipleEntryProjectionData(
                    id: entryId,
                    articleTitle: singleEntryProjection.articleTitle,
                    articleAuthor: singleEntryProjection.articleAuthor,
                    articleURL: singleEntryProjection.articleURL,
                    summaryText: normalizeOptionalText(summaryText),
                    noteText: normalizeOptionalText(noteText)
                )
            )
        }

        return projections
    }

    nonisolated private static func normalizeOptionalText(_ text: String?) -> String? {
        let normalized = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}
