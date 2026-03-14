//
//  MarkupHTMLVisitorTests.swift
//  MercuryTest
//

import Testing
@testable import Mercury

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

    private func render(_ markdown: String) throws -> String {
        try ReaderHTMLRenderer.render(markdown: markdown, themeId: "light")
    }
}
