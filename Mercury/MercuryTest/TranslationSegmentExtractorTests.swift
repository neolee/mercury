import Foundation
import Testing
@testable import Mercury

@Suite("Translation Segment Extractor")
struct TranslationSegmentExtractorTests {
    @Test("Extractor is deterministic for same markdown")
    func extractorDeterministic() throws {
        let markdown = """
        First paragraph.

        - Apple
        - Banana

        Second paragraph.

        1. One
        2. Two
        """

        let first = try TranslationSegmentExtractor.extract(entryId: 42, markdown: markdown)
        let second = try TranslationSegmentExtractor.extract(entryId: 42, markdown: markdown)

        #expect(first.segmenterVersion == TranslationSegmentationContract.segmenterVersion)
        #expect(first.sourceContentHash == second.sourceContentHash)
        #expect(first.segments == second.segments)
        #expect(first.segments.map(\.segmentType) == [.p, .ul, .p, .ol])
        #expect(first.segments.map(\.orderIndex) == [0, 1, 2, 3])
    }

    @Test("Paragraphs inside list do not create duplicate p segments")
    func listParagraphsDoNotDuplicateSegments() throws {
        let renderedHTML = """
        <!doctype html>
        <html>
        <body>
          <article class="reader">
            <p>Lead</p>
            <ul>
              <li><p>A</p></li>
              <li><p>B</p></li>
            </ul>
            <ol>
              <li><p>1</p></li>
            </ol>
          </article>
        </body>
        </html>
        """

        let snapshot = try TranslationSegmentExtractor.extractFromRenderedHTML(entryId: 7, renderedHTML: renderedHTML)

        #expect(snapshot.segments.count == 3)
        #expect(snapshot.segments.map(\.segmentType) == [.p, .ul, .ol])
    }

    @Test("Source content hash changes when segment-relevant content changes")
    func sourceContentHashChangesOnRelevantContentChange() throws {
        let markdownA = """
        Alpha paragraph.

        - One
        - Two
        """

        let markdownB = """
        Beta paragraph.

        - One
        - Two
        """

        let snapshotA = try TranslationSegmentExtractor.extract(entryId: 9, markdown: markdownA)
        let snapshotB = try TranslationSegmentExtractor.extract(entryId: 9, markdown: markdownB)

        #expect(snapshotA.sourceContentHash != snapshotB.sourceContentHash)
        #expect(snapshotA.segments.first?.sourceSegmentId != snapshotB.segments.first?.sourceSegmentId)
    }

    @Test("Extractor skips segments whose source text is empty")
    func skipsEmptySourceTextSegments() throws {
        let renderedHTML = """
        <!doctype html>
        <html>
        <body>
          <article class="reader">
            <p><img src="https://example.com/a.jpg" alt=""></p>
            <ul><li><img src="https://example.com/b.jpg" alt=""></li></ul>
            <p>Body paragraph</p>
            <ul><li>Item text</li></ul>
          </article>
        </body>
        </html>
        """

        let snapshot = try TranslationSegmentExtractor.extractFromRenderedHTML(entryId: 10, renderedHTML: renderedHTML)

        #expect(snapshot.segments.count == 2)
        #expect(snapshot.segments.map(\.segmentType) == [.p, .ul])
        #expect(snapshot.segments.map(\.orderIndex) == [0, 1])
        #expect(snapshot.segments.allSatisfy { segment in
            segment.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        })
    }
}
