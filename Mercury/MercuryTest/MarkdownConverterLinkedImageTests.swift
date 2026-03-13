//
//  MarkdownConverterLinkedImageTests.swift
//  MercuryTest
//

import XCTest
@testable import Mercury

/// Phase 2 tests: linked-image regression and round-trip fidelity.
final class MarkdownConverterLinkedImageTests: XCTestCase {

    // MARK: - Unit tests: exact Markdown output

    func test_linkedImage_aImg_producesNestedImageMarkdown() throws {
        let html = """
        <p><a href="https://example.com/target"><img src="https://cdn.example.com/img.jpg" alt="Alt text"></a></p>
        """
        let markdown = try convert(html)
        XCTAssertTrue(
            markdown.contains("[![Alt text](https://cdn.example.com/img.jpg)](https://example.com/target)"),
            "Expected nested image markdown, got: \(markdown)"
        )
    }

    func test_linkedImage_aImg_emptyAlt_producesNestedImageMarkdown() throws {
        let html = """
        <p><a href="https://t.co/link"><img src="https://cdn.example.com/photo.jpg" alt=""></a></p>
        """
        let markdown = try convert(html)
        XCTAssertTrue(
            markdown.contains("[![](https://cdn.example.com/photo.jpg)](https://t.co/link)"),
            "Expected empty-alt linked image markdown, got: \(markdown)"
        )
    }

    func test_linkedImage_noUrlFallback_srcNotSurfacedAsLinkText() throws {
        let href = "https://example.com/target"
        let src = "https://cdn.example.com/huge-image.jpg"
        let html = "<p><a href=\"\(href)\"><img src=\"\(src)\" alt=\"\"></a></p>"
        let markdown = try convert(html)
        // The image src must never appear as visible link label text.
        XCTAssertFalse(
            markdown.contains("[\(src)](\(href))"),
            "Image src URL must not be surfaced as link label text: \(markdown)"
        )
        XCTAssertFalse(
            markdown.contains("[\(href)](\(href))"),
            "Target URL must not be surfaced as link label text: \(markdown)"
        )
    }

    func test_linkedImage_aPictureImg_producesNestedImageMarkdown() throws {
        let html = """
        <p>
          <a href="https://example.com/target">
            <picture>
              <source srcset="https://example.com/img@2x.webp" type="image/webp">
              <img src="https://example.com/img.jpg" alt="Caption">
            </picture>
          </a>
        </p>
        """
        let markdown = try convert(html)
        XCTAssertTrue(
            markdown.contains("[![Caption](https://example.com/img.jpg)](https://example.com/target)"),
            "Expected nested image markdown for a>picture>img, got: \(markdown)"
        )
    }

    // MARK: - Regression: plain text links must still work

    func test_plainTextLink_rendersCorrectly() throws {
        let html = "<p><a href=\"https://example.com\">Read more</a></p>"
        let markdown = try convert(html)
        XCTAssertTrue(
            markdown.contains("[Read more](https://example.com)"),
            "Plain text link must still render correctly, got: \(markdown)"
        )
    }

    func test_linkWithNoHref_rendersAsPlainText() throws {
        let html = "<p><a>No href here</a></p>"
        let markdown = try convert(html)
        XCTAssertTrue(
            markdown.contains("No href here"),
            "Anchor with no href must render as plain text, got: \(markdown)"
        )
        XCTAssertFalse(
            markdown.contains("[No href here]("),
            "Anchor with no href must not produce link Markdown syntax, got: \(markdown)"
        )
    }

    // MARK: - Round-trip: HTML -> Markdown -> rendered HTML

    func test_roundTrip_linkedImage_renderedHTMLContainsImgAndLink() throws {
        let html = """
        <p><a href="https://example.com/target"><img src="https://cdn.example.com/img.jpg" alt="Photo"></a></p>
        """
        let markdown = try convert(html)
        let rendered = try ReaderHTMLRenderer.render(markdown: markdown, themeId: "light")
        XCTAssertTrue(rendered.contains("<img"), "Rendered HTML must contain an img element")
        XCTAssertTrue(rendered.contains("cdn.example.com/img.jpg"), "Image src must survive round-trip")
        XCTAssertTrue(rendered.contains("example.com/target"), "Link href must survive round-trip")
    }

    func test_roundTrip_pictureInLink_renderedHTMLContainsFallbackSrc() throws {
        let html = """
        <a href="https://example.com/target">
          <picture>
            <source srcset="https://example.com/img@2x.webp" type="image/webp">
            <img src="https://example.com/fallback.jpg" alt="Alt">
          </picture>
        </a>
        """
        let markdown = try convert(html)
        let rendered = try ReaderHTMLRenderer.render(markdown: markdown, themeId: "light")
        XCTAssertTrue(
            rendered.contains("fallback.jpg"),
            "Fallback img src must survive picture-in-link round-trip, got: \(rendered)"
        )
    }

    // MARK: - Translation compatibility

    func test_translationCompatibility_imageOnlyParagraph_doesNotCreateSegment() throws {
        let html = """
        <p><a href="https://example.com/target"><img src="https://cdn.example.com/lead.jpg" alt=""></a></p>
        <p>First article paragraph.</p>
        <p>Second article paragraph.</p>
        """
        let markdown = try convert(html)
        let snapshot = try TranslationSegmentExtractor.extract(entryId: 1, markdown: markdown)
        // Image-only paragraph has no translatable text and must not produce a segment.
        XCTAssertEqual(snapshot.segments.count, 2, "Image-only paragraph must not produce a translation segment")
        XCTAssertTrue(snapshot.segments.allSatisfy { $0.segmentType == .p })
    }

    func test_translationCompatibility_mixedArticle_segmentShapeStable() throws {
        let html = """
        <p><a href="https://example.com"><img src="https://cdn.example.com/hero.jpg" alt="Hero"></a></p>
        <p>Intro paragraph.</p>
        <ul>
          <li>Item A</li>
          <li>Item B</li>
        </ul>
        <p>Closing paragraph.</p>
        """
        let markdown = try convert(html)
        let snapshot = try TranslationSegmentExtractor.extract(entryId: 2, markdown: markdown)
        // Expected: p("Intro paragraph."), ul, p("Closing paragraph.")
        XCTAssertEqual(snapshot.segments.count, 3)
        XCTAssertEqual(snapshot.segments.map(\.segmentType), [.p, .ul, .p])
    }
}

// MARK: - Helpers

private extension MarkdownConverterLinkedImageTests {
    func convert(_ html: String) throws -> String {
        try convertMarkdown(html)
    }
}
