//
//  MarkdownConverterCorpusTests.swift
//  MercuryTest
//
//  Phase 5: consolidated corpus tests covering the full coverage matrix from reader-mode.md.
//  Each fixture class includes exact Markdown assertions, DOM round-trip assertions, and
//  translation compatibility assertions where required.
//

import XCTest
import SwiftSoup
@testable import Mercury

final class MarkdownConverterCorpusTests: XCTestCase {

    // MARK: - Plain paragraphs

    func test_plainParagraphs_exactMarkdown() throws {
        let html = """
        <p>First paragraph of the article.</p>
        <p>Second paragraph continues the text.</p>
        <p>Third paragraph concludes the section.</p>
        """
        let markdown = try convertMarkdown(html)
        XCTAssertTrue(markdown.contains("First paragraph of the article."), "First paragraph must appear")
        XCTAssertTrue(markdown.contains("Second paragraph continues the text."), "Second paragraph must appear")
        XCTAssertTrue(markdown.contains("Third paragraph concludes the section."), "Third paragraph must appear")
        // Paragraphs must be separated by blank lines, not run together.
        let components = markdown.components(separatedBy: "\n\n")
        XCTAssertGreaterThanOrEqual(components.count, 3, "Three paragraphs must be separated by blank lines")
    }

    func test_plainParagraphs_domRoundTrip() throws {
        let html = """
        <p>Alpha.</p>
        <p>Beta.</p>
        """
        let rendered = try roundTrip(html)
        XCTAssertEqual(try countElements("p", in: rendered), 2, "Both paragraphs must appear in rendered output")
    }

    func test_plainParagraphs_translationCompatibility() throws {
        let html = """
        <p>Lead sentence of the article.</p>
        <p>Body sentence continues the story.</p>
        <p>Closing sentence wraps up the piece.</p>
        """
        let snapshot = try translationSnapshot(html: html, entryId: 300)
        XCTAssertEqual(snapshot.segments.count, 3, "Three paragraphs must produce three translation segments")
        XCTAssertTrue(snapshot.segments.allSatisfy { $0.segmentType == .p })
    }

    // MARK: - Headings with inline formatting

    func test_headingH1_exactMarkdown() throws {
        let html = "<h1>Title of the Article</h1>"
        let markdown = try convertMarkdown(html)
        XCTAssertTrue(markdown.hasPrefix("# Title of the Article"), "h1 must produce ATX heading level 1")
    }

    func test_headingH2_exactMarkdown() throws {
        let html = "<h2>Section heading</h2>"
        let markdown = try convertMarkdown(html)
        XCTAssertTrue(markdown.contains("## Section heading"), "h2 must produce ATX heading level 2")
    }

    func test_headingWithInlineEmphasis_preservesFormatting() throws {
        let html = "<h2>Section with <em>emphasis</em> in heading</h2>"
        let markdown = try convertMarkdown(html)
        XCTAssertTrue(
            markdown.contains("## Section with _emphasis_ in heading"),
            "Heading inline em must render as italics, got: \(markdown)"
        )
    }

    func test_headingWithInlineCode_preservesFormatting() throws {
        let html = "<h3>Guide to <code>renderMarkdown</code></h3>"
        let markdown = try convertMarkdown(html)
        XCTAssertTrue(
            markdown.contains("### Guide to `renderMarkdown`"),
            "Heading inline code must render as code span, got: \(markdown)"
        )
    }

    func test_headingWithInlineEmphasis_domRoundTrip() throws {
        let html = "<h2>Section with <em>key term</em> inline</h2>"
        let rendered = try roundTrip(html)
        XCTAssertTrue(try htmlContains("h2", in: rendered), "h2 must survive round-trip")
        XCTAssertTrue(try htmlContains("em", in: rendered), "Inline em must survive heading round-trip")
    }

    // MARK: - Inline emphasis and code

    func test_em_exactMarkdown() throws {
        let html = "<p>Text with <em>italic emphasis</em> inline.</p>"
        let markdown = try convertMarkdown(html)
        XCTAssertTrue(
            markdown.contains("_italic emphasis_"),
            "em must produce underscore-delimited italic, got: \(markdown)"
        )
    }

    func test_i_exactMarkdown() throws {
        let html = "<p>Text with <i>italic via i tag</i>.</p>"
        let markdown = try convertMarkdown(html)
        XCTAssertTrue(
            markdown.contains("_italic via i tag_"),
            "i must produce underscore-delimited italic, got: \(markdown)"
        )
    }

