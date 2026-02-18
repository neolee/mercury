//
//  AppModel+Reader.swift
//  Mercury
//

import Foundation
extension AppModel {
    func readerBuildResult(for entry: Entry, theme: EffectiveReaderTheme) async -> ReaderBuildResult {
        let output = await readerBuildUseCase.run(for: entry, theme: theme)
        if let debugDetail = output.debugDetail {
            reportDebugIssue(
                title: "Reader Build Failure",
                detail: debugDetail,
                category: .reader
            )
        }
        return output.result
    }

    func summarySourceMarkdown(entryId: Int64) async throws -> String? {
        let content = try await contentStore.content(for: entryId)
        let markdown = content?.markdown?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let markdown, markdown.isEmpty == false else {
            return nil
        }
        return markdown
    }
}
