import Testing
@testable import Mercury

@MainActor
struct ReaderHTMLPatchTests {
    @Test
    func extractsBaseAndTranslationStylesSeparately() throws {
        let html = """
        <!doctype html>
        <html>
        <head>
        <style>body { color: red; }</style>
        <style>.mercury-translation-block { color: blue; }</style>
        </head>
        <body>
        <article class="reader"><p>Hello</p></article>
        </body>
        </html>
        """

        let patch = try #require(ReaderHTMLPatch.make(from: html))

        #expect(patch.articleInnerHTML.contains("<p>Hello</p>"))
        #expect(patch.baseStyleContent == "body { color: red; }")
        #expect(patch.translationStyle == ".mercury-translation-block { color: blue; }")
    }

    @Test
    func patchDecisionRequiresExistingLoadedHTML() throws {
        let patch = try #require(
            ReaderHTMLPatch.make(
                from: """
                <html><head><style>body { color: red; }</style></head><body><article class="reader"><p>Hello</p></article></body></html>
                """
            )
        )

        #expect(
            WebView.shouldApplyReaderPatch(
                hasLoadedHTML: false,
                previousBaseStyleContent: patch.baseStyleContent,
                patch: patch
            ) == false
        )
    }

    @Test
    func patchDecisionAllowsPatchOnlyWhenBaseStyleMatches() throws {
        let oldPatch = try #require(
            ReaderHTMLPatch.make(
                from: """
                <html><head><style>body { color: red; }</style></head><body><article class="reader"><p>Old</p></article></body></html>
                """
            )
        )
        let sameStylePatch = try #require(
            ReaderHTMLPatch.make(
                from: """
                <html><head><style>body { color: red; }</style></head><body><article class="reader"><p>New</p></article></body></html>
                """
            )
        )
        let changedStylePatch = try #require(
            ReaderHTMLPatch.make(
                from: """
                <html><head><style>body { color: blue; }</style></head><body><article class="reader"><p>New</p></article></body></html>
                """
            )
        )

        #expect(
            WebView.shouldApplyReaderPatch(
                hasLoadedHTML: true,
                previousBaseStyleContent: oldPatch.baseStyleContent,
                patch: sameStylePatch
            )
        )
        #expect(
            WebView.shouldApplyReaderPatch(
                hasLoadedHTML: true,
                previousBaseStyleContent: oldPatch.baseStyleContent,
                patch: changedStylePatch
            ) == false
        )
    }
}
