import Foundation
import Testing
@testable import Mercury

@Suite("Reader Pipeline Type Implementations")
@MainActor
struct ReaderPipelineTypeImplementationsTests {
    @Test("Default pipeline rebuild action follows shared rebuild policy")
    func defaultPipelineRebuildActionFollowsSharedPolicy() {
        let pipeline = ReaderDefaultPipeline(jobRunner: JobRunner())
        let content = makeContent(
            html: "<html><body>Source</body></html>",
            cleanedHtml: "<p>Cleaned</p>",
            readabilityVersion: ReaderPipelineVersion.readability,
            markdown: "# Title",
            markdownVersion: ReaderPipelineVersion.markdown
        )

        let action = pipeline.rebuildAction(
            for: content,
            cachedHTMLVersion: ReaderPipelineVersion.readerRender - 1,
            hasCachedHTML: true
        )

        #expect(action == .rerenderFromMarkdown)
    }

    @Test("Default pipeline builds Markdown from cleaned HTML and clears special intermediate content")
    @MainActor
    func defaultPipelineBuildsMarkdownFromIntermediate() async throws {
        let pipeline = ReaderDefaultPipeline(jobRunner: JobRunner())
        let content = makeContent(
            cleanedHtml: "<p>Hello <strong>world</strong>.</p>",
            readabilityTitle: "Example Title",
            resolvedIntermediateContent: "https://publish.example.com/article.md",
            pipelineType: .obsidian
        )

        let artifacts = try await pipeline.buildMarkdownFromIntermediate(
            content: content,
            appendEvent: { _ in }
        )

        #expect(artifacts.content.pipelineType == ReaderPipelineType.default.rawValue)
        #expect(artifacts.content.resolvedIntermediateContent == nil)
        #expect(artifacts.content.markdownVersion == ReaderPipelineVersion.markdown)
        #expect(artifacts.markdown == artifacts.content.markdown)
        #expect(artifacts.markdown.contains("# Example Title"))
        #expect(artifacts.markdown.contains("Hello **world**."))
    }

    @Test("Default pipeline builds from source and backfills trusted stored base URL")
    @MainActor
    func defaultPipelineBuildsMarkdownFromSource() async throws {
        let pipeline = ReaderDefaultPipeline(jobRunner: JobRunner())
        let content = makeContent(
            html: """
            <html>
              <head>
                <title>Article Title</title>
                <base href="https://example.com/posts/article/">
              </head>
              <body>
                <article>
                  <p>Hello world.</p>
                </article>
              </body>
            </html>
            """,
            resolvedIntermediateContent: "https://publish.example.com/article.md",
            pipelineType: .obsidian
        )

        let artifacts = try await pipeline.buildMarkdownFromSource(
            content: content,
            entryURL: try #require(URL(string: "https://example.com/posts/article")),
            appendEvent: { _ in }
        )

        #expect(artifacts.content.pipelineType == ReaderPipelineType.default.rawValue)
        #expect(artifacts.content.resolvedIntermediateContent == nil)
        #expect(artifacts.content.documentBaseURL == "https://example.com/posts/article/")
        #expect(artifacts.content.cleanedHtml?.isEmpty == false)
        #expect(artifacts.content.readabilityVersion == ReaderPipelineVersion.readability)
        #expect(artifacts.content.markdownVersion == ReaderPipelineVersion.markdown)
        #expect(artifacts.markdown.contains("Hello world."))
    }

    @Test("Obsidian pipeline rebuild action uses intermediate content instead of readability layers")
    func obsidianPipelineRebuildActionUsesIntermediateContent() {
        let pipeline = ReaderObsidianPipeline(markdownFetcher: { _ in "# Title" })
        let content = makeContent(
            cleanedHtml: "<p>Should be ignored</p>",
            readabilityVersion: ReaderPipelineVersion.readability,
            markdown: nil,
            markdownVersion: nil,
            resolvedIntermediateContent: "https://publish.example.com/article.md",
            pipelineType: .obsidian
        )

        let action = pipeline.rebuildAction(
            for: content,
            cachedHTMLVersion: ReaderPipelineVersion.readerRender,
            hasCachedHTML: true
        )

        #expect(action == .rebuildMarkdownAndRender)
    }

    @Test("Obsidian pipeline builds Markdown from intermediate URL and clears readability fields")
    @MainActor
    func obsidianPipelineBuildsMarkdownFromIntermediate() async throws {
        let pipeline = ReaderObsidianPipeline(markdownFetcher: { url in
            #expect(url.absoluteString == "https://publish.example.com/article.md")
            return "# Obsidian Title\n\nBody text."
        })
        let content = makeContent(
            cleanedHtml: "<p>Old cleaned HTML</p>",
            readabilityTitle: "Old Title",
            readabilityByline: "Old Byline",
            readabilityVersion: ReaderPipelineVersion.readability,
            resolvedIntermediateContent: "https://publish.example.com/article.md",
            pipelineType: .obsidian
        )

        let artifacts = try await pipeline.buildMarkdownFromIntermediate(
            content: content,
            appendEvent: { _ in }
        )

        #expect(artifacts.content.pipelineType == ReaderPipelineType.obsidian.rawValue)
        #expect(artifacts.content.cleanedHtml == nil)
        #expect(artifacts.content.readabilityTitle == nil)
        #expect(artifacts.content.readabilityByline == nil)
        #expect(artifacts.content.readabilityVersion == nil)
        #expect(artifacts.content.markdownVersion == ReaderPipelineVersion.markdown)
        #expect(artifacts.markdown == "# Obsidian Title\n\nBody text.")
    }

