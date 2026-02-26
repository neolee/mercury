import Foundation
import Testing
@testable import Mercury

@Suite("Translation Bilingual Composer")
struct TranslationBilingualComposerTests {
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
        let snapshot = try TranslationSegmentExtractor.extractFromRenderedHTML(entryId: 1, renderedHTML: html)
        let translated = Dictionary(uniqueKeysWithValues: snapshot.segments.map { segment in
            (segment.sourceSegmentId, "TR-\(segment.orderIndex)")
        })

        let result = try TranslationBilingualComposer.compose(
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
        let result = try TranslationBilingualComposer.compose(
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
        let snapshot = try TranslationSegmentExtractor.extractFromRenderedHTML(entryId: 3, renderedHTML: html)
        #expect(snapshot.segments.count == 1)

        let result = try TranslationBilingualComposer.compose(
            renderedHTML: html,
            entryId: 3,
            translatedBySegmentID: [snapshot.segments[0].sourceSegmentId: "OK"],
            missingStatusText: nil
        )
        #expect(result.html.contains("OK"))
    }

    @Test("Compose can prepend header translation block")
    func prependsHeaderTranslation() throws {
        let html = """
        <!doctype html>
        <html><head></head><body>
        <article class="reader">
          <p>Body</p>
        </article>
        </body></html>
        """
        let result = try TranslationBilingualComposer.compose(
            renderedHTML: html,
            entryId: 4,
            translatedBySegmentID: [:],
            missingStatusText: nil,
            headerTranslatedText: "Title\\nAuthor",
            headerStatusText: nil
        )
        #expect(result.html.contains("Title\\nAuthor"))
    }

    @Test("Header translation is inserted after byline paragraph")
    func headerTranslationAfterByline() throws {
        let html = """
        <!doctype html>
        <html><head></head><body>
        <article class="reader">
          <h1>Original Title</h1>
          <p><em>Author Name</em></p>
          <p>Body paragraph</p>
        </article>
        </body></html>
        """
        let result = try TranslationBilingualComposer.compose(
            renderedHTML: html,
            entryId: 5,
            translatedBySegmentID: [:],
            missingStatusText: nil,
            headerTranslatedText: "Translated Header",
            headerStatusText: nil
        )

        let authorRange = result.html.range(of: "Author Name")
        let headerRange = result.html.range(of: "Translated Header")
        let bodyRange = result.html.range(of: "Body paragraph")

        #expect(authorRange != nil)
        #expect(headerRange != nil)
        #expect(bodyRange != nil)
        if let authorRange, let headerRange {
            #expect(authorRange.upperBound <= headerRange.lowerBound)
        }
        if let headerRange, let bodyRange {
            #expect(headerRange.upperBound <= bodyRange.lowerBound)
        }
    }

    @Test("Header translation suppresses duplicated byline segment translation block")
    func headerTranslationSuppressesBylineSegmentTranslation() throws {
        let html = """
        <!doctype html>
        <html><head></head><body>
        <article class="reader">
          <h1>Original Title</h1>
          <p><em>Author Name</em></p>
          <p>Body paragraph</p>
        </article>
        </body></html>
        """
        let snapshot = try TranslationSegmentExtractor.extractFromRenderedHTML(entryId: 8, renderedHTML: html)
        #expect(snapshot.segments.count == 2)
        let translatedBySegmentID = Dictionary(uniqueKeysWithValues: snapshot.segments.map { segment in
            (segment.sourceSegmentId, segment.orderIndex == 0 ? "BYLINE_TRANSLATED" : "BODY_TRANSLATED")
        })

        let result = try TranslationBilingualComposer.compose(
            renderedHTML: html,
            entryId: 8,
            translatedBySegmentID: translatedBySegmentID,
            missingStatusText: nil,
            headerTranslatedText: "HEADER_TRANSLATED",
            headerStatusText: nil
        )

        #expect(result.html.contains("HEADER_TRANSLATED"))
        #expect(result.html.contains("BODY_TRANSLATED"))
        #expect(result.html.contains("BYLINE_TRANSLATED"))
        #expect(result.html.components(separatedBy: "BYLINE_TRANSLATED").count == 2)
    }

    @Test("Header translation merges suppressed byline translation when header has one line")
    func headerTranslationMergesSuppressedBylineWhenHeaderSingleLine() throws {
        let html = """
        <!doctype html>
        <html><head></head><body>
        <article class="reader">
          <h1>Original Title</h1>
          <p><em>Author Name</em></p>
          <p>Body paragraph</p>
        </article>
        </body></html>
        """
        let snapshot = try TranslationSegmentExtractor.extractFromRenderedHTML(entryId: 9, renderedHTML: html)
        #expect(snapshot.segments.count == 2)
        let translatedBySegmentID = Dictionary(uniqueKeysWithValues: snapshot.segments.map { segment in
            (segment.sourceSegmentId, segment.orderIndex == 0 ? "BYLINE_TRANSLATED" : "BODY_TRANSLATED")
        })

        let result = try TranslationBilingualComposer.compose(
            renderedHTML: html,
            entryId: 9,
            translatedBySegmentID: translatedBySegmentID,
            missingStatusText: nil,
            headerTranslatedText: "TITLE_TRANSLATED",
            headerStatusText: nil
        )

        #expect(result.html.contains("TITLE_TRANSLATED\nBYLINE_TRANSLATED"))
        #expect(result.html.contains("BODY_TRANSLATED"))
    }

    @Test("Translation block style keeps structural spacing and layout rules")
    func translationBlockStyleSpacingContract() throws {
        let html = """
        <!doctype html>
        <html><head></head><body>
        <article class="reader">
          <p>Body</p>
        </article>
        </body></html>
        """
        let snapshot = try TranslationSegmentExtractor.extractFromRenderedHTML(entryId: 6, renderedHTML: html)
        let translated = [snapshot.segments[0].sourceSegmentId: "Translated"]
        let result = try TranslationBilingualComposer.compose(
            renderedHTML: html,
            entryId: 6,
            translatedBySegmentID: translated,
            missingStatusText: nil
        )

        #expect(result.html.contains(".mercury-translation-block {"))
        #expect(result.html.contains("margin:"))
        #expect(result.html.contains("padding:"))
        #expect(result.html.contains("display: flex;"))
        #expect(result.html.contains("gap:"))
        #expect(result.html.contains("p + .mercury-translation-block"))
        #expect(result.html.contains(".mercury-translation-block + p"))
    }

    @Test("Compose trims trailing blank lines for translated text rendering")
    func trimsTrailingBlankLinesForDisplay() throws {
        let html = """
        <!doctype html>
        <html><head></head><body>
        <article class="reader">
          <p>Body</p>
        </article>
        </body></html>
        """
        let snapshot = try TranslationSegmentExtractor.extractFromRenderedHTML(entryId: 7, renderedHTML: html)
        let translated = [snapshot.segments[0].sourceSegmentId: "Line A\n\n"]
        let result = try TranslationBilingualComposer.compose(
            renderedHTML: html,
            entryId: 7,
            translatedBySegmentID: translated,
            missingStatusText: nil
        )

        let marker = "<div class=\"mercury-translation-text\">"
        let renderedText: String? = {
            guard let markerRange = result.html.range(of: marker) else { return nil }
            let textStart = markerRange.upperBound
            guard let closeRange = result.html[textStart...].range(of: "</div>") else { return nil }
            return String(result.html[textStart..<closeRange.lowerBound])
        }()
        #expect(renderedText == "Line A")
    }

    @Test("Compose renders failed segments with retry action URL")
    func failedSegmentsContainRetryActionURL() throws {
        let html = """
        <!doctype html>
        <html><head></head><body>
        <article class="reader">
          <p>Body</p>
        </article>
        </body></html>
        """
        let snapshot = try TranslationSegmentExtractor.extractFromRenderedHTML(entryId: 11, renderedHTML: html)
        let segmentID = snapshot.segments[0].sourceSegmentId

        let result = try TranslationBilingualComposer.compose(
            renderedHTML: html,
            entryId: 11,
            translatedBySegmentID: [:],
            missingStatusText: nil,
            pendingSegmentIDs: [],
            failedSegmentIDs: [segmentID],
            pendingStatusText: "Generating...",
            failedStatusText: "No translation",
            retryActionContext: TranslationRetryActionContext(entryId: 11, slotKey: "zh-Hans")
        )

        #expect(result.html.contains("No translation"))
        #expect(result.html.contains("mercury-action://translation/retry-segment"))
        #expect(result.html.contains("segmentId="))
    }

    @Test("Compose does not render retry for empty source segments")
    func emptySourceSegmentsDoNotRenderRetry() throws {
        let html = """
        <!doctype html>
        <html><head></head><body>
        <article class="reader">
          <p><img src="https://example.com/pic.jpg" alt=""></p>
          <p>Body</p>
        </article>
        </body></html>
        """
        let snapshot = try TranslationSegmentExtractor.extractFromRenderedHTML(entryId: 13, renderedHTML: html)
        #expect(snapshot.segments.count == 1)
        guard let textSegment = snapshot.segments.first else { return }

        let result = try TranslationBilingualComposer.compose(
            renderedHTML: html,
            entryId: 13,
            translatedBySegmentID: [:],
            missingStatusText: nil,
            pendingSegmentIDs: [],
            failedSegmentIDs: Set(snapshot.segments.map(\.sourceSegmentId)),
            pendingStatusText: "Generating...",
            failedStatusText: "No translation",
            retryActionContext: TranslationRetryActionContext(entryId: 13, slotKey: "zh-Hans")
        )

        #expect(result.html.contains("segmentId=\(textSegment.sourceSegmentId)"))
    }

    @Test("Compose keeps insertion position stable after filtered empty paragraph")
    func insertionPositionStableAfterFilteredEmptyParagraph() throws {
        let html = """
        <!doctype html>
        <html><head></head><body>
        <article class="reader">
          <p><img src="https://example.com/pic.jpg" alt=""></p>
          <p>Body A</p>
          <p>Body B</p>
        </article>
        </body></html>
        """
        let snapshot = try TranslationSegmentExtractor.extractFromRenderedHTML(entryId: 14, renderedHTML: html)
        #expect(snapshot.segments.count == 2)

        let translated = [snapshot.segments[0].sourceSegmentId: "BODY_A_TR"]
        let result = try TranslationBilingualComposer.compose(
            renderedHTML: html,
            entryId: 14,
            translatedBySegmentID: translated,
            missingStatusText: nil
        )

        let bodyARange = result.html.range(of: "Body A")
        let translatedRange = result.html.range(of: "BODY_A_TR")
        let bodyBRange = result.html.range(of: "Body B")
        #expect(bodyARange != nil)
        #expect(translatedRange != nil)
        #expect(bodyBRange != nil)
        if let bodyARange, let translatedRange {
            #expect(bodyARange.upperBound <= translatedRange.lowerBound)
        }
        if let translatedRange, let bodyBRange {
            #expect(translatedRange.upperBound <= bodyBRange.lowerBound)
        }
    }

    @Test("Compose renders pending segments with pending status text")
    func pendingSegmentsRenderPendingStatus() throws {
        let html = """
        <!doctype html>
        <html><head></head><body>
        <article class="reader">
          <p>Body</p>
        </article>
        </body></html>
        """
        let snapshot = try TranslationSegmentExtractor.extractFromRenderedHTML(entryId: 12, renderedHTML: html)
        let segmentID = snapshot.segments[0].sourceSegmentId

        let result = try TranslationBilingualComposer.compose(
            renderedHTML: html,
            entryId: 12,
            translatedBySegmentID: [:],
            missingStatusText: "No translation",
            pendingSegmentIDs: [segmentID],
            failedSegmentIDs: [],
            pendingStatusText: "Generating...",
            failedStatusText: "No translation",
            retryActionContext: TranslationRetryActionContext(entryId: 12, slotKey: "zh-Hans")
        )

        #expect(result.html.contains("Generating..."))
        #expect(result.html.contains("mercury-translation-status"))
        #expect(result.html.contains("retry-segment") == false)
    }

    @Test("Compose inserts fallback block when no segment can be mapped")
    func insertsFallbackWhenSegmentMappingMisses() throws {
        let html = """
        <!doctype html>
        <html><head></head><body>
        <article class="reader">
          <div>Body without p ul ol</div>
        </article>
        </body></html>
        """
        let result = try TranslationBilingualComposer.compose(
            renderedHTML: html,
            entryId: 10,
            translatedBySegmentID: ["seg_unmatched": "Fallback translated text"],
            missingStatusText: nil
        )

        #expect(result.snapshot.segments.isEmpty)
        #expect(result.html.contains("Fallback translated text"))
        #expect(result.html.contains("mercury-translation-block"))
    }
}