    func test_strong_exactMarkdown() throws {
        let html = "<p>Text with <strong>bold emphasis</strong> inline.</p>"
        let markdown = try convertMarkdown(html)
        XCTAssertTrue(
            markdown.contains("**bold emphasis**"),
            "strong must produce double-asterisk bold, got: \(markdown)"
        )
    }

    func test_b_exactMarkdown() throws {
        let html = "<p>Text with <b>bold via b tag</b>.</p>"
        let markdown = try convertMarkdown(html)
        XCTAssertTrue(
            markdown.contains("**bold via b tag**"),
            "b must produce double-asterisk bold, got: \(markdown)"
        )
    }

    func test_del_exactMarkdown() throws {
        let html = "<p>This is <del>deleted text</del> inline.</p>"
        let markdown = try convertMarkdown(html)
        XCTAssertTrue(
            markdown.contains("~~deleted text~~"),
            "del must produce tilde strikethrough, got: \(markdown)"
        )
    }

    func test_s_exactMarkdown() throws {
        let html = "<p>This is <s>struck text</s>.</p>"
        let markdown = try convertMarkdown(html)
        XCTAssertTrue(
            markdown.contains("~~struck text~~"),
            "s must produce tilde strikethrough, got: \(markdown)"
        )
    }

    func test_inlineCode_exactMarkdown() throws {
        let html = "<p>Call the <code>render()</code> method.</p>"
        let markdown = try convertMarkdown(html)
        XCTAssertTrue(
            markdown.contains("`render()`"),
            "code must produce backtick code span, got: \(markdown)"
        )
    }

    func test_nestedEmStrong_exactMarkdown() throws {
        let html = "<p>Text <strong>bold with <em>nested italic</em></strong> here.</p>"
        let markdown = try convertMarkdown(html)
        XCTAssertTrue(markdown.contains("**bold with"), "strong wrapper must appear")
        XCTAssertTrue(markdown.contains("_nested italic_"), "nested em must produce italics")
    }

    func test_em_domRoundTrip() throws {
        let html = "<p>Read <em>carefully</em> before proceeding.</p>"
        let rendered = try roundTrip(html)
        XCTAssertTrue(try htmlContains("em", in: rendered), "em must survive round-trip render")
    }

    func test_inlineEmphasis_midSentenceWithFollowingText_remainsSingleParagraph() throws {
        let html = """
        <p>Managers pay <em>a lot</em> of attention to engineers with a reputation like that.</p>
        """
        let rendered = try roundTrip(html)
        XCTAssertEqual(try countElements("article.reader > p", in: rendered), 1, "Inline emphasis must remain in a single paragraph")
        XCTAssertTrue(
            rendered.contains("<p>Managers pay <em>a lot</em> of attention to engineers with a reputation like that.</p>"),
            "Rendered HTML must preserve inline emphasis with surrounding text, got: \(rendered)"
        )
    }

    func test_inlineEmphasis_beforeSentencePunctuation_remainsSingleParagraph() throws {
        let html = """
        <p>Most managers do not care about the engineering, they care about the <em>feature</em>. Software engineers who can ship features smoothly will be rewarded.</p>
        """
        let rendered = try roundTrip(html)
        XCTAssertEqual(try countElements("article.reader > p", in: rendered), 1, "Inline emphasis before punctuation must remain in a single paragraph")
        XCTAssertTrue(
            rendered.contains("<p>Most managers do not care about the engineering, they care about the <em>feature</em>. Software engineers who can ship features smoothly will be rewarded.</p>"),
            "Rendered HTML must keep punctuation outside inline emphasis, got: \(rendered)"
        )
    }

    func test_inlineEmphasis_beforeComma_remainsSingleParagraph() throws {
        let html = """
        <p>I think Mario is exactly right about this. Agents let us move <em>so much faster</em>, but this speed also means that changes which we would normally have considered over the course of weeks are landing in a matter of hours.</p>
        """
        let rendered = try roundTrip(html)
        XCTAssertEqual(try countElements("article.reader > p", in: rendered), 1, "Inline emphasis before a comma must remain in a single paragraph")
        XCTAssertTrue(
            rendered.contains("<p>I think Mario is exactly right about this. Agents let us move <em>so much faster</em>, but this speed also means that changes which we would normally have considered over the course of weeks are landing in a matter of hours.</p>"),
            "Rendered HTML must keep the comma inline after the emphasized text, got: \(rendered)"
        )
    }

