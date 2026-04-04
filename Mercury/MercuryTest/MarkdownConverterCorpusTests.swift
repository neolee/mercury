//
//  MarkdownConverterCorpusTests.swift
//  MercuryTest
//
//  Phase 5: consolidated corpus tests covering the full coverage matrix from reader-mode.md.
//  Each fixture class includes exact Markdown assertions, DOM round-trip assertions, and
//  translation compatibility assertions where required.
//

import Testing
import Foundation
import SwiftSoup
@testable import Mercury

@Suite
struct MarkdownConverterCorpusTests {

    // MARK: - Plain paragraphs

    @Test

    func test_plainParagraphs_exactMarkdown() throws {
        let html = """
        <p>First paragraph of the article.</p>
        <p>Second paragraph continues the text.</p>
        <p>Third paragraph concludes the section.</p>
        """
        let markdown = try convertMarkdown(html)
        #expect(markdown.contains("First paragraph of the article."), "First paragraph must appear")
        #expect(markdown.contains("Second paragraph continues the text."), "Second paragraph must appear")
        #expect(markdown.contains("Third paragraph concludes the section."), "Third paragraph must appear")
        // Paragraphs must be separated by blank lines, not run together.
        let components = markdown.components(separatedBy: "\n\n")
        #expect(components.count >= 3, "Three paragraphs must be separated by blank lines")
    }

    @Test

    func test_plainParagraphs_domRoundTrip() throws {
        let html = """
        <p>Alpha.</p>
        <p>Beta.</p>
        """
        let rendered = try roundTrip(html)
        #expect(try countElements("p", in: rendered) == 2, "Both paragraphs must appear in rendered output")
    }

    @Test

    func test_plainParagraphs_translationCompatibility() throws {
        let html = """
        <p>Lead sentence of the article.</p>
        <p>Body sentence continues the story.</p>
        <p>Closing sentence wraps up the piece.</p>
        """
        let snapshot = try translationSnapshot(html: html, entryId: 300)
        #expect(snapshot.segments.count == 3, "Three paragraphs must produce three translation segments")
        #expect(snapshot.segments.allSatisfy { $0.segmentType == .p })
    }

    // MARK: - Headings with inline formatting

    @Test

    func test_headingH1_exactMarkdown() throws {
        let html = "<h1>Title of the Article</h1>"
        let markdown = try convertMarkdown(html)
        #expect(markdown.hasPrefix("# Title of the Article"), "h1 must produce ATX heading level 1")
    }

    @Test

    func test_headingH2_exactMarkdown() throws {
        let html = "<h2>Section heading</h2>"
        let markdown = try convertMarkdown(html)
        #expect(markdown.contains("## Section heading"), "h2 must produce ATX heading level 2")
    }

    @Test

