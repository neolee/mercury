import Testing
@testable import Mercury

@Suite("AI Translation Bilingual Composer")
struct AITranslationBilingualComposerTests {
    @Test("Compose injects translated blocks for p ul ol")
    func injectsTranslatedBlocks() throws {
        let html = """
        <!doctype html>
        <html><head></head><body>
        <article class="reader">
          <p>First paragraph</p>
          <ul><li>One</li><li>Two</li></ul>
          <ol><li>A</li><li>B</li></ol>
        </article>
        </body></html>
        """
        let snapshot = try AITranslationSegmentExtractor.extractFromRenderedHTML(entryId: 1, renderedHTML: html)
        let translated = Dictionary(uniqueKeysWithValues: snapshot.segments.map { segment in
            (segment.sourceSegmentId, "TR-\(segment.orderIndex)")
        })

        let result = try AITranslationBilingualComposer.compose(
            renderedHTML: html,
            entryId: 1,
            translatedBySegmentID: translated,
            missingStatusText: nil
        )

        #expect(result.snapshot.segments.count == 3)
        #expect(result.html.contains("TR-0"))
        #expect(result.html.contains("TR-1"))
        #expect(result.html.contains("TR-2"))
    }

    @Test("Compose shows status placeholder for missing segments")
    func showsStatusWhenMissing() throws {
        let html = """
        <!doctype html>
        <html><head></head><body>
        <article class="reader">
          <p>Hello</p>
        </article>
        </body></html>
        """
        let result = try AITranslationBilingualComposer.compose(
            renderedHTML: html,
            entryId: 2,
            translatedBySegmentID: [:],
            missingStatusText: "Generating..."
        )

        #expect(result.html.contains("Generating..."))
        #expect(result.html.contains("mercury-translation-status"))
    }

    @Test("List-internal paragraph does not create duplicated segment block")
    func listParagraphNoDuplicate() throws {
        let html = """
        <!doctype html>
        <html><head></head><body>
        <article class="reader">
          <ul><li><p>Inside list</p></li></ul>
        </article>
        </body></html>
        """
        let snapshot = try AITranslationSegmentExtractor.extractFromRenderedHTML(entryId: 3, renderedHTML: html)
        #expect(snapshot.segments.count == 1)

        let result = try AITranslationBilingualComposer.compose(
            renderedHTML: html,
            entryId: 3,
            translatedBySegmentID: [snapshot.segments[0].sourceSegmentId: "OK"],
            missingStatusText: nil
        )
        #expect(result.html.contains("OK"))
    }
}
