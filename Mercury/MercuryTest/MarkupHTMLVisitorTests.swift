//
//  MarkupHTMLVisitorTests.swift
//  MercuryTest
//

import Testing
@testable import Mercury

@MainActor
struct MarkupHTMLVisitorTests {
    @Test
    func rendersGFMPipeTableAsTableHTML() throws {
        let markdown = """
        | Name | Value |
        | --- | ---: |
        | A | 1 |
        """

        let rendered = try render(markdown)

        #expect(rendered.contains("<table>"))
        #expect(rendered.contains("<th align=\"right\">Value</th>"))
        #expect(rendered.contains("<td align=\"right\">1</td>"))
    }

    @Test
    func rendersStrikethroughAsDel() throws {
        let rendered = try render("Use ~~legacy~~ renderer.")

        #expect(rendered.contains("<p>Use <del>legacy</del> renderer.</p>\n"))
    }

    @Test
    func preservesInlineHTMLPassthrough() throws {
        let rendered = try render("Footnote<sup>1</sup>")

        #expect(rendered.contains("<sup>1</sup>"))
    }

    @Test
    func rendersSingleLineDataImageMarkdownAsImage() throws {
        let rendered = try render("![](data:image/jpeg;base64,AAAA)")

        #expect(rendered.contains("<img src=\"data:image/jpeg;base64,AAAA\" alt=\"\" />"))
    }

    @Test
    func multilineDataImageMarkdownFallsBackToLiteralText() throws {
        let rendered = try render(
            """
            ![](data:image/jpeg;base64,
            AAAA)
            """
        )

        #expect(rendered.contains("<p>![](data:image/jpeg;base64,\nAAAA)</p>"))
    }

    @Test
    func scopesItalicBlockDisplayToImageAdjacentCaptionParagraphs() throws {
        let rendered = try render(
            """
            ![Landscape](https://example.com/photo.jpg)

            *A scenic view.*
            """
        )

        #expect(rendered.contains("<p class=\"reader-image-block\"><img src=\"https://example.com/photo.jpg\" alt=\"Landscape\" /></p>"))
        #expect(rendered.contains("<p class=\"reader-image-caption\"><em>A scenic view.</em></p>"))
        #expect(rendered.contains("p.reader-image-caption > em {"))
        #expect(rendered.contains("p:has(> em:only-child)") == false)
    }

    @Test
    func imageFollowedByReferenceNoteWithInlineEmphasisDoesNotBecomeCaption() throws {
        let rendered = try render(
            """
            ![Baragar's illustration](https://www.johndcook.com/baragar_star_trek.png)

            [1] Baragar, Arthur (2001), *A Survey of Classical and Modern Geometries: With Computer Activities*, Prentice Hall
            """
        )

        #expect(rendered.contains("<p class=\"reader-image-block\">") == false)
        #expect(rendered.contains("<p class=\"reader-image-caption\">") == false)
        #expect(
            rendered.contains("<p>[1] Baragar, Arthur (2001), <em>A Survey of Classical and Modern Geometries: With Computer Activities</em>, Prentice Hall</p>"),
            "Reference note must remain a normal paragraph with inline emphasis, got: \(rendered)"
        )
    }

    private func render(_ markdown: String) throws -> String {
        try ReaderHTMLRenderer.render(markdown: markdown, themeId: "light")
    }
}