    func test_headingWithInlineEmphasis_preservesFormatting() throws {
        let html = "<h2>Section with <em>emphasis</em> in heading</h2>"
        let markdown = try convertMarkdown(html)
        #expect(
            markdown.contains("## Section with _emphasis_ in heading"),
            "Heading inline em must render as italics, got: \(markdown)"
        )
    }

    @Test

    func test_headingWithInlineCode_preservesFormatting() throws {
        let html = "<h3>Guide to <code>renderMarkdown</code></h3>"
        let markdown = try convertMarkdown(html)
        #expect(
            markdown.contains("### Guide to `renderMarkdown`"),
            "Heading inline code must render as code span, got: \(markdown)"
        )
    }

    @Test

    func test_headingWithInlineEmphasis_domRoundTrip() throws {
        let html = "<h2>Section with <em>key term</em> inline</h2>"
        let rendered = try roundTrip(html)
        #expect(try htmlContains("h2", in: rendered), "h2 must survive round-trip")
        #expect(try htmlContains("em", in: rendered), "Inline em must survive heading round-trip")
    }

    // MARK: - Inline emphasis and code

    @Test

    func test_em_exactMarkdown() throws {
        let html = "<p>Text with <em>italic emphasis</em> inline.</p>"
        let markdown = try convertMarkdown(html)
        #expect(
            markdown.contains("_italic emphasis_"),
            "em must produce underscore-delimited italic, got: \(markdown)"
        )
    }

    @Test

    func test_i_exactMarkdown() throws {
        let html = "<p>Text with <i>italic via i tag</i>.</p>"
        let markdown = try convertMarkdown(html)
        #expect(
            markdown.contains("_italic via i tag_"),
            "i must produce underscore-delimited italic, got: \(markdown)"
        )
    }

    @Test

    func test_strong_exactMarkdown() throws {
        let html = "<p>Text with <strong>bold emphasis</strong> inline.</p>"
        let markdown = try convertMarkdown(html)
        #expect(
            markdown.contains("**bold emphasis**"),
            "strong must produce double-asterisk bold, got: \(markdown)"
        )
    }

    @Test

    func test_b_exactMarkdown() throws {
        let html = "<p>Text with <b>bold via b tag</b>.</p>"
        let markdown = try convertMarkdown(html)
        #expect(
            markdown.contains("**bold via b tag**"),
            "b must produce double-asterisk bold, got: \(markdown)"
        )
    }

    @Test

    func test_del_exactMarkdown() throws {
        let html = "<p>This is <del>deleted text</del> inline.</p>"
        let markdown = try convertMarkdown(html)
        #expect(
            markdown.contains("~~deleted text~~"),
            "del must produce tilde strikethrough, got: \(markdown)"
        )
    }

    @Test

    func test_s_exactMarkdown() throws {
        let html = "<p>This is <s>struck text</s>.</p>"
        let markdown = try convertMarkdown(html)
        #expect(
            markdown.contains("~~struck text~~"),
            "s must produce tilde strikethrough, got: \(markdown)"
        )
    }

    @Test

    func test_inlineCode_exactMarkdown() throws {
        let html = "<p>Call the <code>render()</code> method.</p>"
        let markdown = try convertMarkdown(html)
        #expect(
            markdown.contains("`render()`"),
            "code must produce backtick code span, got: \(markdown)"
        )
    }

    @Test

    func test_inlineCode_withBackticks_usesSafeFence() throws {
        let html = "<p>Call <code>foo`bar</code> before continuing.</p>"
        let markdown = try convertMarkdown(html)
        #expect(
            markdown.contains("``foo`bar``"),
            "Inline code containing backticks must use a longer fence, got: \(markdown)"
        )
    }

    @Test

    func test_inlineCode_withBackticks_survivesRoundTrip() throws {
        let html = "<p>Call <code>foo`bar</code> before continuing.</p>"
        let rendered = try roundTrip(html)
        #expect(try countElements("article.reader > p", in: rendered) == 1, "Inline code must remain in a single paragraph")
        #expect(
            rendered.contains("<p>Call <code>foo`bar</code> before continuing.</p>"),
            "Round-trip HTML must preserve inline code containing backticks, got: \(rendered)"
        )
    }

    @Test

    func test_inlineCode_preservesRepeatedSpaces_exactMarkdown() throws {
        let html = "<p>Use <code>a  b</code> now.</p>"
        let markdown = try convertMarkdown(html)
        #expect(
            markdown.contains("`a  b`"),
            "Inline code must preserve repeated ASCII spaces, got: \(markdown)"
        )
    }

    @Test

    func test_inlineCode_preservesRepeatedSpaces_survivesRoundTrip() throws {
        let html = "<p>Use <code>a  b</code> now.</p>"
        let rendered = try roundTrip(html)
        #expect(try countElements("article.reader > p", in: rendered) == 1, "Inline code with repeated spaces must remain in a single paragraph")
        #expect(
            rendered.contains("<p>Use <code>a  b</code> now.</p>"),
            "Round-trip HTML must preserve repeated spaces inside inline code, got: \(rendered)"
        )
    }

    @Test

    func test_inlineCode_preservesNonBreakingSpace_exactMarkdown() throws {
        let html = "<p>Use <code>a&nbsp;b</code> now.</p>"
        let markdown = try convertMarkdown(html)
        #expect(
            markdown.contains("`a\u{00A0}b`"),
            "Inline code must preserve non-breaking spaces, got: \(markdown)"
        )
    }

    @Test

    func test_inlineCode_preservesNonBreakingSpace_survivesRoundTrip() throws {
        let html = "<p>Use <code>a&nbsp;b</code> now.</p>"
        let rendered = try roundTrip(html)
        #expect(try countElements("article.reader > p", in: rendered) == 1, "Inline code with non-breaking space must remain in a single paragraph")
        #expect(
            rendered.contains("<code>a\u{00A0}b</code>") || rendered.contains("<code>a&nbsp;b</code>"),
            "Round-trip HTML must preserve non-breaking spaces inside inline code, got: \(rendered)"
        )
    }

    @Test

    func test_nestedEmStrong_exactMarkdown() throws {
        let html = "<p>Text <strong>bold with <em>nested italic</em></strong> here.</p>"
        let markdown = try convertMarkdown(html)
        #expect(markdown.contains("**bold with"), "strong wrapper must appear")
        #expect(markdown.contains("_nested italic_"), "nested em must produce italics")
    }

    @Test

    func test_em_domRoundTrip() throws {
        let html = "<p>Read <em>carefully</em> before proceeding.</p>"
        let rendered = try roundTrip(html)
        #expect(try htmlContains("em", in: rendered), "em must survive round-trip render")
    }

    @Test

    func test_inlineEmphasis_midSentenceWithFollowingText_remainsSingleParagraph() throws {
        let html = """
        <p>Managers pay <em>a lot</em> of attention to engineers with a reputation like that.</p>
        """
        let rendered = try roundTrip(html)
        #expect(try countElements("article.reader > p", in: rendered) == 1, "Inline emphasis must remain in a single paragraph")
        #expect(
            rendered.contains("<p>Managers pay <em>a lot</em> of attention to engineers with a reputation like that.</p>"),
            "Rendered HTML must preserve inline emphasis with surrounding text, got: \(rendered)"
        )
    }

    @Test

    func test_inlineEmphasis_beforeSentencePunctuation_remainsSingleParagraph() throws {
        let html = """
        <p>Most managers do not care about the engineering, they care about the <em>feature</em>. Software engineers who can ship features smoothly will be rewarded.</p>
        """
        let rendered = try roundTrip(html)
        #expect(try countElements("article.reader > p", in: rendered) == 1, "Inline emphasis before punctuation must remain in a single paragraph")
        #expect(
            rendered.contains("<p>Most managers do not care about the engineering, they care about the <em>feature</em>. Software engineers who can ship features smoothly will be rewarded.</p>"),
            "Rendered HTML must keep punctuation outside inline emphasis, got: \(rendered)"
        )
    }

    @Test

    func test_inlineEmphasis_beforeComma_remainsSingleParagraph() throws {
        let html = """
        <p>I think Mario is exactly right about this. Agents let us move <em>so much faster</em>, but this speed also means that changes which we would normally have considered over the course of weeks are landing in a matter of hours.</p>
        """
        let rendered = try roundTrip(html)
        #expect(try countElements("article.reader > p", in: rendered) == 1, "Inline emphasis before a comma must remain in a single paragraph")
        #expect(
            rendered.contains("<p>I think Mario is exactly right about this. Agents let us move <em>so much faster</em>, but this speed also means that changes which we would normally have considered over the course of weeks are landing in a matter of hours.</p>"),
            "Rendered HTML must keep the comma inline after the emphasized text, got: \(rendered)"
        )
    }

    @Test

    func test_strong_domRoundTrip() throws {
        let html = "<p>This is <strong>critical</strong> information.</p>"
        let rendered = try roundTrip(html)
        #expect(try htmlContains("strong", in: rendered), "strong must survive round-trip render")
    }

    @Test

    func test_inlineEmphasis_translationCompatibility() throws {
        let html = """
        <p>This paragraph has <strong>bold</strong> and <em>italic</em> text.</p>
        <p>This paragraph is plain.</p>
        """
        let snapshot = try translationSnapshot(html: html, entryId: 310)
        #expect(snapshot.segments.count == 2, "Inline formatting must not split paragraphs into extra segments")
        #expect(snapshot.segments.allSatisfy { $0.segmentType == .p })
    }

    @Test

    func test_linkWithLeadingWhitespace_preservesMarkdownSpacing() throws {
        let html = """
        <p><span>First, Microsoft’s Mustafa Suleyman</span><a href="https://x.com/haydenfield/status/2039705728416362864?s=61"> just tried to redefine superintelligence</a><span> down from AI that is smarter than the smartest humans.</span></p>
        """
        let markdown = try convertMarkdown(html)
        #expect(
            markdown.contains("First, Microsoft’s Mustafa Suleyman [just tried to redefine superintelligence](https://x.com/haydenfield/status/2039705728416362864?s=61) down from AI that is smarter than the smartest humans."),
            "Link text with a leading space must keep that space outside the Markdown link, got: \(markdown)"
        )
    }

    @Test

    func test_linkWithLeadingWhitespace_survivesRoundTrip() throws {
        let html = """
        <p><span>First, Microsoft’s Mustafa Suleyman</span><a href="https://x.com/haydenfield/status/2039705728416362864?s=61"> just tried to redefine superintelligence</a><span> down from AI that is smarter than the smartest humans.</span></p>
        """
        let rendered = try roundTrip(html)
        #expect(
            rendered.contains("<p>First, Microsoft’s Mustafa Suleyman <a href=\"https://x.com/haydenfield/status/2039705728416362864?s=61\">just tried to redefine superintelligence</a> down from AI that is smarter than the smartest humans.</p>"),
            "Round-trip HTML must preserve the space before the linked phrase, got: \(rendered)"
        )
    }

    @Test

    func test_adjacentLinkedEmphasisSegments_preserveSpacesInMarkdown() throws {
        let html = """
        <p><span>A bunch of employees actually thought </span><a href="https://www.theinformation.com/articles/openais-tbpn-deal-joke?utm_source=ti_app&amp;rc=dcf9pt">it </a><em><a href="https://www.theinformation.com/articles/openais-tbpn-deal-joke?utm_source=ti_app&amp;rc=dcf9pt">was</a></em><a href="https://www.theinformation.com/articles/openais-tbpn-deal-joke?utm_source=ti_app&amp;rc=dcf9pt"> an April Fool’s</a><span>:</span></p>
        """
        let markdown = try convertMarkdown(html)
        #expect(
            markdown.contains("A bunch of employees actually thought [it](https://www.theinformation.com/articles/openais-tbpn-deal-joke?utm_source=ti_app&rc=dcf9pt) _[was](https://www.theinformation.com/articles/openais-tbpn-deal-joke?utm_source=ti_app&rc=dcf9pt)_ [an April Fool’s](https://www.theinformation.com/articles/openais-tbpn-deal-joke?utm_source=ti_app&rc=dcf9pt):"),
            "Adjacent link/em/link segments must preserve spaces outside Markdown wrappers, got: \(markdown)"
        )
    }

    @Test

    func test_adjacentLinkedEmphasisSegments_surviveRoundTrip() throws {
        let html = """
        <p><span>A bunch of employees actually thought </span><a href="https://www.theinformation.com/articles/openais-tbpn-deal-joke?utm_source=ti_app&amp;rc=dcf9pt">it </a><em><a href="https://www.theinformation.com/articles/openais-tbpn-deal-joke?utm_source=ti_app&amp;rc=dcf9pt">was</a></em><a href="https://www.theinformation.com/articles/openais-tbpn-deal-joke?utm_source=ti_app&amp;rc=dcf9pt"> an April Fool’s</a><span>:</span></p>
        """
        let rendered = try roundTrip(html)
        #expect(
            try countElements("article.reader > p a", in: rendered) == 3,
            "Round-trip HTML must keep the three adjacent anchors"
        )
        #expect(
            try countElements("article.reader > p em > a", in: rendered) == 1,
            "Round-trip HTML must preserve the emphasized linked segment"
        )
        #expect(
            try firstElementText("article.reader > p", in: rendered) == "A bunch of employees actually thought it was an April Fool’s:",
            "Round-trip paragraph text must preserve spaces around the emphasized link sequence"
        )
    }

    @Test

    func test_nonBreakingSpace_beforeLink_preservesSemanticWhitespace() throws {
        let html = """
        <p>Hello&nbsp;<a href="https://example.com/world">world</a>.</p>
        """
        let markdown = try convertMarkdown(html)
        #expect(
            markdown.contains("Hello\u{00A0}[world](https://example.com/world)."),
            "A non-breaking space before a link must not collapse to ASCII space, got: \(markdown)"
        )
    }

    @Test

    func test_nonBreakingSpace_insideLinkBoundary_isNotMovedOutsideWrapper() throws {
        let html = """
        <p><a href="https://example.com/world">&nbsp;world</a> continues.</p>
        """
        let markdown = try convertMarkdown(html)
        #expect(
            markdown.contains("[\u{00A0}world](https://example.com/world) continues."),
            "A non-breaking space inside link content must stay inside the wrapper payload, got: \(markdown)"
        )
    }

    @Test

    func test_adjacentLinks_separatedBySpace_preserveMarkdownSpacing() throws {
        let html = """
        <p><a href="https://x.com/karpathy">Karpathy's</a> <a href="https://github.com/karpathy/autoresearch">auto-research</a> applied to startup optimization.</p>
        """
        let markdown = try convertMarkdown(html)
        #expect(
            markdown.contains("[Karpathy's](https://x.com/karpathy) [auto-research](https://github.com/karpathy/autoresearch) applied to startup optimization."),
            "Adjacent inline links separated by a whitespace-only text node must keep that space, got: \(markdown)"
        )
    }

    @Test

    func test_adjacentLinks_separatedBySpace_surviveRoundTrip() throws {
        let html = """
        <p><a href="https://x.com/karpathy">Karpathy's</a> <a href="https://github.com/karpathy/autoresearch">auto-research</a> applied to startup optimization.</p>
        """
        let rendered = try roundTrip(html)
        #expect(
            try countElements("article.reader > p > a", in: rendered) == 2,
            "Round-trip HTML must keep both adjacent links as separate anchors"
        )
        let paragraphText = try firstElementText("article.reader > p", in: rendered)?
            .replacingOccurrences(of: "’", with: "'")
        #expect(
            paragraphText == "Karpathy's auto-research applied to startup optimization.",
            "Round-trip paragraph text must preserve the space between adjacent links"
        )
    }

    @Test

    func test_whitespaceOnlyLink_doesNotLeakHrefIntoMarkdown() throws {
        let html = """
        <p>Alpha<a href="https://example.com/ghost"> </a>Omega</p>
        """
        let markdown = try convertMarkdown(html)
        #expect(
            markdown.contains("Alpha Omega"),
            "Whitespace-only links must preserve separator spacing without exposing href text, got: \(markdown)"
        )
        #expect(
            markdown.contains("https://example.com/ghost") == false,
            "Whitespace-only links must not surface their href in Markdown, got: \(markdown)"
        )
    }

    @Test

    func test_whitespaceOnlyLink_doesNotLeakHrefOnRoundTrip() throws {
        let html = """
        <p>Alpha<a href="https://example.com/ghost"> </a>Omega</p>
        """
        let rendered = try roundTrip(html)
        #expect(try countElements("article.reader > p", in: rendered) == 1, "Whitespace-only links must remain inline")
        #expect(
            try countElements("article.reader > p > a", in: rendered) == 0,
            "Whitespace-only links must not reappear as visible anchors after round-trip"
        )
        #expect(
            try firstElementText("article.reader > p", in: rendered) == "Alpha Omega",
            "Whitespace-only links must preserve separator spacing in rendered text"
        )
    }

    @Test

    func test_inlineVideoInsideGenericContainer_preservesSentenceFlowInMarkdown() throws {
        let html = """
        <div>Watch <video src="https://example.com/clip.mp4"></video> now.</div>
        """
        let markdown = try convertMarkdown(html)
        #expect(
            markdown.contains("Watch [Video](https://example.com/clip.mp4) now."),
            "Inline video inside a generic inline-flow container must not break the sentence, got: \(markdown)"
        )
    }

    @Test

    func test_inlineVideoInsideGenericContainer_survivesRoundTrip() throws {
        let html = """
        <div>Watch <video src="https://example.com/clip.mp4"></video> now.</div>
        """
        let rendered = try roundTrip(html)
        #expect(try countElements("article.reader > p", in: rendered) == 1, "Inline video inside a generic container must render as one paragraph")
        #expect(
            rendered.contains("<p>Watch <a href=\"https://example.com/clip.mp4\">Video</a> now.</p>"),
            "Round-trip HTML must keep inline video placeholder inside the sentence, got: \(rendered)"
        )
    }

    @Test

    func test_inlineAudioInsideGenericContainer_preservesSentenceFlowInMarkdown() throws {
        let html = """
        <div>Listen <audio src="https://example.com/clip.mp3"></audio> now.</div>
        """
        let markdown = try convertMarkdown(html)
        #expect(
            markdown.contains("Listen [Audio](https://example.com/clip.mp3) now."),
            "Inline audio inside a generic inline-flow container must not break the sentence, got: \(markdown)"
        )
    }

    @Test

    func test_inlineAudioInsideGenericContainer_survivesRoundTrip() throws {
        let html = """
        <div>Listen <audio src="https://example.com/clip.mp3"></audio> now.</div>
        """
        let rendered = try roundTrip(html)
        #expect(try countElements("article.reader > p", in: rendered) == 1, "Inline audio inside a generic container must render as one paragraph")
        #expect(
            rendered.contains("<p>Listen <a href=\"https://example.com/clip.mp3\">Audio</a> now.</p>"),
            "Round-trip HTML must keep inline audio placeholder inside the sentence, got: \(rendered)"
        )
    }

    @Test

    func test_listItem_adjacentLinksSeparatedBySpace_preserveMarkdownSpacing() throws {
        let html = """
        <ul>
          <li><a href="https://example.com/first">First</a> <a href="https://example.com/second">Second</a></li>
        </ul>
        """
        let markdown = try convertMarkdown(html)
        #expect(
            markdown.contains("- [First](https://example.com/first) [Second](https://example.com/second)"),
            "List item inline siblings must preserve whitespace-only separators, got: \(markdown)"
        )
    }

    @Test

    func test_spanWrappedLink_preservesSpacesOnBothSides() throws {
        let html = """
        <p><span>Release</span> <span><a href="https://github.com/datasette/datasette-files-s3/releases/tag/0.1a1">datasette-files-s3 0.1a1</a></span> <span>— datasette-files S3 backend</span></p>
        """
        let markdown = try convertMarkdown(html)
        #expect(
            markdown.contains("Release [datasette-files-s3 0.1a1](https://github.com/datasette/datasette-files-s3/releases/tag/0.1a1) — datasette-files S3 backend"),
            "Inline wrapper spans around a linked phrase must preserve surrounding spaces, got: \(markdown)"
        )
    }

    @Test

    func test_spanWrappedLink_survivesRoundTripWithReadableSpacing() throws {
        let html = """
        <p><span>Release</span> <span><a href="https://github.com/datasette/datasette-files-s3/releases/tag/0.1a1">datasette-files-s3 0.1a1</a></span> <span>— datasette-files S3 backend</span></p>
        """
        let rendered = try roundTrip(html)
        #expect(
            try countElements("article.reader > p > a", in: rendered) == 1,
            "Round-trip HTML must keep the wrapped linked phrase as a single anchor"
        )
        #expect(
            try firstElementText("article.reader > p", in: rendered) == "Release datasette-files-s3 0.1a1 — datasette-files S3 backend",
            "Round-trip paragraph text must preserve spaces around a wrapped inline link"
        )
    }

    // MARK: - Horizontal rule

    @Test

    func test_hr_exactMarkdown() throws {
        let html = "<p>Before rule.</p><hr><p>After rule.</p>"
        let markdown = try convertMarkdown(html)
        #expect(markdown.contains("---"), "hr must produce a horizontal rule in Markdown")
    }

    // MARK: - Nested lists

    @Test

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
        #expect(markdown.contains("- Top item A"), "Top-level item must appear at root indentation")
        #expect(markdown.contains("  - Sub-item A1"), "Nested item must be indented two spaces")
        #expect(markdown.contains("  - Sub-item A2"), "Second nested item must be indented two spaces")
        #expect(markdown.contains("- Top item B"), "Second top-level item must appear")
    }

    @Test

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
        #expect(markdown.contains("1. Step one"), "First ordered item must appear")
        #expect(markdown.contains("  1. Sub-step 1a"), "Nested ordered item must be indented")
        #expect(markdown.contains("2. Step two"), "Second ordered item must appear")
    }

    @Test

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
        #expect(try htmlContains("ul", in: rendered), "ul must survive round-trip")
        #expect(
            try countElements("li", in: rendered) >= 2,
            "Both list items must survive round-trip"
        )
    }

    @Test

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
        #expect(snapshot.segments.count == 3, "p + ul + p must produce three segments")
        #expect(snapshot.segments.map(\.segmentType) == [.p, .ul, .p])
    }

    // MARK: - Mixed media paragraph

    @Test

    func test_mixedMedia_imageFollowedByParagraph_exactMarkdown() throws {
        let html = """
        <p><img src="https://example.com/banner.jpg" alt="Banner"></p>
        <p>Article introduction follows the banner image.</p>
        """
        let markdown = try convertMarkdown(html)
        #expect(markdown.contains("![Banner](https://example.com/banner.jpg)"), "Banner image must be present")
        #expect(markdown.contains("Article introduction follows the banner image."), "Body text must be present")
    }

    @Test

    func test_mixedMedia_linkedImageFollowedByParagraph_exactMarkdown() throws {
        let html = """
        <p><a href="https://example.com/page"><img src="https://cdn.example.com/hero.jpg" alt="Hero image"></a></p>
        <p>The hero image above links to the full article page.</p>
        """
        let markdown = try convertMarkdown(html)
        #expect(
            markdown.contains("[![Hero image](https://cdn.example.com/hero.jpg)](https://example.com/page)"),
            "Linked hero image must produce nested Markdown image syntax"
        )
        #expect(
            markdown.contains("The hero image above links to the full article page."),
            "Body text must follow the image"
        )
    }

    @Test

    func test_inlineImage_midSentence_preservesSingleParagraphMarkdown() throws {
        let html = """
        <p>Logo <img src="https://example.com/logo.png" alt="Mercury logo"> appears inline.</p>
        """
        let markdown = try convertMarkdown(html)
        #expect(
            markdown.contains("Logo ![Mercury logo](https://example.com/logo.png) appears inline."),
            "Inline image syntax must stay inside the sentence without blank lines, got: \(markdown)"
        )
        #expect(
            !markdown.contains("Logo \n\n![Mercury logo]"),
            "Inline image must not inject a paragraph break, got: \(markdown)"
        )
    }

    @Test

    func test_inlineImage_midSentence_survivesRoundTripAsSingleParagraph() throws {
        let html = """
        <p>Logo <img src="https://example.com/logo.png" alt="Mercury logo"> appears inline.</p>
        """
        let rendered = try roundTrip(html)
        #expect(try countElements("article.reader > p", in: rendered) == 1, "Inline image sentence must remain a single paragraph")
        #expect(try countElements("article.reader > p img", in: rendered) == 1, "Inline image must remain inside the paragraph")
        #expect(
            try firstElementText("article.reader > p", in: rendered) == "Logo appears inline.",
            "Round-trip paragraph text must remain on one line around the inline image"
        )
    }

    @Test

    func test_mixedMedia_figureWithCaptionAndParagraph_domRoundTrip() throws {
        let html = """
        <figure>
          <img src="https://example.com/photo.jpg" alt="Photo">
          <figcaption>A scenic view.</figcaption>
        </figure>
        <p>Description paragraph follows the figure.</p>
        """
        let rendered = try roundTrip(html)
        #expect(try htmlContains("img", in: rendered), "img must survive round-trip in figure fixture")
        #expect(try htmlContains("em", in: rendered), "figcaption italic must survive round-trip")
        #expect(try htmlContains("p", in: rendered), "paragraph must survive round-trip")
    }

    @Test

    func test_mixedMedia_translationCompatibility() throws {
        let html = """
        <p><img src="https://example.com/lead.jpg" alt="Lead"></p>
        <p>First body paragraph.</p>
        <p>Second body paragraph.</p>
        """
        let snapshot = try translationSnapshot(html: html, entryId: 330)
        // Image-only paragraph must not create a translation segment.
        #expect(snapshot.segments.count == 2, "Image-only p must not create a translation segment")
        #expect(snapshot.segments.allSatisfy { $0.segmentType == .p })
    }

    // MARK: - Round-trip DOM assertions for figure and picture (consolidating Phase 4)

    @Test

    func test_figureWithCaption_domRoundTrip() throws {
        let html = """
        <figure>
          <img src="https://example.com/landscape.jpg" alt="Landscape">
          <figcaption>Mountain landscape at dusk.</figcaption>
        </figure>
        """
        let rendered = try roundTrip(html)
        #expect(try htmlContains("img", in: rendered), "img must survive figure round-trip")
        #expect(
            try firstAttribute("src", ofSelector: "img", in: rendered) == "https://example.com/landscape.jpg",
            "Image src must be preserved through figure round-trip"
        )
    }

    @Test

    func test_figureWithCaption_rendersAsImageParagraphThenItalicCaptionParagraph() throws {
        let html = """
        <figure>
          <img src="https://example.com/photo.jpg" alt="Landscape">
          <figcaption>A scenic view of the valley.</figcaption>
        </figure>
        """
        let rendered = try roundTrip(html)
        #expect(try countElements("article.reader > p", in: rendered) == 2, "Figure with caption must render as image paragraph followed by caption paragraph")
        #expect(try countElements("article.reader > p:first-of-type > img", in: rendered) == 1, "First paragraph must contain the image")
        #expect(try countElements("article.reader > p:nth-of-type(2) > em", in: rendered) == 1, "Second paragraph must contain italic caption text")
        #expect(try firstElementText("article.reader > p:nth-of-type(2) > em", in: rendered) == "A scenic view of the valley.")
    }

    @Test

    func test_responsivePicture_domRoundTrip() throws {
        let html = """
        <picture>
          <source srcset="https://example.com/photo@2x.webp" type="image/webp">
          <img src="https://example.com/photo.jpg" alt="Photo">
        </picture>
        """
        let rendered = try roundTrip(html)
        #expect(try htmlContains("img", in: rendered), "img must survive picture round-trip")
        #expect(
            try firstAttribute("src", ofSelector: "img", in: rendered) == "https://example.com/photo.jpg",
            "Primary img src must be used after picture collapse"
        )
        #expect(
            !(try htmlContains("picture", in: rendered)),
            "picture tag must not appear in rendered output"
        )
    }

    // MARK: - Round-trip DOM assertions for simple table (consolidating Phase 4)

    @Test

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
        #expect(rendered.contains("Alice"), "Table content must survive round-trip")
        #expect(rendered.contains("95"), "Table value must survive round-trip")
    }

    // MARK: - Complex table fallback (consolidating Phase 4)

    @Test

    func test_complexTable_colspanContent_appearsInRoundTrip() throws {
        let html = """
        <table>
          <thead><tr><th colspan="2">Spanned header</th></tr></thead>
          <tbody><tr><td>Cell A</td><td>Cell B</td></tr></tbody>
        </table>
        """
        // Complex table falls back to child-text rendering.
        let rendered = try roundTrip(html)
        #expect(rendered.contains("Spanned header"), "Spanned header text must survive round-trip")
        #expect(rendered.contains("Cell A"), "Cell content must survive round-trip fallback")
    }

    // MARK: - Blockquote

    @Test

    func test_blockquote_exactMarkdown() throws {
        let html = "<blockquote><p>A wise saying attributed to someone.</p></blockquote>"
        let markdown = try convertMarkdown(html)
        #expect(markdown.contains("> A wise saying"), "blockquote must produce > prefix")
    }

    @Test

    func test_blockquote_domRoundTrip() throws {
        let html = "<blockquote><p>Quoted text content.</p></blockquote>"
        let rendered = try roundTrip(html)
        #expect(try htmlContains("blockquote", in: rendered), "blockquote must survive round-trip")
    }

    // MARK: - Code block

    @Test

    func test_codeBlock_exactMarkdown() throws {
        let html = "<pre><code>let x = 42\nprint(x)</code></pre>"
        let markdown = try convertMarkdown(html)
        #expect(markdown.contains("```"), "pre/code must produce fenced code block")
        #expect(markdown.contains("let x = 42"), "Code content must be preserved")
    }

    @Test

    func test_codeBlock_domRoundTrip() throws {
        let html = "<pre><code>func greet() -> String { return \"Hello\" }</code></pre>"
        let rendered = try roundTrip(html)
        #expect(try htmlContains("code", in: rendered), "code block must survive round-trip")
    }

    @Test

    func test_markdownPreType_exactMarkdown() throws {
        let html = "<pre data-readability-pre-type=\"markdown\">## Section\n\n- item one\n- item two\n</pre>"
        let markdown = try convertMarkdown(html)
        #expect(markdown.contains("## Section"), "Markdown pre must preserve heading syntax, got: \(markdown)")
        #expect(markdown.contains("- item one"), "Markdown pre must preserve list syntax, got: \(markdown)")
        #expect(!markdown.contains("```"), "Markdown pre must not be wrapped as fenced code, got: \(markdown)")
    }

    @Test

    func test_markdownPreType_domRoundTripRendersMarkdownStructure() throws {
        let html = "<pre data-readability-pre-type=\"markdown\">## Section\n\n- item one\n- item two\n</pre>"
        let rendered = try roundTrip(html)
        #expect(!(try htmlContains("pre", in: rendered)), "Markdown pre must not render back to a pre block")
        #expect(try htmlContains("h2", in: rendered), "Markdown pre must render heading structure")
        #expect(try htmlContains("ul", in: rendered), "Markdown pre must render list structure")
        #expect(try countElements("li", in: rendered) == 2, "Markdown pre list items must survive round-trip")
    }

    @Test

    func test_markdownPreType_translationCompatibilityUsesRenderedMarkdownBlocks() throws {
        let html = "<pre data-readability-pre-type=\"markdown\">Lead paragraph.\n\n- item one\n- item two\n</pre>"
        let snapshot = try translationSnapshot(html: html, entryId: 320)
        #expect(snapshot.segments.count == 2, "Markdown pre must segment as paragraph plus list")
        #expect(snapshot.segments[0].segmentType == .p)
        #expect(snapshot.segments[1].segmentType == .ul)
    }

    @Test

    func test_codePreType_exactMarkdownProducesFencedCodeBlock() throws {
        let html = "<pre data-readability-pre-type=\"code\">let value = 42\nprint(value)</pre>"
        let markdown = try convertMarkdown(html)
        #expect(markdown.contains("```"), "Code pre must still produce fenced code block, got: \(markdown)")
        #expect(markdown.contains("let value = 42"), "Code pre must preserve content, got: \(markdown)")
    }
}