    func test_strong_domRoundTrip() throws {
        let html = "<p>This is <strong>critical</strong> information.</p>"
        let rendered = try roundTrip(html)
        XCTAssertTrue(try htmlContains("strong", in: rendered), "strong must survive round-trip render")
    }

    func test_inlineEmphasis_translationCompatibility() throws {
        let html = """
        <p>This paragraph has <strong>bold</strong> and <em>italic</em> text.</p>
        <p>This paragraph is plain.</p>
        """
        let snapshot = try translationSnapshot(html: html, entryId: 310)
        XCTAssertEqual(snapshot.segments.count, 2, "Inline formatting must not split paragraphs into extra segments")
        XCTAssertTrue(snapshot.segments.allSatisfy { $0.segmentType == .p })
    }

    // MARK: - Horizontal rule

    func test_hr_exactMarkdown() throws {
        let html = "<p>Before rule.</p><hr><p>After rule.</p>"
        let markdown = try convertMarkdown(html)
        XCTAssertTrue(markdown.contains("---"), "hr must produce a horizontal rule in Markdown")
    }

    // MARK: - Nested lists

    func test_nestedUnorderedList_exactMarkdown() throws {
        let html = """
        <ul>
          <li>Top item A
            <ul>
              <li>Sub-item A1</li>
              <li>Sub-item A2</li>
            </ul>
          </li>
          <li>Top item B</li>
        </ul>
        """
        let markdown = try convertMarkdown(html)
        XCTAssertTrue(markdown.contains("- Top item A"), "Top-level item must appear at root indentation")
        XCTAssertTrue(markdown.contains("  - Sub-item A1"), "Nested item must be indented two spaces")
        XCTAssertTrue(markdown.contains("  - Sub-item A2"), "Second nested item must be indented two spaces")
        XCTAssertTrue(markdown.contains("- Top item B"), "Second top-level item must appear")
    }

    func test_nestedOrderedList_exactMarkdown() throws {
        let html = """
        <ol>
          <li>Step one
            <ol>
              <li>Sub-step 1a</li>
            </ol>
          </li>
          <li>Step two</li>
        </ol>
        """
        let markdown = try convertMarkdown(html)
        XCTAssertTrue(markdown.contains("1. Step one"), "First ordered item must appear")
        XCTAssertTrue(markdown.contains("  1. Sub-step 1a"), "Nested ordered item must be indented")
        XCTAssertTrue(markdown.contains("2. Step two"), "Second ordered item must appear")
    }

    func test_nestedList_domRoundTrip() throws {
        let html = """
        <ul>
          <li>Outer
            <ul>
              <li>Inner</li>
            </ul>
          </li>
        </ul>
        """
        let rendered = try roundTrip(html)
        XCTAssertTrue(try htmlContains("ul", in: rendered), "ul must survive round-trip")
        XCTAssertGreaterThanOrEqual(
            try countElements("li", in: rendered), 2,
            "Both list items must survive round-trip"
        )
    }

    func test_nestedList_translationCompatibility() throws {
        let html = """
        <p>Intro paragraph.</p>
        <ul>
          <li>Item A
            <ul>
              <li>Sub-item</li>
            </ul>
          </li>
          <li>Item B</li>
        </ul>
        <p>Closing paragraph.</p>
        """
        let snapshot = try translationSnapshot(html: html, entryId: 320)
        // The entire ul (including nested) counts as one segment.
        XCTAssertEqual(snapshot.segments.count, 3, "p + ul + p must produce three segments")
        XCTAssertEqual(snapshot.segments.map(\.segmentType), [.p, .ul, .p])
    }

    // MARK: - Mixed media paragraph

    func test_mixedMedia_imageFollowedByParagraph_exactMarkdown() throws {
        let html = """
        <p><img src="https://example.com/banner.jpg" alt="Banner"></p>
        <p>Article introduction follows the banner image.</p>
        """
        let markdown = try convertMarkdown(html)
        XCTAssertTrue(markdown.contains("![Banner](https://example.com/banner.jpg)"), "Banner image must be present")
        XCTAssertTrue(markdown.contains("Article introduction follows the banner image."), "Body text must be present")
    }

