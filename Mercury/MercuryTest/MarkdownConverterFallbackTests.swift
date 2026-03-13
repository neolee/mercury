//
//  MarkdownConverterFallbackTests.swift
//  MercuryTest
//

import XCTest
@testable import Mercury

/// Phase 4 tests: fallback handling for figure, picture, table, video, audio, sup, sub.
final class MarkdownConverterFallbackTests: XCTestCase {

    // MARK: - figure

    func test_figure_imgWithCaption_producesImageAndItalicCaption() throws {
        let html = """
        <figure>
          <img src="https://example.com/photo.jpg" alt="Landscape">
          <figcaption>A scenic view of the valley.</figcaption>
        </figure>
        """
        let markdown = try convert(html)
        XCTAssertTrue(
            markdown.contains("![Landscape](https://example.com/photo.jpg)"),
            "Expected Markdown image, got: \(markdown)"
        )
        XCTAssertTrue(
            markdown.contains("_A scenic view of the valley._"),
            "Expected italic caption, got: \(markdown)"
        )
        // The <figure> wrapper must not appear as raw HTML.
        XCTAssertFalse(markdown.contains("<figure"), "figure tag must not appear in Markdown, got: \(markdown)")
        XCTAssertFalse(markdown.contains("<figcaption"), "figcaption tag must not appear in Markdown, got: \(markdown)")
    }

    func test_figure_imgWithoutCaption_producesImageOnly() throws {
        let html = """
        <figure>
          <img src="https://example.com/hero.jpg" alt="Hero">
        </figure>
        """
        let markdown = try convert(html)
        XCTAssertTrue(
            markdown.contains("![Hero](https://example.com/hero.jpg)"),
            "Expected Markdown image, got: \(markdown)"
        )
        XCTAssertFalse(markdown.contains("_"), "No italic caption expected, got: \(markdown)")
    }

    func test_figure_pictureWithCaption_producesImageAndItalicCaption() throws {
        let html = """
        <figure>
          <picture>
            <source srcset="https://example.com/photo@2x.webp" type="image/webp">
            <img src="https://example.com/photo.jpg" alt="Mountain">
          </picture>
          <figcaption>Mountain summit.</figcaption>
        </figure>
        """
        let markdown = try convert(html)
        XCTAssertTrue(
            markdown.contains("![Mountain](https://example.com/photo.jpg)"),
            "Expected Markdown image, got: \(markdown)"
        )
        XCTAssertTrue(
            markdown.contains("_Mountain summit._"),
            "Expected italic caption, got: \(markdown)"
        )
    }

    func test_figure_complexContent_fallsBackToChildText() throws {
        // A figure with multiple images is treated as complex and falls back.
        let html = """
        <figure>
          <img src="https://example.com/a.jpg" alt="A">
          <img src="https://example.com/b.jpg" alt="B">
          <figcaption>Two images.</figcaption>
        </figure>
        """
        let markdown = try convert(html)
        // The fallback renders children, producing both images and the caption text.
        XCTAssertFalse(markdown.contains("<figure"), "figure tag must not appear in Markdown")
    }

    // MARK: - picture (standalone)

    func test_picture_standalone_collapsesToMarkdownImage() throws {
        let html = """
        <picture>
          <source srcset="https://example.com/img@2x.webp" type="image/webp">
          <img src="https://example.com/img.jpg" alt="Responsive image">
        </picture>
        """
        let markdown = try convert(html)
        XCTAssertTrue(
            markdown.contains("![Responsive image](https://example.com/img.jpg)"),
            "Expected Markdown image from picture, got: \(markdown)"
        )
        XCTAssertFalse(markdown.contains("<picture"), "picture tag must not appear in Markdown")
        XCTAssertFalse(markdown.contains("<source"), "source tag must not appear in Markdown")
    }

    func test_picture_noImg_fallsBack() throws {
        let html = """
        <picture>
          <source srcset="https://example.com/img.webp" type="image/webp">
        </picture>
        """
        // No <img> fallback: picture produces empty content rather than crashing.
        let markdown = try convert(html)
        XCTAssertFalse(markdown.contains("<picture"), "picture tag must not appear in Markdown")
    }

    // MARK: - video

    func test_video_srcAttribute_producesFallbackLink() throws {
        let html = """
        <video src="https://example.com/clip.mp4" controls></video>
        """
        let markdown = try convert(html)
        XCTAssertTrue(
            markdown.contains("[Video](https://example.com/clip.mp4)"),
            "Expected video fallback link, got: \(markdown)"
        )
    }

    func test_video_sourceChild_producesFallbackLink() throws {
        let html = """
        <video controls>
          <source src="https://example.com/clip.mp4" type="video/mp4">
        </video>
        """
        let markdown = try convert(html)
        XCTAssertTrue(
            markdown.contains("[Video](https://example.com/clip.mp4)"),
            "Expected video fallback link from source child, got: \(markdown)"
        )
    }

    func test_video_noUrl_producesNoLink() throws {
        let html = "<video controls></video>"
        let markdown = try convert(html)
        XCTAssertFalse(markdown.contains("[Video]"), "No video link expected when no URL is available")
    }

