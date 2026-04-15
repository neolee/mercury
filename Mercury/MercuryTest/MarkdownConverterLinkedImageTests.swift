//
//  MarkdownConverterLinkedImageTests.swift
//  MercuryTest
//

import Testing
@testable import Mercury

/// Phase 2 tests: linked-image regression and round-trip fidelity.
@Suite
@MainActor
struct MarkdownConverterLinkedImageTests {

    // MARK: - Unit tests: exact Markdown output

    @Test

    func test_linkedImage_aImg_producesNestedImageMarkdown() throws {
        let html = """
        <p><a href="https://example.com/target"><img src="https://cdn.example.com/img.jpg" alt="Alt text"></a></p>
        """
        let markdown = try convert(html)
        #expect(
            markdown.contains("[![Alt text](https://cdn.example.com/img.jpg)](https://example.com/target)"),
            "Expected nested image markdown, got: \(markdown)"
        )
    }

    @Test

    func test_linkedImage_aImg_emptyAlt_producesNestedImageMarkdown() throws {
        let html = """
        <p><a href="https://t.co/link"><img src="https://cdn.example.com/photo.jpg" alt=""></a></p>
        """
        let markdown = try convert(html)
        #expect(
            markdown.contains("[![](https://cdn.example.com/photo.jpg)](https://t.co/link)"),
            "Expected empty-alt linked image markdown, got: \(markdown)"
        )
    }

    @Test

    func test_linkedImage_noUrlFallback_srcNotSurfacedAsLinkText() throws {
        let href = "https://example.com/target"
        let src = "https://cdn.example.com/huge-image.jpg"
        let html = "<p><a href=\"\(href)\"><img src=\"\(src)\" alt=\"\"></a></p>"
        let markdown = try convert(html)
        // The image src must never appear as visible link label text.
        #expect(
            !markdown.contains("[\(src)](\(href))"),
            "Image src URL must not be surfaced as link label text: \(markdown)"
        )
        #expect(
            !markdown.contains("[\(href)](\(href))"),
            "Target URL must not be surfaced as link label text: \(markdown)"
        )
    }

    @Test

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
        #expect(
            markdown.contains("[![Caption](https://example.com/img.jpg)](https://example.com/target)"),
            "Expected nested image markdown for a>picture>img, got: \(markdown)"
        )
    }

    // MARK: - Regression: plain text links must still work

    @Test

    func test_plainTextLink_rendersCorrectly() throws {
        let html = "<p><a href=\"https://example.com\">Read more</a></p>"
        let markdown = try convert(html)
        #expect(
            markdown.contains("[Read more](https://example.com)"),
            "Plain text link must still render correctly, got: \(markdown)"
        )
    }

    @Test

    func test_linkWithNoHref_rendersAsPlainText() throws {
        let html = "<p><a>No href here</a></p>"
        let markdown = try convert(html)
        #expect(
            markdown.contains("No href here"),
            "Anchor with no href must render as plain text, got: \(markdown)"
        )
        #expect(
            !markdown.contains("[No href here]("),
            "Anchor with no href must not produce link Markdown syntax, got: \(markdown)"
        )
    }

    // MARK: - Round-trip: HTML -> Markdown -> rendered HTML

    @Test

    func test_roundTrip_linkedImage_renderedHTMLContainsImgAndLink() throws {
        let html = """
        <p><a href="https://example.com/target"><img src="https://cdn.example.com/img.jpg" alt="Photo"></a></p>
        """
        let markdown = try convert(html)
        let rendered = try ReaderHTMLRenderer.render(markdown: markdown, themeId: "light")
        #expect(rendered.contains("<img"), "Rendered HTML must contain an img element")
        #expect(rendered.contains("cdn.example.com/img.jpg"), "Image src must survive round-trip")
        #expect(rendered.contains("example.com/target"), "Link href must survive round-trip")
    }

    @Test

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
        #expect(
            rendered.contains("fallback.jpg"),
            "Fallback img src must survive picture-in-link round-trip, got: \(rendered)"
        )
    }

    @Test

    func test_dataImage_multilineBase64Src_normalizesToSingleLineMarkdown() throws {
        let html = """
        <p><img src="data:image/jpeg;base64,
        AAAA
        BBBB" alt="Inline data"></p>
        """
        let markdown = try convert(html)

        #expect(
            markdown.contains("![Inline data](data:image/jpeg;base64,AAAABBBB)"),
            "Expected multiline base64 payload to be normalized into a single Markdown image destination, got: \(markdown)"
        )
    }

    @Test

    func test_roundTrip_multilineBase64DataImage_rendersAsImg() throws {
        let html = """
        <p><img src="data:image/jpeg;base64,
        AAAA
        BBBB" alt="Inline data"></p>
        """
        let rendered = try roundTrip(html)

        #expect(rendered.contains("<img"), "Rendered HTML must contain an img element")
        #expect(
            rendered.contains("src=\"data:image/jpeg;base64,AAAABBBB\""),
            "Expected normalized data URI to survive round-trip, got: \(rendered)"
        )
    }

    // MARK: - Translation compatibility

    @Test

    func test_translationCompatibility_imageOnlyParagraph_doesNotCreateSegment() throws {
        let html = """
        <p><a href="https://example.com/target"><img src="https://cdn.example.com/lead.jpg" alt=""></a></p>
        <p>First article paragraph.</p>
        <p>Second article paragraph.</p>
        """
        let markdown = try convert(html)
        let snapshot = try TranslationSegmentExtractor.extract(entryId: 1, markdown: markdown)
        // Image-only paragraph has no translatable text and must not produce a segment.
        #expect(snapshot.segments.count == 2, "Image-only paragraph must not produce a translation segment")
        #expect(snapshot.segments.allSatisfy { $0.segmentType == .p })
    }

    @Test

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
        #expect(snapshot.segments.count == 3)
        #expect(snapshot.segments.map(\.segmentType) == [.p, .ul, .p])
    }
}

// MARK: - Helpers

private extension MarkdownConverterLinkedImageTests {
    func convert(_ html: String) throws -> String {
        try convertMarkdown(html)
    }
}
