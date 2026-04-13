import Foundation
import GRDB
import Testing
@testable import Mercury

@Suite("AppModel Reader Runtime")
struct AppModelReaderRuntimeTests {

    @Test("Available reader Markdown requires current readability and Markdown versions")
    @MainActor
    func availableReaderMarkdownRequiresCurrentReadabilityAndMarkdownVersions() async throws {
        try await AppModelTestHarness.withInMemory(
            credentialStore: ReaderRuntimeTestCredentialStore()
        ) { harness in
            let appModel = harness.appModel
            let entry = try await Self.makeEntry(appModel: appModel, summary: "Fallback summary")
            let entryId = try #require(entry.id)

            try await Self.seedCurrentReaderPipeline(appModel: appModel, entryId: entryId)
            let currentMarkdown = try await appModel.availableReaderMarkdown(entryId: entryId)
            #expect(currentMarkdown == "# Title\n\nBody")

            try await appModel.contentStore.invalidateReaderPipeline(entryId: entryId, target: .readability)
            let staleReadabilityMarkdown = try await appModel.availableReaderMarkdown(entryId: entryId)
            #expect(staleReadabilityMarkdown == nil)

            try await Self.seedCurrentReaderPipeline(appModel: appModel, entryId: entryId)
            try await appModel.contentStore.invalidateReaderPipeline(entryId: entryId, target: .markdown)
            let staleMarkdown = try await appModel.availableReaderMarkdown(entryId: entryId)
            #expect(staleMarkdown == nil)
        }
    }

    @Test("Available reader Markdown accepts current Obsidian pipeline Markdown without readability layer")
    @MainActor
    func availableReaderMarkdownAcceptsCurrentObsidianMarkdown() async throws {
        try await AppModelTestHarness.withInMemory(
            credentialStore: ReaderRuntimeTestCredentialStore()
        ) { harness in
            let appModel = harness.appModel
            let entry = try await Self.makeEntry(appModel: appModel, summary: "Fallback summary")
            let entryId = try #require(entry.id)

            try await Self.seedCurrentReaderPipeline(
                appModel: appModel,
                entryId: entryId,
                pipelineType: .obsidian,
                resolvedIntermediateContent: "https://publish.example.com/article.md",
                cleanedHtml: nil,
                readabilityTitle: nil,
                readabilityVersion: nil,
                markdown: "# Obsidian Title\n\nBody"
            )

            let markdown = try await appModel.availableReaderMarkdown(entryId: entryId)
            #expect(markdown == "# Obsidian Title\n\nBody")
        }
    }

    @Test("Available reader Markdown returns nil while entry is marked rebuilding")
    @MainActor
    func availableReaderMarkdownReturnsNilWhileEntryIsMarkedRebuilding() async throws {
        try await AppModelTestHarness.withInMemory(
            credentialStore: ReaderRuntimeTestCredentialStore()
        ) { harness in
            let appModel = harness.appModel
            let entry = try await Self.makeEntry(appModel: appModel, summary: "Fallback summary")
            let entryId = try #require(entry.id)

            try await Self.seedCurrentReaderPipeline(appModel: appModel, entryId: entryId)

            var continuation: CheckedContinuation<Void, Never>?
            let task = Task { @MainActor in
                await appModel.withReaderPipelineRebuildScope(entryId: entryId) {
                    await withCheckedContinuation { continuation = $0 }
                }
            }

            try await Self.waitUntil(
                message: "Timed out waiting for rebuild scope to mark the entry as rebuilding"
            ) {
                appModel.isReaderPipelineRebuilding(entryId: entryId)
            }

            #expect(appModel.isReaderPipelineRebuilding(entryId: entryId))
            let markdownWhileRebuilding = try await appModel.availableReaderMarkdown(entryId: entryId)
            #expect(markdownWhileRebuilding == nil)

            let rebuildContinuation = try #require(continuation)
            rebuildContinuation.resume()
            await task.value

            #expect(!appModel.isReaderPipelineRebuilding(entryId: entryId))
        }
    }

    @Test("Nested reader pipeline rebuild scope keeps state until outer scope finishes")
    @MainActor
    func nestedReaderPipelineRebuildScopeKeepsStateUntilOuterScopeFinishes() async throws {
        try await AppModelTestHarness.withInMemory(
            credentialStore: ReaderRuntimeTestCredentialStore()
        ) { harness in
            let appModel = harness.appModel
            let entry = try await Self.makeEntry(appModel: appModel, summary: "Fallback summary")
            let entryId = try #require(entry.id)

            var continuation: CheckedContinuation<Void, Never>?
            let task = Task { @MainActor in
                await appModel.withReaderPipelineRebuildScope(entryId: entryId) {
                    #expect(appModel.isReaderPipelineRebuilding(entryId: entryId))
                    await appModel.withReaderPipelineRebuildScope(entryId: entryId) {
                        #expect(appModel.isReaderPipelineRebuilding(entryId: entryId))
                    }
                    #expect(appModel.isReaderPipelineRebuilding(entryId: entryId))
                    await withCheckedContinuation { continuation = $0 }
                }
            }

            try await Self.waitUntil(
                message: "Timed out waiting for outer rebuild scope to remain active"
            ) {
                appModel.isReaderPipelineRebuilding(entryId: entryId)
            }
            #expect(appModel.isReaderPipelineRebuilding(entryId: entryId))

            let rebuildContinuation = try #require(continuation)
            rebuildContinuation.resume()
            await task.value

            #expect(!appModel.isReaderPipelineRebuilding(entryId: entryId))
        }
    }