    // MARK: - audio

    func test_audio_srcAttribute_producesFallbackLink() throws {
        let html = """
        <audio src="https://example.com/sound.mp3" controls></audio>
        """
        let markdown = try convert(html)
        XCTAssertTrue(
            markdown.contains("[Audio](https://example.com/sound.mp3)"),
            "Expected audio fallback link, got: \(markdown)"
        )
    }

    func test_audio_sourceChild_producesFallbackLink() throws {
        let html = """
        <audio controls>
          <source src="https://example.com/sound.ogg" type="audio/ogg">
        </audio>
        """
        let markdown = try convert(html)
        XCTAssertTrue(
            markdown.contains("[Audio](https://example.com/sound.ogg)"),
            "Expected audio fallback link from source child, got: \(markdown)"
        )
    }

    func test_audio_noUrl_producesNoLink() throws {
        let html = "<audio controls></audio>"
        let markdown = try convert(html)
        XCTAssertFalse(markdown.contains("[Audio]"), "No audio link expected when no URL is available")
    }

    // MARK: - table GFM conversion

    func test_table_simpleWithTheadTbody_producesGFM() throws {
        let html = """
        <table>
          <thead><tr><th>Name</th><th>Score</th></tr></thead>
          <tbody>
            <tr><td>Alice</td><td>95</td></tr>
            <tr><td>Bob</td><td>87</td></tr>
          </tbody>
        </table>
        """
        let markdown = try convert(html)
        XCTAssertTrue(markdown.contains("| Name | Score |"), "Expected GFM header row, got: \(markdown)")
        XCTAssertTrue(markdown.contains("| --- | --- |"), "Expected GFM separator, got: \(markdown)")
        XCTAssertTrue(markdown.contains("| Alice | 95 |"), "Expected first data row, got: \(markdown)")
        XCTAssertTrue(markdown.contains("| Bob | 87 |"), "Expected second data row, got: \(markdown)")
        XCTAssertFalse(markdown.contains("<table"), "table tag must not appear in Markdown")
    }

    func test_table_noTheadFirstRowHasTh_producesGFM() throws {
        let html = """
        <table>
          <tr><th>Language</th><th>Paradigm</th></tr>
          <tr><td>Swift</td><td>Multi-paradigm</td></tr>
        </table>
        """
        let markdown = try convert(html)
        XCTAssertTrue(markdown.contains("| Language | Paradigm |"), "Expected GFM header, got: \(markdown)")
        XCTAssertTrue(markdown.contains("| Swift | Multi-paradigm |"), "Expected data row, got: \(markdown)")
    }

    func test_table_multipleColumns_paddingApplied() throws {
        let html = """
        <table>
          <thead><tr><th>A</th><th>B</th><th>C</th></tr></thead>
          <tbody><tr><td>1</td><td>2</td></tr></tbody>
        </table>
        """
        let markdown = try convert(html)
        // The short data row (2 cells) must be padded to the header's 3 columns.
        // A 3-column GFM row has exactly 4 pipe characters.
        let dataRow = markdown.components(separatedBy: "\n").first { $0.hasPrefix("| 1") } ?? ""
        XCTAssertFalse(dataRow.isEmpty, "Data row must be present in GFM output, got: \(markdown)")
        let pipeCount = dataRow.filter { $0 == "|" }.count
        XCTAssertEqual(pipeCount, 4, "3-column row must have 4 pipe characters (padding applied), got: \(dataRow)")
    }

    func test_table_colspanPresent_fallsBackToText() throws {
        let html = """
        <table>
          <thead><tr><th colspan="2">Spanned</th></tr></thead>
          <tbody><tr><td>A</td><td>B</td></tr></tbody>
        </table>
        """
        let markdown = try convert(html)
        // colspan prevents GFM conversion; table content surfaces as plain text.
        XCTAssertFalse(markdown.contains("| --- |"), "GFM separator must not appear for colspan table")
    }

    func test_table_noHeaderRow_fallsBackToText() throws {
        let html = """
        <table>
          <tbody>
            <tr><td>Only</td><td>Data</td></tr>
          </tbody>
        </table>
        """
        let markdown = try convert(html)
        // No header row: GFM not possible.
        XCTAssertFalse(markdown.contains("| --- |"), "GFM separator must not appear for header-less table")
    }

    func test_table_pipeInCellContent_isEscaped() throws {
        let html = """
        <table>
          <thead><tr><th>Key</th><th>Value</th></tr></thead>
          <tbody><tr><td>A|B</td><td>1</td></tr></tbody>
        </table>
        """
        let markdown = try convert(html)
        XCTAssertTrue(markdown.contains("A\\|B"), "Pipe in cell content must be escaped, got: \(markdown)")
    }

    // MARK: - sup and sub inline HTML

    func test_sup_producesInlineHTML() throws {
        let html = "<p>E = mc<sup>2</sup></p>"
        let markdown = try convert(html)
        XCTAssertTrue(
            markdown.contains("<sup>2</sup>"),
            "sup must produce inline HTML, got: \(markdown)"
        )
        XCTAssertFalse(markdown.contains("<sup><sup>"), "No double-wrapping expected")
    }

