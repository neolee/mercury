import Testing
@testable import Mercury

@Suite("AI Translation Header Text Builder")
struct TranslationHeaderTextBuilderTests {
    @Test("Uses entry title and entry author when both are available")
    func usesEntryTitleAndAuthor() {
        let text = TranslationHeaderTextBuilder.buildHeaderSourceText(
            entryTitle: "Title",
            entryAuthor: "Author",
            renderedHTML: nil
        )

        #expect(text == "Title\nAuthor")
    }

    @Test("Falls back to byline from rendered HTML when entry author is missing")
    func fallsBackToRenderedByline() {
        let html = """
        <!doctype html>
        <html><head></head><body>
        <article class="reader">
          <h1>Original Title</h1>
          <p><em>Byline Author</em></p>
          <p>Body paragraph</p>
        </article>
        </body></html>
        """

        let text = TranslationHeaderTextBuilder.buildHeaderSourceText(
            entryTitle: "Title",
            entryAuthor: nil,
            renderedHTML: html
        )

        #expect(text == "Title\nByline Author")
    }

    @Test("Keeps title only when no author can be resolved")
    func keepsTitleOnlyWhenNoAuthor() {
        let html = """
        <!doctype html>
        <html><head></head><body>
        <article class="reader">
          <h1>Original Title</h1>
          <p></p>
          <p>Body paragraph</p>
        </article>
        </body></html>
        """

        let text = TranslationHeaderTextBuilder.buildHeaderSourceText(
            entryTitle: "Title",
            entryAuthor: nil,
            renderedHTML: html
        )

        #expect(text == "Title")
    }
}
