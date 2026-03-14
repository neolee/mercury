//
//  MarkupHTMLVisitor.swift
//  Mercury
//
//  Created by Codex on 2026/3/14.
//

import Foundation
import Markdown

struct MarkupHTMLVisitor: MarkupVisitor {
    typealias Result = String

    private struct TableContext {
        var columnAlignments: [Table.ColumnAlignment?]
        var isRenderingHead = false
        var currentColumn = 0
    }

    private var tableContextStack: [TableContext] = []

    mutating func defaultVisit(_ markup: Markup) -> String {
        renderChildren(of: markup)
    }

    mutating func visitDocument(_ document: Document) -> String {
        renderChildren(of: document)
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) -> String {
        "<blockquote>\n\(renderChildren(of: blockQuote))</blockquote>\n"
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> String {
        let languageAttribute: String
        if let language = codeBlock.language, !language.isEmpty {
            languageAttribute = " class=\"language-\(escapeAttribute(language))\""
        } else {
            languageAttribute = ""
        }

        return "<pre><code\(languageAttribute)>\(escapeText(codeBlock.code))</code></pre>\n"
    }

    mutating func visitHeading(_ heading: Heading) -> String {
        "<h\(heading.level)>\(renderChildren(of: heading))</h\(heading.level)>\n"
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) -> String {
        "<hr />\n"
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) -> String {
        html.rawHTML
    }

    mutating func visitOrderedList(_ orderedList: OrderedList) -> String {
        let startAttribute: String
        if orderedList.startIndex != 1 {
            startAttribute = " start=\"\(orderedList.startIndex)\""
        } else {
            startAttribute = ""
        }

        return "<ol\(startAttribute)>\n\(renderChildren(of: orderedList))</ol>\n"
    }

    mutating func visitUnorderedList(_ unorderedList: UnorderedList) -> String {
        "<ul>\n\(renderChildren(of: unorderedList))</ul>\n"
    }

    mutating func visitListItem(_ listItem: ListItem) -> String {
        var result = "<li>"

        if let checkbox = listItem.checkbox {
            result += "<input type=\"checkbox\" disabled=\"\""
            if checkbox == .checked {
                result += " checked=\"\""
            }
            result += " /> "
        }

        result += renderListItemChildren(listItem)
        result += "</li>\n"
        return result
    }

    mutating func visitParagraph(_ paragraph: Paragraph) -> String {
        "<p>\(renderChildren(of: paragraph))</p>\n"
    }

    mutating func visitTable(_ table: Table) -> String {
        tableContextStack.append(TableContext(columnAlignments: table.columnAlignments))
        defer { _ = tableContextStack.popLast() }

        return "<table>\n\(renderChildren(of: table))</table>\n"
    }

    mutating func visitTableHead(_ tableHead: Table.Head) -> String {
        guard !tableContextStack.isEmpty else {
            return "<thead>\n<tr>\n\(renderChildren(of: tableHead))</tr>\n</thead>\n"
        }

        tableContextStack[tableContextStack.count - 1].isRenderingHead = true
        tableContextStack[tableContextStack.count - 1].currentColumn = 0
        defer {
            tableContextStack[tableContextStack.count - 1].isRenderingHead = false
        }

        return "<thead>\n<tr>\n\(renderChildren(of: tableHead))</tr>\n</thead>\n"
    }

    mutating func visitTableBody(_ tableBody: Table.Body) -> String {
        guard !tableBody.isEmpty else {
            return ""
        }
        return "<tbody>\n\(renderChildren(of: tableBody))</tbody>\n"
    }

    mutating func visitTableRow(_ tableRow: Table.Row) -> String {
        if !tableContextStack.isEmpty {
            tableContextStack[tableContextStack.count - 1].currentColumn = 0
        }
        return "<tr>\n\(renderChildren(of: tableRow))</tr>\n"
    }

    mutating func visitTableCell(_ tableCell: Table.Cell) -> String {
        guard tableCell.colspan > 0, tableCell.rowspan > 0 else {
            return ""
        }

        let isHeadCell = tableContextStack.last?.isRenderingHead ?? false
        let tag = isHeadCell ? "th" : "td"
        var attributes = ""

        if let context = tableContextStack.last,
           context.currentColumn < context.columnAlignments.count,
           let alignment = context.columnAlignments[context.currentColumn] {
            attributes += " align=\"\(alignment.rawHTMLValue)\""
        }

        if tableCell.rowspan > 1 {
            attributes += " rowspan=\"\(tableCell.rowspan)\""
        }

        if tableCell.colspan > 1 {
            attributes += " colspan=\"\(tableCell.colspan)\""
        }

        if !tableContextStack.isEmpty {
            tableContextStack[tableContextStack.count - 1].currentColumn += max(Int(tableCell.colspan), 1)
        }

        return "<\(tag)\(attributes)>\(renderChildren(of: tableCell))</\(tag)>\n"
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) -> String {
        "<code>\(escapeText(inlineCode.code))</code>"
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) -> String {
        wrapInline(tag: "em", markup: emphasis)
    }

    mutating func visitStrong(_ strong: Strong) -> String {
        wrapInline(tag: "strong", markup: strong)
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) -> String {
        wrapInline(tag: "del", markup: strikethrough)
    }

    mutating func visitImage(_ image: Image) -> String {
        var attributes = ""

        if let source = image.source, !source.isEmpty {
            attributes += " src=\"\(escapeAttribute(source))\""
        }

        let altText = image.plainText
        attributes += " alt=\"\(escapeAttribute(altText))\""

        if let title = image.title, !title.isEmpty {
            attributes += " title=\"\(escapeAttribute(title))\""
        }

        return "<img\(attributes) />"
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) -> String {
        inlineHTML.rawHTML
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) -> String {
        "<br />\n"
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) -> String {
        "\n"
    }

    mutating func visitLink(_ link: Link) -> String {
        var attributes = ""
        if let destination = link.destination, !destination.isEmpty {
            attributes += " href=\"\(escapeAttribute(destination))\""
        }
        if let title = link.title, !title.isEmpty {
            attributes += " title=\"\(escapeAttribute(title))\""
        }
        return "<a\(attributes)>\(renderChildren(of: link))</a>"
    }

    mutating func visitText(_ text: Text) -> String {
        escapeText(text.string)
    }

    mutating func visitSymbolLink(_ symbolLink: SymbolLink) -> String {
        "<code>\(escapeText(symbolLink.destination ?? ""))</code>"
    }

    private mutating func renderChildren(of markup: Markup) -> String {
        markup.children.map { visit($0) }.joined()
    }

    private mutating func renderListItemChildren(_ listItem: ListItem) -> String {
        let children = Array(listItem.children)
        guard !children.isEmpty else {
            return ""
        }

        var result = ""
        for (index, child) in children.enumerated() {
            if let paragraph = child as? Paragraph,
               shouldUnwrapParagraph(in: children, at: index) {
                result += renderChildren(of: paragraph)
                if index < children.count - 1 {
                    result += "\n"
                }
            } else {
                result += visit(child)
            }
        }
        return result
    }

    private func shouldUnwrapParagraph(in children: [Markup], at index: Int) -> Bool {
        guard index == 0,
              children[index] is Paragraph else {
            return false
        }

        if children.count == 1 {
            return true
        }

        return children.dropFirst().allSatisfy { child in
            child is OrderedList || child is UnorderedList
        }
    }

    private mutating func wrapInline(tag: String, markup: Markup) -> String {
        "<\(tag)>\(renderChildren(of: markup))</\(tag)>"
    }

    private func escapeText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func escapeAttribute(_ text: String) -> String {
        escapeText(text)
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

private extension Table.ColumnAlignment {
    var rawHTMLValue: String {
        switch self {
        case .left:
            return "left"
        case .center:
            return "center"
        case .right:
            return "right"
        }
    }
}