    func test_mixedMedia_linkedImageFollowedByParagraph_exactMarkdown() throws {
        let html = """
        <p><a href="https://example.com/page"><img src="https://cdn.example.com/hero.jpg" alt="Hero image"></a></p>
        <p>The hero image above links to the full article page.</p>
        """
        let markdown = try convertMarkdown(html)
        XCTAssertTrue(
            markdown.contains("[![Hero image](https://cdn.example.com/hero.jpg)](https://example.com/page)"),
            "Linked hero image must produce nested Markdown image syntax"
        )
        XCTAssertTrue(
            markdown.contains("The hero image above links to the full article page."),
            "Body text must follow the image"
        )
    }

    func test_mixedMedia_figureWithCaptionAndParagraph_domRoundTrip() throws {
        let html = """
        <figure>
          <img src="https://example.com/photo.jpg" alt="Photo">
          <figcaption>A scenic view.</figcaption>
        </figure>
        <p>Description paragraph follows the figure.</p>
        """
        let rendered = try roundTrip(html)
        XCTAssertTrue(try htmlContains("img", in: rendered), "img must survive round-trip in figure fixture")
        XCTAssertTrue(try htmlContains("em", in: rendered), "figcaption italic must survive round-trip")
        XCTAssertTrue(try htmlContains("p", in: rendered), "paragraph must survive round-trip")
    }

    func test_mixedMedia_translationCompatibility() throws {
        let html = """
        <p><img src="https://example.com/lead.jpg" alt="Lead"></p>
        <p>First body paragraph.</p>
        <p>Second body paragraph.</p>
        """
        let snapshot = try translationSnapshot(html: html, entryId: 330)
        // Image-only paragraph must not create a translation segment.
        XCTAssertEqual(snapshot.segments.count, 2, "Image-only p must not create a translation segment")
        XCTAssertTrue(snapshot.segments.allSatisfy { $0.segmentType == .p })
    }

    // MARK: - Round-trip DOM assertions for figure and picture (consolidating Phase 4)

    func test_figureWithCaption_domRoundTrip() throws {
        let html = """
        <figure>
          <img src="https://example.com/landscape.jpg" alt="Landscape">
          <figcaption>Mountain landscape at dusk.</figcaption>
        </figure>
        """
        let rendered = try roundTrip(html)
        XCTAssertTrue(try htmlContains("img", in: rendered), "img must survive figure round-trip")
        XCTAssertEqual(
            try firstAttribute("src", ofSelector: "img", in: rendered),
            "https://example.com/landscape.jpg",
            "Image src must be preserved through figure round-trip"
        )
    }

    func test_figureWithCaption_rendersAsImageParagraphThenItalicCaptionParagraph() throws {
        let html = """
        <figure>
          <img src="https://example.com/photo.jpg" alt="Landscape">
          <figcaption>A scenic view of the valley.</figcaption>
        </figure>
        """
        let rendered = try roundTrip(html)
        XCTAssertEqual(try countElements("article.reader > p", in: rendered), 2, "Figure with caption must render as image paragraph followed by caption paragraph")
        XCTAssertEqual(try countElements("article.reader > p:first-of-type > img", in: rendered), 1, "First paragraph must contain the image")
        XCTAssertEqual(try countElements("article.reader > p:nth-of-type(2) > em", in: rendered), 1, "Second paragraph must contain italic caption text")
        XCTAssertEqual(try firstElementText("article.reader > p:nth-of-type(2) > em", in: rendered), "A scenic view of the valley.")
    }

    func test_responsivePicture_domRoundTrip() throws {
        let html = """
        <picture>
          <source srcset="https://example.com/photo@2x.webp" type="image/webp">
          <img src="https://example.com/photo.jpg" alt="Photo">
        </picture>
        """
        let rendered = try roundTrip(html)
        XCTAssertTrue(try htmlContains("img", in: rendered), "img must survive picture round-trip")
        XCTAssertEqual(
            try firstAttribute("src", ofSelector: "img", in: rendered),
            "https://example.com/photo.jpg",
            "Primary img src must be used after picture collapse"
        )
        XCTAssertFalse(
            try htmlContains("picture", in: rendered),
            "picture tag must not appear in rendered output"
        )
    }

    // MARK: - Round-trip DOM assertions for simple table (consolidating Phase 4)

    func test_simpleTable_domRoundTrip() throws {
        let html = """
        <table>
          <thead><tr><th>Name</th><th>Score</th></tr></thead>
          <tbody>
            <tr><td>Alice</td><td>95</td></tr>
          </tbody>
        </table>
        """
        // Note: Down (cmark 0.29.0) renders GFM pipe-table syntax as paragraph text.
        // The round-trip test verifies that Alice's score still appears in the rendered output.
        let rendered = try roundTrip(html)
        XCTAssertTrue(rendered.contains("Alice"), "Table content must survive round-trip")
        XCTAssertTrue(rendered.contains("95"), "Table value must survive round-trip")
    }

