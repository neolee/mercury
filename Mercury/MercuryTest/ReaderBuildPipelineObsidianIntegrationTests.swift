import Foundation
import GRDB
import Testing
@testable import Mercury

@Suite("Reader Build Pipeline Obsidian Integration")
@MainActor
struct ReaderBuildPipelineObsidianIntegrationTests {
    @Test("Build pipeline rerenders current Obsidian Markdown without requiring readability output")
    @MainActor
    func rerendersCurrentObsidianMarkdownWithoutReadability() async throws {
        try await AppModelTestHarness.withInMemory(
            credentialStore: ReaderBuildPipelineObsidianCredentialStore()
        ) { harness in
            let appModel = harness.appModel
            let entry = try await Self.makeEntry(appModel: appModel)
            let entryId = try #require(entry.id)
            let theme = Self.readerTheme

            let content = Content(
                id: nil,
                entryId: entryId,
                html: "<html><body>shell</body></html>",
                cleanedHtml: nil,
                readabilityTitle: nil,
                readabilityByline: nil,
                readabilityVersion: nil,
                markdown: "# Obsidian Title\n\nRendered body.",
                markdownVersion: ReaderPipelineVersion.markdown,
                displayMode: ContentDisplayMode.cleaned.rawValue,
                createdAt: Date(),
                documentBaseURL: nil,
                pipelineType: ReaderPipelineType.obsidian.rawValue,
                resolvedIntermediateContent: "https://publish.example.com/article.md"
            )
            _ = try await appModel.contentStore.upsert(content)

            let output = await appModel.readerBuildPipeline.run(for: entry, theme: theme)
            let cached = try await appModel.contentStore.cachedHTML(
                for: entryId,
                themeId: theme.cacheThemeID
            )

            #expect(output.result.errorMessage == nil)
            #expect(output.result.html?.contains("Rendered body.") == true)
            #expect(cached?.readerRenderVersion == ReaderPipelineVersion.readerRender)
        }
    }

    @Test("Build pipeline resolves fetched Obsidian shell into Markdown and rendered HTML")
    @MainActor
    func resolvesFetchedObsidianShellIntoMarkdownAndRenderedHTML() async throws {
        try await AppModelTestHarness.withInMemory(
            credentialStore: ReaderBuildPipelineObsidianCredentialStore()
        ) { harness in
            let appModel = harness.appModel
            let entry = try await Self.makeEntry(appModel: appModel)
            let entryId = try #require(entry.id)
            let theme = Self.readerTheme

            let pipeline = ReaderBuildPipeline(
                contentStore: appModel.contentStore,
                entryStore: appModel.entryStore,
                jobRunner: appModel.jobRunner,
                sourceDocumentFetcher: { _, _ in
                    ReaderFetchedDocument(
                        html: obsidianShellHTML,
                        responseURL: URL(string: "https://chadnauseam.com/coding/tips/give-them-two-choices")
                    )
                },
                obsidianMarkdownFetcher: { url in
                    #expect(
                        url.absoluteString ==
                            "https://publish-01.obsidian.md/access/8a529a39ad1753175d73ccc6abc0547e/coding/tips/give-them-two-choices.md"
                    )
                    return "# Obsidian Title\n\nResolved body."
                }
            )

            let output = await pipeline.run(for: entry, theme: theme)
            let storedContent = try await appModel.contentStore.content(for: entryId)
            let cached = try await appModel.contentStore.cachedHTML(
                for: entryId,
                themeId: theme.cacheThemeID
            )

            #expect(output.result.errorMessage == nil)
            #expect(output.result.html?.contains("Resolved body.") == true)
            #expect(storedContent?.pipelineType == ReaderPipelineType.obsidian.rawValue)
            #expect(
                storedContent?.resolvedIntermediateContent ==
                    "https://publish-01.obsidian.md/access/8a529a39ad1753175d73ccc6abc0547e/coding/tips/give-them-two-choices.md"
            )
            #expect(storedContent?.cleanedHtml == nil)
            #expect(storedContent?.readabilityVersion == nil)
            #expect(storedContent?.markdown == "# Obsidian Title\n\nResolved body.")
            #expect(storedContent?.markdownVersion == ReaderPipelineVersion.markdown)
            #expect(cached?.readerRenderVersion == ReaderPipelineVersion.readerRender)
        }
    }

    @Test("Build pipeline keeps Obsidian ownership when Markdown fetch fails after resolution")
    @MainActor
    func keepsObsidianOwnershipWhenMarkdownFetchFailsAfterResolution() async throws {
        try await AppModelTestHarness.withInMemory(
            credentialStore: ReaderBuildPipelineObsidianCredentialStore()
        ) { harness in
            let appModel = harness.appModel
            let entry = try await Self.makeEntry(appModel: appModel)
            let entryId = try #require(entry.id)
            let theme = Self.readerTheme

            let pipeline = ReaderBuildPipeline(
                contentStore: appModel.contentStore,
                entryStore: appModel.entryStore,
                jobRunner: appModel.jobRunner,
                sourceDocumentFetcher: { _, _ in
                    ReaderFetchedDocument(
                        html: obsidianShellHTML,
                        responseURL: URL(string: "https://chadnauseam.com/coding/tips/give-them-two-choices")
                    )
                },
                obsidianMarkdownFetcher: { _ in
                    throw ReaderBuildError.invalidURL
                }
            )

            let output = await pipeline.run(for: entry, theme: theme)
            let storedContent = try await appModel.contentStore.content(for: entryId)
            let cached = try await appModel.contentStore.cachedHTML(
                for: entryId,
                themeId: theme.cacheThemeID
            )

            #expect(output.result.errorMessage == "Invalid URL")
            #expect(output.result.html == nil)
            #expect(storedContent?.pipelineType == ReaderPipelineType.obsidian.rawValue)
            #expect(
                storedContent?.resolvedIntermediateContent ==
                    "https://publish-01.obsidian.md/access/8a529a39ad1753175d73ccc6abc0547e/coding/tips/give-them-two-choices.md"
            )
            #expect(storedContent?.markdown == nil)
            #expect(storedContent?.cleanedHtml == nil)
            #expect(cached == nil)
        }
    }
}