    @Test("Rerun reader pipeline for reader HTML rebuilds and clears rebuild state")
    @MainActor
    func rerunReaderPipelineReaderHTMLRebuildsAndClearsRebuildState() async throws {
        try await AppModelTestHarness.withInMemory(
            credentialStore: ReaderRuntimeTestCredentialStore()
        ) { harness in
            let appModel = harness.appModel
            let entry = try await Self.makeEntry(appModel: appModel, summary: "Fallback summary")
            let entryId = try #require(entry.id)

            try await Self.seedCurrentReaderPipeline(appModel: appModel, entryId: entryId)

            let theme = ReaderThemeResolver.resolve(
                presetID: .classic,
                mode: .forceLight,
                isSystemDark: false,
                override: nil
            )

            let result = await appModel.rerunReaderPipeline(
                for: entry,
                theme: theme,
                target: .readerHTML
            )

            #expect(!appModel.isReaderPipelineRebuilding(entryId: entryId))
            #expect(result.errorMessage == nil)
            #expect(result.html != nil)

            let cache = try await appModel.contentStore.cachedHTML(
                for: entryId,
                themeId: theme.cacheThemeID
            )
            #expect(cache?.readerRenderVersion == ReaderPipelineVersion.readerRender)
            #expect(cache?.html != nil)
        }
    }

    @Test("Tagging source body falls back to entry summary when Markdown is stale")
    @MainActor
    func taggingSourceBodyFallsBackToEntrySummaryWhenMarkdownIsStale() async throws {
        try await AppModelTestHarness.withInMemory(
            credentialStore: ReaderRuntimeTestCredentialStore()
        ) { harness in
            let appModel = harness.appModel
            let entry = try await Self.makeEntry(appModel: appModel, summary: "Fallback summary")
            let entryId = try #require(entry.id)

            try await Self.seedCurrentReaderPipeline(appModel: appModel, entryId: entryId)
            let currentBody = try await appModel.taggingSourceBody(entry: entry, maxLength: 8)
            #expect(currentBody == "# Title\n")

            try await appModel.contentStore.invalidateReaderPipeline(entryId: entryId, target: .readability)
            let fallbackBody = try await appModel.taggingSourceBody(entry: entry, maxLength: 800)
            #expect(fallbackBody == "Fallback summary")
        }
    }
}

private extension AppModelReaderRuntimeTests {
    @MainActor
    static func waitUntil(
        iterations: Int = 100,
        interval: Duration = .milliseconds(10),
        message: String,
        _ condition: @MainActor () -> Bool
    ) async throws {
        for _ in 0..<iterations {
            if condition() {
                return
            }
            try await Task.sleep(for: interval)
        }

        fatalError(message)
    }

    @MainActor
    static func makeEntry(appModel: AppModel, summary: String) async throws -> Entry {
        try await appModel.database.write { db in
            var feed = Feed(
                id: nil,
                title: "Test Feed",
                feedURL: "https://example.com/feed/\(UUID().uuidString)",
                siteURL: "https://example.com",
                lastFetchedAt: nil,
                createdAt: Date()
            )
            try feed.insert(db)

            var entry = Entry(
                id: nil,
                feedId: feed.id!,
                guid: UUID().uuidString,
                url: "https://example.com/articles/\(UUID().uuidString)",
                title: "Title",
                author: nil,
                publishedAt: nil,
                summary: summary,
                isRead: false,
                isStarred: false,
                createdAt: Date()
            )
            try entry.insert(db)
            return entry
        }
    }

    @MainActor
    static func seedCurrentReaderPipeline(appModel: AppModel, entryId: Int64) async throws {
        try await seedCurrentReaderPipeline(
            appModel: appModel,
            entryId: entryId,
            pipelineType: .default,
            resolvedIntermediateContent: nil,
            cleanedHtml: "<p>Body</p>",
            readabilityTitle: "Title",
            readabilityVersion: ReaderPipelineVersion.readability,
            markdown: "# Title\n\nBody"
        )
    }

    @MainActor
    static func seedCurrentReaderPipeline(
        appModel: AppModel,
        entryId: Int64,
        pipelineType: ReaderPipelineType,
        resolvedIntermediateContent: String?,
        cleanedHtml: String?,
        readabilityTitle: String?,
        readabilityVersion: Int?,
        markdown: String
    ) async throws {
        let content = Content(
            id: nil,
            entryId: entryId,
            html: "<html>source</html>",
            cleanedHtml: cleanedHtml,
            readabilityTitle: readabilityTitle,
            readabilityByline: nil,
            readabilityVersion: readabilityVersion,
            markdown: markdown,
            markdownVersion: ReaderPipelineVersion.markdown,
            displayMode: ContentDisplayMode.cleaned.rawValue,
            createdAt: Date(),
            documentBaseURL: nil,
            pipelineType: pipelineType.rawValue,
            resolvedIntermediateContent: resolvedIntermediateContent
        )

        _ = try await appModel.contentStore.upsert(content)
        try await appModel.contentStore.upsertCache(
            entryId: entryId,
            themeId: "default",
            html: "<html>rendered</html>",
            readerRenderVersion: ReaderPipelineVersion.readerRender
        )
    }
}

private final class ReaderRuntimeTestCredentialStore: CredentialStore, @unchecked Sendable {
    private var storage: [String: String] = [:]

    func save(secret: String, for ref: String) throws {
        storage[ref] = secret
    }

    func readSecret(for ref: String) throws -> String {
        guard let secret = storage[ref] else {
            throw CredentialStoreError.itemNotFound
        }
        return secret
    }

    func deleteSecret(for ref: String) throws {
        storage.removeValue(forKey: ref)
    }
}