    // MARK: - Complex table fallback (consolidating Phase 4)

    func test_complexTable_colspanContent_appearsInRoundTrip() throws {
        let html = """
        <table>
          <thead><tr><th colspan="2">Spanned header</th></tr></thead>
          <tbody><tr><td>Cell A</td><td>Cell B</td></tr></tbody>
        </table>
        """
        // Complex table falls back to child-text rendering.
        let rendered = try roundTrip(html)
        XCTAssertTrue(rendered.contains("Spanned header"), "Spanned header text must survive round-trip")
        XCTAssertTrue(rendered.contains("Cell A"), "Cell content must survive round-trip fallback")
    }

    // MARK: - Blockquote

    func test_blockquote_exactMarkdown() throws {
        let html = "<blockquote><p>A wise saying attributed to someone.</p></blockquote>"
        let markdown = try convertMarkdown(html)
        XCTAssertTrue(markdown.contains("> A wise saying"), "blockquote must produce > prefix")
    }

    func test_blockquote_domRoundTrip() throws {
        let html = "<blockquote><p>Quoted text content.</p></blockquote>"
        let rendered = try roundTrip(html)
        XCTAssertTrue(try htmlContains("blockquote", in: rendered), "blockquote must survive round-trip")
    }

    // MARK: - Code block

    func test_codeBlock_exactMarkdown() throws {
        let html = "<pre><code>let x = 42\nprint(x)</code></pre>"
        let markdown = try convertMarkdown(html)
        XCTAssertTrue(markdown.contains("```"), "pre/code must produce fenced code block")
        XCTAssertTrue(markdown.contains("let x = 42"), "Code content must be preserved")
    }

    func test_codeBlock_domRoundTrip() throws {
        let html = "<pre><code>func greet() -> String { return \"Hello\" }</code></pre>"
        let rendered = try roundTrip(html)
        XCTAssertTrue(try htmlContains("code", in: rendered), "code block must survive round-trip")
    }

    func test_markdownPreType_exactMarkdown() throws {
        let html = "<pre data-readability-pre-type=\"markdown\">## Section\n\n- item one\n- item two\n</pre>"
        let markdown = try convertMarkdown(html)
        XCTAssertTrue(markdown.contains("## Section"), "Markdown pre must preserve heading syntax, got: \(markdown)")
        XCTAssertTrue(markdown.contains("- item one"), "Markdown pre must preserve list syntax, got: \(markdown)")
        XCTAssertFalse(markdown.contains("```"), "Markdown pre must not be wrapped as fenced code, got: \(markdown)")
    }

    func test_markdownPreType_domRoundTripRendersMarkdownStructure() throws {
        let html = "<pre data-readability-pre-type=\"markdown\">## Section\n\n- item one\n- item two\n</pre>"
        let rendered = try roundTrip(html)
        XCTAssertFalse(try htmlContains("pre", in: rendered), "Markdown pre must not render back to a pre block")
        XCTAssertTrue(try htmlContains("h2", in: rendered), "Markdown pre must render heading structure")
        XCTAssertTrue(try htmlContains("ul", in: rendered), "Markdown pre must render list structure")
        XCTAssertEqual(try countElements("li", in: rendered), 2, "Markdown pre list items must survive round-trip")
    }

    func test_markdownPreType_translationCompatibilityUsesRenderedMarkdownBlocks() throws {
        let html = "<pre data-readability-pre-type=\"markdown\">Lead paragraph.\n\n- item one\n- item two\n</pre>"
        let snapshot = try translationSnapshot(html: html, entryId: 320)
        XCTAssertEqual(snapshot.segments.count, 2, "Markdown pre must segment as paragraph plus list")
        XCTAssertEqual(snapshot.segments[0].segmentType, .p)
        XCTAssertEqual(snapshot.segments[1].segmentType, .ul)
    }

    func test_codePreType_exactMarkdownProducesFencedCodeBlock() throws {
        let html = "<pre data-readability-pre-type=\"code\">let value = 42\nprint(value)</pre>"
        let markdown = try convertMarkdown(html)
        XCTAssertTrue(markdown.contains("```"), "Code pre must still produce fenced code block, got: \(markdown)")
        XCTAssertTrue(markdown.contains("let value = 42"), "Code pre must preserve content, got: \(markdown)")
    }
}