    @Test("Obsidian pipeline rewrites embedded image wikilinks using publish resource index")
    @MainActor
    func obsidianPipelineRewritesEmbeddedImageWikilinks() async throws {
        let pipeline = ReaderObsidianPipeline(
            markdownFetcher: { url in
                #expect(
                    url.absoluteString ==
                        "https://publish-01.obsidian.md/access/8a529a39ad1753175d73ccc6abc0547e/coding/tips/give-them-two-choices.md"
                )
                return "# Obsidian Title\n\n![[Pasted image 20260412153832.png]]\n\n![[CleanShot 2026-04-12 at 15.39.32@2x.png|Anki Screenshot]]"
            },
            resourceIndexFetcher: { url in
                #expect(url.absoluteString == "https://publish-01.obsidian.md/cache/8a529a39ad1753175d73ccc6abc0547e")
                return [
                    "images/Pasted image 20260412153832.png",
                    "images/CleanShot 2026-04-12 at 15.39.32@2x.png"
                ]
            }
        )
        let content = makeContent(
            resolvedIntermediateContent: "https://publish-01.obsidian.md/access/8a529a39ad1753175d73ccc6abc0547e/coding/tips/give-them-two-choices.md",
            pipelineType: .obsidian
        )

        let artifacts = try await pipeline.buildMarkdownFromIntermediate(
            content: content,
            appendEvent: { _ in }
        )

        #expect(
            artifacts.markdown.contains(
                "![Pasted image 20260412153832](https://publish-01.obsidian.md/access/8a529a39ad1753175d73ccc6abc0547e/images/Pasted%20image%2020260412153832.png)"
            )
        )
        #expect(
            artifacts.markdown.contains(
                "![Anki Screenshot](https://publish-01.obsidian.md/access/8a529a39ad1753175d73ccc6abc0547e/images/CleanShot%202026-04-12%20at%2015.39.32@2x.png)"
            )
        )
    }

    @Test("Obsidian pipeline resolves markdown URL from source shell before fetching Markdown")
    @MainActor
    func obsidianPipelineBuildsMarkdownFromSource() async throws {
        let pipeline = ReaderObsidianPipeline(markdownFetcher: { url in
            #expect(
                url.absoluteString ==
                    "https://publish-01.obsidian.md/access/8a529a39ad1753175d73ccc6abc0547e/coding/tips/give-them-two-choices.md"
            )
            return "# Resolved Title\n\nResolved body."
        })
        let content = makeContent(html: obsidianShellHTML, pipelineType: .default)

        let artifacts = try await pipeline.buildMarkdownFromSource(
            content: content,
            entryURL: try #require(URL(string: "https://chadnauseam.com/coding/tips/give-them-two-choices")),
            appendEvent: { _ in }
        )

        #expect(artifacts.content.pipelineType == ReaderPipelineType.obsidian.rawValue)
        #expect(
            artifacts.content.resolvedIntermediateContent ==
                "https://publish-01.obsidian.md/access/8a529a39ad1753175d73ccc6abc0547e/coding/tips/give-them-two-choices.md"
        )
        #expect(artifacts.content.cleanedHtml == nil)
        #expect(artifacts.content.readabilityVersion == nil)
        #expect(artifacts.content.markdownVersion == ReaderPipelineVersion.markdown)
        #expect(artifacts.markdown == "# Resolved Title\n\nResolved body.")
    }
}

private extension ReaderPipelineTypeImplementationsTests {
    func makeContent(
        html: String? = nil,
        cleanedHtml: String? = nil,
        readabilityTitle: String? = nil,
        readabilityByline: String? = nil,
        readabilityVersion: Int? = nil,
        markdown: String? = nil,
        markdownVersion: Int? = nil,
        resolvedIntermediateContent: String? = nil,
        pipelineType: ReaderPipelineType = .default
    ) -> Content {
        Content(
            id: nil,
            entryId: 1,
            html: html,
            cleanedHtml: cleanedHtml,
            readabilityTitle: readabilityTitle,
            readabilityByline: readabilityByline,
            readabilityVersion: readabilityVersion,
            markdown: markdown,
            markdownVersion: markdownVersion,
            displayMode: ContentDisplayMode.cleaned.rawValue,
            createdAt: Date(),
            documentBaseURL: nil,
            pipelineType: pipelineType.rawValue,
            resolvedIntermediateContent: resolvedIntermediateContent
        )
    }
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
