import Foundation
import Testing
@testable import Mercury

@Suite("Reader Pipeline Resolver")
struct ReaderPipelineResolverTests {
    @Test("Resolve detects Obsidian Publish shell and extracts Markdown URL")
    func resolveDetectsObsidianPublishShell() throws {
        let resolution = ReaderPipelineResolver.resolve(
            entryURL: try #require(URL(string: "https://chadnauseam.com/coding/tips/give-them-two-choices")),
            fetchedDocument: ReaderFetchedDocument(
                html: obsidianShellHTML,
                responseURL: URL(string: "https://chadnauseam.com/coding/tips/give-them-two-choices")
            )
        )

        #expect(resolution.pipelineType == .obsidian)
        #expect(
            resolution.resolvedIntermediateContent ==
                "https://publish-01.obsidian.md/access/8a529a39ad1753175d73ccc6abc0547e/coding/tips/give-them-two-choices.md"
        )
    }

    @Test("Resolve falls back to default for regular HTML pages")
    func resolveFallsBackToDefaultForRegularPages() throws {
        let resolution = ReaderPipelineResolver.resolve(
            entryURL: try #require(URL(string: "https://example.com/posts/article")),
            fetchedDocument: ReaderFetchedDocument(
                html: "<html><head><title>Article</title></head><body><article>Hello</article></body></html>",
                responseURL: URL(string: "https://example.com/posts/article")
            )
        )

        #expect(resolution.pipelineType == .default)
        #expect(resolution.resolvedIntermediateContent == nil)
    }

    @Test("Resolve falls back to default when Obsidian shell has no usable preload page URL")
    func resolveFallsBackWhenPreloadPageURLIsMissing() throws {
        let html = """
        <html>
        <head>
          <base href="https://publish.obsidian.md">
          <script>
          window.siteInfo={"uid":"vault","host":"publish-01.obsidian.md"};
          window.preloadPage=f("");
          </script>
        </head>
        <body></body>
        </html>
        """

        let resolution = ReaderPipelineResolver.resolve(
            entryURL: try #require(URL(string: "https://example.com/obsidian-shell")),
            fetchedDocument: ReaderFetchedDocument(
                html: html,
                responseURL: URL(string: "https://example.com/obsidian-shell")
            )
        )

        #expect(resolution.pipelineType == .default)
        #expect(resolution.resolvedIntermediateContent == nil)
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
