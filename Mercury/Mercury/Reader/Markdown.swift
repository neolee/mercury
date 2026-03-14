//
//  Markdown.swift
//  Mercury
//

import Foundation
import Readability
import SwiftSoup

enum MarkdownConverter {
    static func markdownFromReadability(_ result: ReadabilityResult) throws -> String {
        try markdownFromParts(
            title: result.title,
            byline: result.byline,
            contentHTML: result.content,
            textContentFallback: result.textContent
        )
    }

    /// Converts persisted Readability output back to Markdown without re-parsing the DOM.
    /// Use this path when `cleanedHtml`, `readabilityTitle`, and `readabilityByline` have
    /// already been persisted and a full `ReadabilityResult` is not available.
    static func markdownFromPersisted(
        contentHTML: String,
        title: String?,
        byline: String?
    ) throws -> String {
        try markdownFromParts(
            title: title ?? "",
            byline: byline,
            contentHTML: contentHTML,
            textContentFallback: ""
        )
    }

    private static func markdownFromParts(
        title: String,
        byline: String?,
        contentHTML: String,
        textContentFallback: String
    ) throws -> String {
        var parts: [String] = []

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTitle.isEmpty == false {
            parts.append("# \(trimmedTitle)")
        }

        if let byline = byline?.trimmingCharacters(in: .whitespacesAndNewlines), byline.isEmpty == false {
            parts.append("_\(byline)_")
        }

        let bodyMarkdown = try markdownFromHTML(contentHTML)
        if bodyMarkdown.isEmpty == false {
            parts.append(bodyMarkdown)
        } else if textContentFallback.isEmpty == false {
            let fallback = textContentFallback
                .replacingOccurrences(of: "\n", with: "\n\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if fallback.isEmpty == false {
                parts.append(fallback)
            }
        }

        return parts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func markdownFromHTML(_ html: String) throws -> String {
        let document = try SwiftSoup.parse(html)
        let root = document.body() ?? document
        return try renderMarkdown(from: root)
            .replacingOccurrences(of: "\n\n\n+", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func renderMarkdown(from node: Node) throws -> String {
        if let textNode = node as? TextNode {
            let raw = textNode.text().replacingOccurrences(of: "\n", with: " ")
            // Whitespace-only nodes arise from HTML indentation between block elements
            // and must not produce leading spaces that corrupt block-level Markdown format.
            return raw.trimmingCharacters(in: .whitespaces).isEmpty ? "" : raw
        }

        guard let element = node as? Element else {
            return ""
        }

        let tag = element.tagName().lowercased()
        switch tag {
        case "h1", "h2", "h3", "h4", "h5", "h6":
            let level = Int(tag.dropFirst()) ?? 1
            let text = try renderChildrenMarkdown(from: element).trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(String(repeating: "#", count: level)) \(text)\n\n"
        case "p":
            let text = try renderChildrenMarkdown(from: element)
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\(text)\n\n"
        case "br":
            return "\n"
        case "ul", "ol":
            let content = try renderList(from: element, depth: 0)
            return content.isEmpty ? "" : content + "\n\n"
        case "hr":
            return "---\n\n"
        case "blockquote":
            let text = try renderChildrenMarkdown(from: element)
            let quoted = text
                .split(separator: "\n")
                .map { "> \($0)" }
                .joined(separator: "\n")
            return quoted + "\n\n"
        case "pre":
            let text = try element.text()
            return "```\n\(text)\n```\n\n"
        case "code":
            let text = try element.text()
            return "`\(text)`"
        case "img":
            let alt = (try? element.attr("alt")) ?? ""
            let src = (try? element.attr("src")) ?? ""
            guard src.isEmpty == false else { return "" }
            return "![\(alt)](\(src))\n\n"
        case "a":
            let href = (try? element.attr("href")) ?? ""
            guard href.isEmpty == false else {
                return try renderChildrenMarkdown(from: element)
            }
            // a > img  or  a > picture > img: emit nested image syntax
            let elementChildren = element.children().array()
            if elementChildren.count == 1,
               let imgMd = try primaryImageMarkdown(from: elementChildren[0]) {
                return "[\(imgMd)](\(href))"
            }
            let inner = try renderChildrenMarkdown(from: element).trimmingCharacters(in: .whitespacesAndNewlines)
            return "[\(inner.isEmpty ? href : inner)](\(href))"
        case "picture":
            if let imgMd = try primaryImageMarkdown(from: element) {
                return imgMd + "\n\n"
            }
            return try renderChildrenMarkdown(from: element)
        case "figure":
            let figChildren = element.children().array()
            let mediaChildren = try figChildren.filter { try primaryFigureMediaMarkdown(from: $0) != nil }
            let captionChildren = figChildren.filter { $0.tagName().lowercased() == "figcaption" }
            if mediaChildren.count == 1,
               captionChildren.count <= 1,
               let mediaMarkdown = try primaryFigureMediaMarkdown(from: mediaChildren[0]) {
                var result = mediaMarkdown + "\n\n"
                if let caption = captionChildren.first {
                    let captionText = try caption.text().trimmingCharacters(in: .whitespacesAndNewlines)
                    if captionText.isEmpty == false {
                        result += "_\(captionText)_\n\n"
                    }
                }
                return result
            }
            return try renderChildrenMarkdown(from: element)
        case "figcaption":
            let captionText = try element.text().trimmingCharacters(in: .whitespacesAndNewlines)
            return captionText.isEmpty ? "" : "_\(captionText)_\n\n"
        case "table":
            if let gfm = try renderTableAsGFM(from: element) {
                return gfm
            }
            let tableText = try renderChildrenMarkdown(from: element).trimmingCharacters(in: .whitespacesAndNewlines)
            return tableText.isEmpty ? "" : tableText + "\n\n"
        case "video":
            let videoSrc = (try? element.attr("src")) ?? ""
            if videoSrc.isEmpty == false {
                return "[Video](\(videoSrc))\n\n"
            }
            if let sourceEl = try element.select("source").first(),
               let sourceSrc = try? sourceEl.attr("src"),
               sourceSrc.isEmpty == false {
                return "[Video](\(sourceSrc))\n\n"
            }
            return try renderChildrenMarkdown(from: element)
        case "audio":
            let audioSrc = (try? element.attr("src")) ?? ""
            if audioSrc.isEmpty == false {
                return "[Audio](\(audioSrc))\n\n"
            }
            if let sourceEl = try element.select("source").first(),
               let sourceSrc = try? sourceEl.attr("src"),
               sourceSrc.isEmpty == false {
                return "[Audio](\(sourceSrc))\n\n"
            }
            return try renderChildrenMarkdown(from: element)
        case "em", "i":
            let inner = try renderChildrenMarkdown(from: element).trimmingCharacters(in: .whitespacesAndNewlines)
            return inner.isEmpty ? "" : "_\(inner)_"
        case "strong", "b":
            let inner = try renderChildrenMarkdown(from: element).trimmingCharacters(in: .whitespacesAndNewlines)
            return inner.isEmpty ? "" : "**\(inner)**"
        case "del", "s":
            let inner = try renderChildrenMarkdown(from: element).trimmingCharacters(in: .whitespacesAndNewlines)
            return inner.isEmpty ? "" : "~~\(inner)~~"
        case "sup":
            let supInner = try renderChildrenMarkdown(from: element).trimmingCharacters(in: .whitespacesAndNewlines)
            return supInner.isEmpty ? "" : "<sup>\(supInner)</sup>"
        case "sub":
            let subInner = try renderChildrenMarkdown(from: element).trimmingCharacters(in: .whitespacesAndNewlines)
            return subInner.isEmpty ? "" : "<sub>\(subInner)</sub>"
        default:
            return try renderChildrenMarkdown(from: element)
        }
    }

    // MARK: - List rendering

    /// Renders a `ul` or `ol` element recursively, supporting nested lists with proper indentation.
    private static func renderList(from element: Element, depth: Int) throws -> String {
        let isOrdered = element.tagName().lowercased() == "ol"
        let indent = String(repeating: "  ", count: depth)
        var orderedIndex = 1
        var lines: [String] = []

        for child in element.children().array() {
            guard child.tagName().lowercased() == "li" else { continue }

            var inlineParts: [String] = []
            var nestedListContent = ""

            for node in child.getChildNodes() {
                if let el = node as? Element {
                    let t = el.tagName().lowercased()
                    if t == "ul" || t == "ol" {
                        nestedListContent = try renderList(from: el, depth: depth + 1)
                    } else {
                        inlineParts.append(try renderMarkdown(from: el))
                    }
                } else {
                    inlineParts.append(try renderMarkdown(from: node))
                }
            }

            let text = inlineParts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.isEmpty == false else {
                orderedIndex += 1
                continue
            }

            let bullet = isOrdered ? "\(indent)\(orderedIndex). \(text)" : "\(indent)- \(text)"
            orderedIndex += 1
            lines.append(bullet)
            if nestedListContent.isEmpty == false {
                // Append nested list lines, stripping leading/trailing newlines to avoid double spacing.
                lines.append(nestedListContent.trimmingCharacters(in: .init(charactersIn: "\n")))
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Table rendering

    /// Attempts to convert an HTML table to GFM Markdown.
    /// Returns `nil` when the table structure is too complex for GFM (e.g. colspan, rowspan, no header).
    private static func renderTableAsGFM(from element: Element) throws -> String? {
        let theadRows = try element.select("thead tr").array()
        let tbodyRows = try element.select("tbody tr").array()
        let allRows = try element.select("tr").array()
        guard allRows.isEmpty == false else { return nil }

        let headerRow: Element
        let dataRows: [Element]

        if let firstTheadRow = theadRows.first {
            headerRow = firstTheadRow
            dataRows = tbodyRows
        } else {
            // No explicit thead: accept the first row only if it uses <th> cells.
            guard let firstRow = allRows.first,
                  (try firstRow.select("th").first()) != nil else {
                return nil
            }
            headerRow = firstRow
            dataRows = Array(allRows.dropFirst())
        }

        // Reject tables with colspan or rowspan other than "1".
        for cell in try element.select("th, td").array() {
            let colspan = (try? cell.attr("colspan")) ?? ""
            let rowspan = (try? cell.attr("rowspan")) ?? ""
            if (colspan.isEmpty == false && colspan != "1") || (rowspan.isEmpty == false && rowspan != "1") {
                return nil
            }
        }

        let headerCells = try headerRow.select("th, td").array()
        guard headerCells.isEmpty == false else { return nil }
        let columnCount = headerCells.count

        func renderCell(_ cell: Element) throws -> String {
            let text = try renderChildrenMarkdown(from: cell).trimmingCharacters(in: .whitespacesAndNewlines)
            return text
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "|", with: "\\|")
        }

        let renderedHeader = try headerCells.map { try renderCell($0) }
        var lines: [String] = [
            "| " + renderedHeader.joined(separator: " | ") + " |",
            "| " + Array(repeating: "---", count: columnCount).joined(separator: " | ") + " |"
        ]

        for row in dataRows {
            var cells = try row.select("td, th").array().map { try renderCell($0) }
            while cells.count < columnCount { cells.append("") }
            lines.append("| " + cells.prefix(columnCount).joined(separator: " | ") + " |")
        }

        return lines.joined(separator: "\n") + "\n\n"
    }

    private static func renderChildrenMarkdown(from element: Element) throws -> String {
        let children = element.getChildNodes()
        return try children.map { try renderMarkdown(from: $0) }.joined()
    }

    /// Returns inline image Markdown `![alt](src)` for a bare `img` or `picture` element.
    /// Returns `nil` when no usable `src` is found.
    private static func primaryImageMarkdown(from element: Element) throws -> String? {
        let tag = element.tagName().lowercased()
        if tag == "img" {
            let src = (try? element.attr("src")) ?? ""
            guard !src.isEmpty else { return nil }
            let alt = (try? element.attr("alt")) ?? ""
            return "![\(alt)](\(src))"
        }
        if tag == "picture" {
            guard let img = try element.select("img").first() else { return nil }
            let src = (try? img.attr("src")) ?? ""
            guard !src.isEmpty else { return nil }
            let alt = (try? img.attr("alt")) ?? ""
            return "![\(alt)](\(src))"
        }
        return nil
    }

    /// Returns standalone figure media Markdown for `img`, `picture`, or `a > img/picture`.
    private static func primaryFigureMediaMarkdown(from element: Element) throws -> String? {
        if let imageMarkdown = try primaryImageMarkdown(from: element) {
            return imageMarkdown
        }

        guard element.tagName().lowercased() == "a" else {
            return nil
        }

        let href = (try? element.attr("href")) ?? ""
        guard href.isEmpty == false else {
            return nil
        }

        let elementChildren = element.children().array()
        guard elementChildren.count == 1,
              let imageMarkdown = try primaryImageMarkdown(from: elementChildren[0]) else {
            return nil
        }

        return "[\(imageMarkdown)](\(href))"
    }
}
