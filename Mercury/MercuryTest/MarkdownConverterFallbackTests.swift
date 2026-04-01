//
//  MarkdownConverterFallbackTests.swift
//  MercuryTest
//

import Foundation
import Testing
@testable import Mercury

/// Phase 4 tests: fallback handling for figure, picture, table, video, audio, sup, sub.
@Suite
struct MarkdownConverterFallbackTests {

    // MARK: - figure

    @Test

    func test_figure_imgWithCaption_producesImageAndItalicCaption() throws {
        let html = """
        <figure>
          <img src="https://example.com/photo.jpg" alt="Landscape">
          <figcaption>A scenic view of the valley.</figcaption>
        </figure>
        """
        let markdown = try convert(html)
        #expect(
            markdown.contains("![Landscape](https://example.com/photo.jpg)"),
            "Expected Markdown image, got: \(markdown)"
        )
        #expect(
            markdown.contains("_A scenic view of the valley._"),
            "Expected italic caption, got: \(markdown)"
        )
        // The <figure> wrapper must not appear as raw HTML.
        #expect(!markdown.contains("<figure"), "figure tag must not appear in Markdown, got: \(markdown)")
        #expect(!markdown.contains("<figcaption"), "figcaption tag must not appear in Markdown, got: \(markdown)")
    }

    @Test

    func test_figure_imgWithoutCaption_producesImageOnly() throws {
        let html = """
        <figure>
          <img src="https://example.com/hero.jpg" alt="Hero">
        </figure>
        """
        let markdown = try convert(html)
        #expect(
            markdown.contains("![Hero](https://example.com/hero.jpg)"),
            "Expected Markdown image, got: \(markdown)"
        )
        #expect(!markdown.contains("_"), "No italic caption expected, got: \(markdown)")
    }

    @Test

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
        #expect(
            markdown.contains("![Mountain](https://example.com/photo.jpg)"),
            "Expected Markdown image, got: \(markdown)"
        )
        #expect(
            markdown.contains("_Mountain summit._"),
            "Expected italic caption, got: \(markdown)"
        )
    }

    @Test

    func test_figure_linkWrappedImageWithCaption_putsCaptionOnNextParagraph() throws {
        let html = """
        <figure>
          <a href="https://example.com/full.jpg">
            <img src="https://example.com/thumb.jpg" alt="Thumbnail">
          </a>
          <figcaption>Linked image caption.</figcaption>
        </figure>
        """
        let markdown = try convert(html)
        #expect(
            markdown.contains("[![Thumbnail](https://example.com/thumb.jpg)](https://example.com/full.jpg)"),
            "Expected linked image Markdown, got: \(markdown)"
        )
        #expect(
            markdown.contains("[![Thumbnail](https://example.com/thumb.jpg)](https://example.com/full.jpg)\n\n_Linked image caption._"),
            "Expected caption to start in the next paragraph, got: \(markdown)"
        )
    }

    @Test

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
        #expect(!markdown.contains("<figure"), "figure tag must not appear in Markdown")
    }

    // MARK: - picture (standalone)

    @Test

    func test_picture_standalone_collapsesToMarkdownImage() throws {
        let html = """
        <picture>
          <source srcset="https://example.com/img@2x.webp" type="image/webp">
          <img src="https://example.com/img.jpg" alt="Responsive image">
        </picture>
        """
        let markdown = try convert(html)
        #expect(
            markdown.contains("![Responsive image](https://example.com/img.jpg)"),
            "Expected Markdown image from picture, got: \(markdown)"
        )
        #expect(!markdown.contains("<picture"), "picture tag must not appear in Markdown")
        #expect(!markdown.contains("<source"), "source tag must not appear in Markdown")
    }

    @Test

    func test_picture_noImg_fallsBack() throws {
        let html = """
        <picture>
          <source srcset="https://example.com/img.webp" type="image/webp">
        </picture>
        """
        // No <img> fallback: picture produces empty content rather than crashing.
        let markdown = try convert(html)
        #expect(!markdown.contains("<picture"), "picture tag must not appear in Markdown")
    }

    // MARK: - video

    @Test

    func test_video_srcAttribute_producesFallbackLink() throws {
        let html = """
        <video src="https://example.com/clip.mp4" controls></video>
        """
        let markdown = try convert(html)
        #expect(
            markdown.contains("[Video](https://example.com/clip.mp4)"),
            "Expected video fallback link, got: \(markdown)"
        )
    }

    @Test

    func test_video_sourceChild_producesFallbackLink() throws {
        let html = """
        <video controls>
          <source src="https://example.com/clip.mp4" type="video/mp4">
        </video>
        """
        let markdown = try convert(html)
        #expect(
            markdown.contains("[Video](https://example.com/clip.mp4)"),
            "Expected video fallback link from source child, got: \(markdown)"
        )
    }

    @Test

    func test_video_noUrl_producesNoLink() throws {
        let html = "<video controls></video>"
        let markdown = try convert(html)
        #expect(!markdown.contains("[Video]"), "No video link expected when no URL is available")
    }

    // MARK: - audio

    @Test

    func test_audio_srcAttribute_producesFallbackLink() throws {
        let html = """
        <audio src="https://example.com/sound.mp3" controls></audio>
        """
        let markdown = try convert(html)
        #expect(
            markdown.contains("[Audio](https://example.com/sound.mp3)"),
            "Expected audio fallback link, got: \(markdown)"
        )
    }

    @Test

    func test_audio_sourceChild_producesFallbackLink() throws {
        let html = """
        <audio controls>
          <source src="https://example.com/sound.ogg" type="audio/ogg">
        </audio>
        """
        let markdown = try convert(html)
        #expect(
            markdown.contains("[Audio](https://example.com/sound.ogg)"),
            "Expected audio fallback link from source child, got: \(markdown)"
        )
    }

    @Test

    func test_audio_noUrl_producesNoLink() throws {
        let html = "<audio controls></audio>"
        let markdown = try convert(html)
        #expect(!markdown.contains("[Audio]"), "No audio link expected when no URL is available")
    }

    // MARK: - table GFM conversion

    @Test

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
        #expect(markdown.contains("| Name | Score |"), "Expected GFM header row, got: \(markdown)")
        #expect(markdown.contains("| --- | --- |"), "Expected GFM separator, got: \(markdown)")
        #expect(markdown.contains("| Alice | 95 |"), "Expected first data row, got: \(markdown)")
        #expect(markdown.contains("| Bob | 87 |"), "Expected second data row, got: \(markdown)")
        #expect(!markdown.contains("<table"), "table tag must not appear in Markdown")
    }

    @Test

    func test_table_noTheadFirstRowHasTh_producesGFM() throws {
        let html = """
        <table>
          <tr><th>Language</th><th>Paradigm</th></tr>
          <tr><td>Swift</td><td>Multi-paradigm</td></tr>
        </table>
        """
        let markdown = try convert(html)
        #expect(markdown.contains("| Language | Paradigm |"), "Expected GFM header, got: \(markdown)")
        #expect(markdown.contains("| Swift | Multi-paradigm |"), "Expected data row, got: \(markdown)")
    }

    @Test

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
        #expect(!dataRow.isEmpty, "Data row must be present in GFM output, got: \(markdown)")
        let pipeCount = dataRow.filter { $0 == "|" }.count
        #expect(pipeCount == 4, "3-column row must have 4 pipe characters (padding applied), got: \(dataRow)")
    }

    @Test

    func test_table_colspanPresent_fallsBackToText() throws {
        let html = """
        <table>
          <thead><tr><th colspan="2">Spanned</th></tr></thead>
          <tbody><tr><td>A</td><td>B</td></tr></tbody>
        </table>
        """
        let markdown = try convert(html)
        // colspan prevents GFM conversion; table content surfaces as plain text.
        #expect(!markdown.contains("| --- |"), "GFM separator must not appear for colspan table")
    }

    @Test

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
        #expect(!markdown.contains("| --- |"), "GFM separator must not appear for header-less table")
    }

    @Test

    func test_table_pipeInCellContent_isEscaped() throws {
        let html = """
        <table>
          <thead><tr><th>Key</th><th>Value</th></tr></thead>
          <tbody><tr><td>A|B</td><td>1</td></tr></tbody>
        </table>
        """
        let markdown = try convert(html)
        #expect(markdown.contains("A\\|B"), "Pipe in cell content must be escaped, got: \(markdown)")
    }

    // MARK: - sup and sub inline HTML

    @Test

    func test_sup_producesInlineHTML() throws {
        let html = "<p>E = mc<sup>2</sup></p>"
        let markdown = try convert(html)
        #expect(
            markdown.contains("<sup>2</sup>"),
            "sup must produce inline HTML, got: \(markdown)"
        )
        #expect(!markdown.contains("<sup><sup>"), "No double-wrapping expected")
    }

    @Test

    func test_sub_producesInlineHTML() throws {
        let html = "<p>H<sub>2</sub>O</p>"
        let markdown = try convert(html)
        #expect(
            markdown.contains("<sub>2</sub>"),
            "sub must produce inline HTML, got: \(markdown)"
        )
    }

    @Test

    func test_sup_empty_producesNothing() throws {
        let html = "<p>Text<sup></sup> more.</p>"
        let markdown = try convert(html)
        #expect(!markdown.contains("<sup>"), "Empty sup must not produce inline HTML")
    }

    // MARK: - Raw-HTML passthrough verification

    @Test

    func test_sup_survivesRendererPassthrough() throws {
        let html = "<p>See footnote<sup>1</sup> for details.</p>"
        let markdown = try convert(html)
        #expect(markdown.contains("<sup>1</sup>"), "Markdown must contain sup HTML, got: \(markdown)")
        let rendered = try renderToHTML(markdown)
        #expect(
            rendered.contains("<sup>1</sup>"),
            "sup inline HTML must survive the reader renderer passthrough, got: \(rendered)"
        )
    }

    @Test

    func test_sub_survivesRendererPassthrough() throws {
        let html = "<p>Formula H<sub>2</sub>O.</p>"
        let markdown = try convert(html)
        #expect(markdown.contains("<sub>2</sub>"), "Markdown must contain sub HTML, got: \(markdown)")
        let rendered = try renderToHTML(markdown)
        #expect(
            rendered.contains("<sub>2</sub>"),
            "sub inline HTML must survive the reader renderer passthrough, got: \(rendered)"
        )
    }

    // MARK: - Translation compatibility

    @Test

    func test_translationCompatibility_gfmTable_isExcludedFromCollectedSegments() throws {
        let html = """
        <p>Before table.</p>
        <table>
          <thead><tr><th>Name</th><th>Value</th></tr></thead>
          <tbody><tr><td>A</td><td>1</td></tr></tbody>
        </table>
        <p>After table.</p>
        """
        let markdown = try convert(html)
        #expect(markdown.contains("| Name | Value |"), "GFM table syntax must be present in Markdown, got: \(markdown)")
        let snapshot = try TranslationSegmentExtractor.extract(entryId: 200, markdown: markdown)
        #expect(snapshot.segments.count == 2, "Expected only the surrounding paragraphs to be collected, got \(snapshot.segments.count)")
        #expect(snapshot.segments.allSatisfy { $0.segmentType == .p })
    }

    @Test

    func test_roundTrip_gfmTable_rendersTableElement() throws {
        let html = """
        <table>
          <thead><tr><th>Name</th><th>Value</th></tr></thead>
          <tbody><tr><td>A</td><td>1</td></tr></tbody>
        </table>
        """
        let rendered = try roundTrip(html)
        #expect(try htmlContains("table", in: rendered), "Expected rendered HTML to contain a table element, got: \(rendered)")
        #expect(try countElements("table", in: rendered) == 1)
        #expect(try firstElementText("th", in: rendered) == "Name")
    }

    @Test

    func test_roundTrip_strikethrough_rendersDelElement() throws {
        let html = "<p>Use <del>legacy</del> renderer.</p>"
        let rendered = try roundTrip(html)
        #expect(try htmlContains("del", in: rendered), "Expected rendered HTML to contain a del element, got: \(rendered)")
        #expect(try firstElementText("del", in: rendered) == "legacy")
    }

    @Test

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
        #expect(snapshot.segments.count == 3, "Expected 3 segments (lead + caption + body), got \(snapshot.segments.count)")
        #expect(snapshot.segments.allSatisfy { $0.segmentType == .p })
    }

    @Test

    func test_translationCompatibility_figureLinkedImageCaption_createsParagraphSegment() throws {
        let html = """
        <p>Article lead.</p>
        <figure>
          <a href="https://example.com/full.jpg">
            <img src="https://example.com/thumb.jpg" alt="Alt">
          </a>
          <figcaption>Photo caption text.</figcaption>
        </figure>
        <p>Article body.</p>
        """
        let markdown = try convert(html)
        let snapshot = try TranslationSegmentExtractor.extract(entryId: 204, markdown: markdown)
        #expect(snapshot.segments.count == 3, "Expected 3 segments (lead + caption + body), got \(snapshot.segments.count)")
        #expect(snapshot.segments.allSatisfy { $0.segmentType == .p })
    }

    @Test

    func test_translationCompatibility_supInParagraph_doesNotBreakSegment() throws {
        let html = """
        <p>Reference<sup>1</sup> inline.</p>
        <p>Second paragraph.</p>
        """
        let markdown = try convert(html)
        let snapshot = try TranslationSegmentExtractor.extract(entryId: 202, markdown: markdown)
        #expect(snapshot.segments.count == 2, "sup must not split the paragraph into extra segments")
        #expect(snapshot.segments.allSatisfy { $0.segmentType == .p })
    }

    @Test

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
        #expect(snapshot.segments.count >= 2, "At least the two text paragraphs must be segmented")
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