private extension ReaderBuildPipelineObsidianIntegrationTests {
    static var readerTheme: EffectiveReaderTheme {
        ReaderThemeResolver.resolve(
            presetID: .classic,
            mode: .forceLight,
            isSystemDark: false,
            override: nil
        )
    }

    @MainActor
    static func makeEntry(appModel: AppModel) async throws -> Entry {
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
                url: "https://chadnauseam.com/coding/tips/give-them-two-choices",
                title: "Title",
                author: nil,
                publishedAt: nil,
                summary: "Summary",
                isRead: false,
                isStarred: false,
                createdAt: Date()
            )
            try entry.insert(db)
            return entry
        }
    }
}

private final class ReaderBuildPipelineObsidianCredentialStore: CredentialStore, @unchecked Sendable {
    func save(secret: String, for ref: String) throws {}
    func readSecret(for ref: String) throws -> String { "secret" }
    func deleteSecret(for ref: String) throws {}
}

private let obsidianShellHTML = """
<!doctype html><html lang="en"><head><meta charset="utf-8"/><meta name="viewport" content="width=device-width,initial-scale=1"/><style class="preload">html,body{margin:0;height:100%}body.theme-light{background-color:#fff;color:#222}body.theme-dark{background-color:#1e1e1e;color:#dadada}.preload{padding:20px;white-space:pre-wrap;overflow-wrap:break-word}@keyframes rotate{from{transform:rotate(0)}to{transform:rotate(360deg)}}</style><base href="https://publish.obsidian.md"><script defer="defer" src="/app.js?5e3dc6f6d7b275ed59ee"></script><link rel="preload" href="/app.css?5e3dc6f6d7b275ed59ee" as="style" onload="this.onload=null;this.rel='stylesheet'"><noscript><link rel="stylesheet" href="/app.css?5e3dc6f6d7b275ed59ee"></noscript><title>give-them-two-choices - Chad Nauseam Home</title><link rel="preload" href="https://publish-01.obsidian.md/access/8a529a39ad1753175d73ccc6abc0547e/publish.css" as="style" onload="this.onload=null;this.rel='stylesheet'"><noscript><link rel="stylesheet" href="https://publish-01.obsidian.md/access/8a529a39ad1753175d73ccc6abc0547e/publish.css"></noscript><link rel="preload" href="https://publish-01.obsidian.md/access/8a529a39ad1753175d73ccc6abc0547e/publish.js" as="script"><link rel="icon" href="/favicon.ico?5e3dc6f6d7b275ed59ee"><script type="text/javascript">
window.siteInfo={"uid":"8a529a39ad1753175d73ccc6abc0547e","host":"publish-01.obsidian.md","status":"active","slug":null,"redirect":1,"customurl":"chadnauseam.com"};
(function(){
	let f = u=>u&&fetch(u,{credentials: "include"});
	window.preloadOptions=f("https://publish-01.obsidian.md/options/8a529a39ad1753175d73ccc6abc0547e");
	window.preloadCache=f("https://publish-01.obsidian.md/cache/8a529a39ad1753175d73ccc6abc0547e");
	window.preloadPage=f("https://publish-01.obsidian.md/access/8a529a39ad1753175d73ccc6abc0547e/coding/tips/give-them-two-choices.md");
})();
</script><meta name="description" content="give-them-two-choices - Chad Nauseam Home"><meta property="og:description" content="give-them-two-choices - Chad Nauseam Home"></head><body class="theme-light"><div class="preload" style="text-align:center"><svg style="width:50px" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><path style="transform-origin:50px 50px;animation:1s linear infinite rotate" fill="currentColor" d="M73,50c0-12.7-10.3-23-23-23S27,37.3,27,50 M30.9,50c0-10.5,8.5-19.1,19.1-19.1S69.1,39.5,69.1,50"/></svg></div><script type="text/javascript">(function(){let t=localStorage.getItem('site-theme'),cl=document.body.classList;if(t&&t!=='light') {cl.remove('theme-light');cl.add('theme-'+t)}})();</script></body></html>
"""
