//
//  AppModel+Reader.swift
//  Mercury
//

import Foundation
extension AppModel {
    func readerBuildResult(for entry: Entry, theme: EffectiveReaderTheme) async -> ReaderBuildResult {
        let output: ReaderBuildPipelineOutput
        if let entryId = entry.id {
            output = await withReaderPipelineRebuildScope(entryId: entryId) {
                do {
                    _ = try await readerDocumentBaseURLRepairUseCase.repairIfNeeded(for: entry)
                } catch {
                    reportDebugIssue(
                        title: "Reader Document Base URL Repair Failed",
                        detail: "entryId=\(entryId)\nurl=\(entry.url ?? "(missing)")\nerror=\(error.localizedDescription)",
                        category: .reader
                    )
                }
                return await readerBuildPipeline.run(for: entry, theme: theme)
            }
        } else {
            output = await readerBuildPipeline.run(for: entry, theme: theme)
        }
        if let debugDetail = output.debugDetail {
            reportDebugIssue(
                title: "Reader Build Failure",
                detail: debugDetail,
                category: .reader
            )
        }
        return output.result
    }

    func rerunReaderPipeline(
        for entry: Entry,
        theme: EffectiveReaderTheme,
        target: ReaderPipelineTarget
    ) async -> ReaderBuildResult {
        guard let entryId = entry.id else {
            return ReaderBuildResult(html: nil, errorMessage: "Missing entry ID")
        }

        do {
            return await withReaderPipelineRebuildScope(entryId: entryId) {
                do {
                    try await contentStore.invalidateReaderPipeline(entryId: entryId, target: target)
                } catch {
                    reportDebugIssue(
                        title: "Reader Pipeline Invalidation Failed",
                        detail: "entryId=\(entryId)\ntarget=\(target)\nerror=\(error.localizedDescription)",
                        category: .reader
                    )
                    return ReaderBuildResult(html: nil, errorMessage: error.localizedDescription)
                }
                return await readerBuildResult(for: entry, theme: theme)
            }
        }
    }

    func availableReaderMarkdown(entryId: Int64) async throws -> String? {
        guard isReaderPipelineRebuilding(entryId: entryId) == false else {
            return nil
        }

        let content = try await contentStore.content(for: entryId)
        guard isCurrentReaderMarkdown(content) else {
            return nil
        }

        let markdown = content?.markdown?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let markdown, markdown.isEmpty == false else {
            return nil
        }
        return markdown
    }

    func taggingSourceBody(entry: Entry, maxLength: Int = 800) async throws -> String {
        guard let entryId = entry.id else {
            return entry.summary ?? ""
        }

        if let markdown = try await availableReaderMarkdown(entryId: entryId) {
            return String(markdown.prefix(maxLength))
        }

        return entry.summary ?? ""
    }

    func isReaderPipelineRebuilding(entryId: Int64?) -> Bool {
        guard let entryId else {
            return false
        }
        return readerPipelineRebuildingEntryIDs.contains(entryId)
    }

    func withReaderPipelineRebuildScope<Result>(
        entryId: Int64,
        operation: () async throws -> Result
    ) async rethrows -> Result {
        beginReaderPipelineRebuild(entryId: entryId)
        defer { endReaderPipelineRebuild(entryId: entryId) }
        return try await operation()
    }

    private func isCurrentReaderMarkdown(_ content: Content?) -> Bool {
        guard let content else {
            return false
        }
        guard content.readabilityVersion == ReaderPipelineVersion.readability else {
            return false
        }
        return content.markdownVersion == ReaderPipelineVersion.markdown
    }

    private func beginReaderPipelineRebuild(entryId: Int64) {
        let nextDepth = (readerPipelineRebuildDepthByEntry[entryId] ?? 0) + 1
        readerPipelineRebuildDepthByEntry[entryId] = nextDepth
        readerPipelineRebuildingEntryIDs.insert(entryId)
    }

    private func endReaderPipelineRebuild(entryId: Int64) {
        guard let currentDepth = readerPipelineRebuildDepthByEntry[entryId] else {
            return
        }

        if currentDepth > 1 {
            readerPipelineRebuildDepthByEntry[entryId] = currentDepth - 1
            return
        }

        readerPipelineRebuildDepthByEntry.removeValue(forKey: entryId)
        readerPipelineRebuildingEntryIDs.remove(entryId)
    }
}