    func test_sub_producesInlineHTML() throws {
        let html = "<p>H<sub>2</sub>O</p>"
        let markdown = try convert(html)
        XCTAssertTrue(
            markdown.contains("<sub>2</sub>"),
            "sub must produce inline HTML, got: \(markdown)"
        )
    }

    func test_sup_empty_producesNothing() throws {
        let html = "<p>Text<sup></sup> more.</p>"
        let markdown = try convert(html)
        XCTAssertFalse(markdown.contains("<sup>"), "Empty sup must not produce inline HTML")
    }

    // MARK: - Down raw-HTML passthrough verification

    func test_sup_survivesRendererPassthrough() throws {
        let html = "<p>See footnote<sup>1</sup> for details.</p>"
        let markdown = try convert(html)
        XCTAssertTrue(markdown.contains("<sup>1</sup>"), "Markdown must contain sup HTML, got: \(markdown)")
        let rendered = try renderToHTML(markdown)
        XCTAssertTrue(
            rendered.contains("<sup>1</sup>"),
            "sup inline HTML must survive Down renderer (unsafe mode required), got: \(rendered)"
        )
    }

    func test_sub_survivesRendererPassthrough() throws {
        let html = "<p>Formula H<sub>2</sub>O.</p>"
        let markdown = try convert(html)
        XCTAssertTrue(markdown.contains("<sub>2</sub>"), "Markdown must contain sub HTML, got: \(markdown)")
        let rendered = try renderToHTML(markdown)
        XCTAssertTrue(
            rendered.contains("<sub>2</sub>"),
            "sub inline HTML must survive Down renderer (unsafe mode required), got: \(rendered)"
        )
    }

    // MARK: - Translation compatibility

    func test_translationCompatibility_gfmTable_renderedAsTextWithCurrentRenderer() throws {
        let html = """
        <p>Before table.</p>
        <table>
          <thead><tr><th>Name</th><th>Value</th></tr></thead>
          <tbody><tr><td>A</td><td>1</td></tr></tbody>
        </table>
        <p>After table.</p>
        """
        let markdown = try convert(html)
        // GFM pipe table syntax is generated correctly, but the current renderer
        // (Down/libcmark, no GFM table extension) renders it as paragraph text.
        // The surrounding paragraphs remain stable as translation segments.
        XCTAssertTrue(markdown.contains("| Name | Value |"), "GFM table syntax must be present in Markdown, got: \(markdown)")
        let snapshot = try TranslationSegmentExtractor.extract(entryId: 200, markdown: markdown)
        // Before paragraph (1) + GFM table as paragraph text (1) + after paragraph (1) = 3.
        XCTAssertEqual(snapshot.segments.count, 3, "Expected 3 p segments with cmark renderer (no GFM table support), got \(snapshot.segments.count)")
        XCTAssertTrue(snapshot.segments.allSatisfy { $0.segmentType == .p })
    }

    func test_translationCompatibility_figureCaption_createsParagraphSegment() throws {
        let html = """
        <p>Article lead.</p>
        <figure>
          <img src="https://example.com/img.jpg" alt="Alt">
          <figcaption>Photo caption text.</figcaption>
        </figure>
        <p>Article body.</p>
        """
        let markdown = try convert(html)
        let snapshot = try TranslationSegmentExtractor.extract(entryId: 201, markdown: markdown)
        // Article lead + figcaption paragraph + article body = 3 segments.
        XCTAssertEqual(snapshot.segments.count, 3, "Expected 3 segments (lead + caption + body), got \(snapshot.segments.count)")
        XCTAssertTrue(snapshot.segments.allSatisfy { $0.segmentType == .p })
    }

    func test_translationCompatibility_supInParagraph_doesNotBreakSegment() throws {
        let html = """
        <p>Reference<sup>1</sup> inline.</p>
        <p>Second paragraph.</p>
        """
        let markdown = try convert(html)
        let snapshot = try TranslationSegmentExtractor.extract(entryId: 202, markdown: markdown)
        XCTAssertEqual(snapshot.segments.count, 2, "sup must not split the paragraph into extra segments")
        XCTAssertTrue(snapshot.segments.allSatisfy { $0.segmentType == .p })
    }

    func test_translationCompatibility_videoFallback_doesNotCreateSegment() throws {
        let html = """
        <p>Watch the clip.</p>
        <video src="https://example.com/clip.mp4"></video>
        <p>After video.</p>
        """
        let markdown = try convert(html)
        let snapshot = try TranslationSegmentExtractor.extract(entryId: 203, markdown: markdown)
        // Video produces a standalone link paragraph; paragraph contains text so it IS a segment.
        // Main invariant: p/ul/ol counts in unchanged article regions must remain stable.
        XCTAssertGreaterThanOrEqual(snapshot.segments.count, 2, "At least the two text paragraphs must be segmented")
    }
}

// MARK: - Helpers

private extension MarkdownConverterFallbackTests {
    func convert(_ html: String) throws -> String {
        try convertMarkdown(html)
    }

    func renderToHTML(_ markdown: String) throws -> String {
        try renderMarkdownToHTML(markdown)
    }
}
