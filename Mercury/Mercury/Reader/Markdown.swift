//
//  Markdown.swift
//  Mercury
//

import Foundation
import Readability
import SwiftSoup

enum MarkdownConverter {
    private static let readabilityPreTypeAttribute = "data-readability-pre-type"

    private enum WhitespacePolicy {
        case discardWhitespaceOnlyTextNodes
        case preserveSingleSpaceTextNodes

        func renderedText(for raw: String) -> String {
            guard raw.trimmingCharacters(in: .whitespaces).isEmpty else {
                return raw
            }

            switch self {
            case .discardWhitespaceOnlyTextNodes:
                return ""
            case .preserveSingleSpaceTextNodes:
                return " "
            }
        }
    }

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
        try renderMarkdown(from: node, whitespacePolicy: .discardWhitespaceOnlyTextNodes)
    }

    private static func renderMarkdown(
        from node: Node,
        whitespacePolicy: WhitespacePolicy
    ) throws -> String {
        if let textNode = node as? TextNode {
            let raw = textNode.text().replacingOccurrences(of: "\n", with: " ")
            return whitespacePolicy.renderedText(for: raw)
        }

        guard let element = node as? Element else {
            return ""
        }

        let tag = element.tagName().lowercased()
        switch tag {
        case "h1", "h2", "h3", "h4", "h5", "h6":
            let level = Int(tag.dropFirst()) ?? 1
            let text = try renderInlineChildrenMarkdown(from: element).trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(String(repeating: "#", count: level)) \(text)\n\n"
        case "p":
            if let mediaLeadParagraph = try renderMediaLeadParagraphMarkdown(from: element) {
                return mediaLeadParagraph
            }
            let text = try renderInlineChildrenMarkdown(from: element)
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\(text)\n\n"
        case "br":
            return "\n"
        case "header":
            if try isMetadataOnlyHeader(element) {
                return ""
            }
            return try renderBlockContainerMarkdown(from: element)
        case "body", "html", "div", "article", "section", "main", "aside", "footer", "nav":
            return try renderBlockContainerMarkdown(from: element)
        case "ul", "ol":
            let content = try renderList(from: element, depth: 0)
            return content.isEmpty ? "" : content + "\n\n"
        case "hr":
            return "---\n\n"
        case "blockquote":
            let text = try renderBlockChildrenMarkdown(from: element)
            let quoted = text
                .split(separator: "\n")
                .map { "> \($0)" }
                .joined(separator: "\n")
            return quoted + "\n\n"
        case "pre":
            return try renderPreMarkdown(from: element)
        case "code":
            return try inlineCodeMarkdown(from: element)
        case "img":
            guard let imageMarkdown = try primaryImageMarkdown(from: element) else {
                return ""
            }
            return shouldRenderMediaInline(element, whitespacePolicy: whitespacePolicy)
                ? imageMarkdown
                : imageMarkdown + "\n\n"
        case "a":
            return try renderInlineMarkdown(from: element)
        case "picture":
            if let imgMd = try primaryImageMarkdown(from: element) {
                return shouldRenderMediaInline(element, whitespacePolicy: whitespacePolicy)
                    ? imgMd
                    : imgMd + "\n\n"
            }
            return isInlineWhitespacePolicy(whitespacePolicy)
                ? (try renderInlineMarkdown(from: element))
                : (try renderChildrenMarkdown(from: element, whitespacePolicy: inferredWhitespacePolicy(for: element)))
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
            return try renderBlockChildrenMarkdown(from: element)
        case "figcaption":
            let captionText = try element.text().trimmingCharacters(in: .whitespacesAndNewlines)
            return captionText.isEmpty ? "" : "_\(captionText)_\n\n"
        case "table":
            if let gfm = try renderTableAsGFM(from: element) {
                return gfm
            }
            let tableText = try renderBlockChildrenMarkdown(from: element).trimmingCharacters(in: .whitespacesAndNewlines)
            return tableText.isEmpty ? "" : tableText + "\n\n"
        case "video":
            let videoSrc = (try? element.attr("src")) ?? ""
            if videoSrc.isEmpty == false {
                let videoMarkdown = "[Video](\(videoSrc))"
                return shouldRenderMediaInline(element, whitespacePolicy: whitespacePolicy)
                    ? videoMarkdown
                    : videoMarkdown + "\n\n"
            }
            if let sourceEl = try element.select("source").first(),
               let sourceSrc = try? sourceEl.attr("src"),
               sourceSrc.isEmpty == false {
                let videoMarkdown = "[Video](\(sourceSrc))"
                return shouldRenderMediaInline(element, whitespacePolicy: whitespacePolicy)
                    ? videoMarkdown
                    : videoMarkdown + "\n\n"
            }
            return try renderChildrenMarkdown(from: element, whitespacePolicy: inferredWhitespacePolicy(for: element))
        case "audio":
            let audioSrc = (try? element.attr("src")) ?? ""
            if audioSrc.isEmpty == false {
                let audioMarkdown = "[Audio](\(audioSrc))"
                return shouldRenderMediaInline(element, whitespacePolicy: whitespacePolicy)
                    ? audioMarkdown
                    : audioMarkdown + "\n\n"
            }
            if let sourceEl = try element.select("source").first(),
               let sourceSrc = try? sourceEl.attr("src"),
               sourceSrc.isEmpty == false {
                let audioMarkdown = "[Audio](\(sourceSrc))"
                return shouldRenderMediaInline(element, whitespacePolicy: whitespacePolicy)
                    ? audioMarkdown
                    : audioMarkdown + "\n\n"
            }
            return isInlineWhitespacePolicy(whitespacePolicy)
                ? (try renderInlineMarkdown(from: element))
                : (try renderChildrenMarkdown(from: element, whitespacePolicy: inferredWhitespacePolicy(for: element)))
        case "em", "i":
            return try renderInlineMarkdown(from: element)
        case "strong", "b":
            return try renderInlineMarkdown(from: element)
        case "del", "s":
            return try renderInlineMarkdown(from: element)
        case "sup":
            return try renderInlineMarkdown(from: element)
        case "sub":
            return try renderInlineMarkdown(from: element)
        default:
            return try renderChildrenMarkdown(from: element, whitespacePolicy: inferredWhitespacePolicy(for: element))
        }
    }

    private static func renderPreMarkdown(from element: Element) throws -> String {
        let preType = ((try? element.attr(readabilityPreTypeAttribute)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let text = try normalizedPreformattedText(from: element)

        if preType == "markdown" {
            return text.isEmpty ? "" : text + "\n\n"
        }

        return "```\n\(text)\n```\n\n"
    }

    private static func normalizedPreformattedText(from element: Element) throws -> String {
        let rawText = try preformattedText(from: element)
        return rawText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .newlines)
    }

    private static func preformattedText(from node: Node) throws -> String {
        if let textNode = node as? TextNode {
            return textNode.getWholeText()
        }

        guard let element = node as? Element else {
            return ""
        }

        if element.tagName().lowercased() == "br" {
            return "\n"
        }

        return try element.getChildNodes()
            .map { try preformattedText(from: $0) }
            .joined()
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

            var inlineFragments: [InlineFragment] = []
            var nestedListContent = ""

            for node in child.getChildNodes() {
                if let el = node as? Element {
                    let t = el.tagName().lowercased()
                    if t == "ul" || t == "ol" {
                        nestedListContent = try renderList(from: el, depth: depth + 1)
                    } else {
                        inlineFragments.append(contentsOf: try renderInlineFragments(from: el))
                    }
                } else {
                    inlineFragments.append(contentsOf: try renderInlineFragments(from: node))
                }
            }

            let text = assembleInlineFragments(inlineFragments).trimmingCharacters(in: .whitespacesAndNewlines)
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
            let text = try renderInlineChildrenMarkdown(from: cell).trimmingCharacters(in: .whitespacesAndNewlines)
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

    private static func renderBlockChildrenMarkdown(from element: Element) throws -> String {
        try renderChildrenMarkdown(from: element, whitespacePolicy: .discardWhitespaceOnlyTextNodes)
    }

    private static func renderBlockContainerMarkdown(from element: Element) throws -> String {
        let content = try renderBlockChildrenMarkdown(from: element)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return content.isEmpty ? "" : content + "\n\n"
    }

    private static func isMetadataOnlyHeader(_ element: Element) throws -> Bool {
        guard try containsTimeElement(element) else {
            return false
        }
        return try hasVisibleContentOutsideTime(element) == false
    }

    private static func containsTimeElement(_ node: Node) throws -> Bool {
        guard let element = node as? Element else {
            return false
        }

        if element.tagName().lowercased() == "time" {
            return true
        }

        for child in element.getChildNodes() {
            if try containsTimeElement(child) {
                return true
            }
        }
        return false
    }

    private static func hasVisibleContentOutsideTime(_ node: Node) throws -> Bool {
        if let textNode = node as? TextNode {
            return textNode.getWholeText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }

        guard let element = node as? Element else {
            return false
        }

        let tag = element.tagName().lowercased()
        if tag == "time" {
            return false
        }

        guard isMetadataTransparentWrapper(tag) else {
            return true
        }

        for child in element.getChildNodes() {
            if try hasVisibleContentOutsideTime(child) {
                return true
            }
        }
        return false
    }

    private static func isMetadataTransparentWrapper(_ tag: String) -> Bool {
        switch tag {
        case "header", "span", "a", "p", "div":
            return true
        default:
            return false
        }
    }

    /// Canonicalizes paragraphs shaped like `img + br + caption/link` into two block paragraphs.
    /// This preserves the visual block break from HTML `<br>` without widening `br` behavior globally.
    private static func renderMediaLeadParagraphMarkdown(from element: Element) throws -> String? {
        let nodes = element.getChildNodes()
        guard nodes.isEmpty == false else {
            return nil
        }

        var index = 0
        skipIgnorableInlineWhitespace(in: nodes, index: &index)

        guard index < nodes.count,
              let mediaElement = nodes[index] as? Element,
              let mediaMarkdown = try primaryFigureMediaMarkdown(from: mediaElement) else {
            return nil
        }

        index += 1
        skipIgnorableInlineWhitespace(in: nodes, index: &index)

        guard index < nodes.count,
              let breakElement = nodes[index] as? Element,
              breakElement.tagName().lowercased() == "br" else {
            return nil
        }

        index += 1
        skipIgnorableInlineWhitespace(in: nodes, index: &index)

        let tailNodes = Array(nodes[index...])
        let tailMarkdown = assembleInlineFragments(
            try tailNodes.flatMap { try renderInlineFragments(from: $0) }
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        guard tailMarkdown.isEmpty == false else {
            return nil
        }

        return "\(mediaMarkdown)\n\n\(tailMarkdown)\n\n"
    }

    private static func renderInlineChildrenMarkdown(from element: Element) throws -> String {
        let fragments = try element.getChildNodes().flatMap { try renderInlineFragments(from: $0) }
        return assembleInlineFragments(fragments)
    }

    private enum InlineFragment {
        case text(String)
        case collapsibleSpace
    }

    private static func renderInlineMarkdown(from node: Node) throws -> String {
        assembleInlineFragments(try renderInlineFragments(from: node))
    }

    private static func renderInlineFragments(from node: Node) throws -> [InlineFragment] {
        if let textNode = node as? TextNode {
            return inlineTextFragments(from: textNode.getWholeText())
        }

        guard let element = node as? Element else {
            return []
        }

        let tag = element.tagName().lowercased()
        switch tag {
        case "br":
            return [.text("\n")]
        case "a":
            let href = (try? element.attr("href")) ?? ""
            guard href.isEmpty == false else {
                return try element.getChildNodes().flatMap { try renderInlineFragments(from: $0) }
            }
            let elementChildren = element.children().array()
            if elementChildren.count == 1,
               let imageMarkdown = try primaryImageMarkdown(from: elementChildren[0]) {
                return [.text("[\(imageMarkdown)](\(href))")]
            }
            let childFragments = try element.getChildNodes().flatMap { try renderInlineFragments(from: $0) }
            return wrapInlineFragments(childFragments) { core in
                "[\(core)](\(href))"
            }
        case "em", "i":
            let childFragments = try element.getChildNodes().flatMap { try renderInlineFragments(from: $0) }
            return wrapInlineFragments(childFragments) { core in
                "_\(core)_"
            }
        case "strong", "b":
            let childFragments = try element.getChildNodes().flatMap { try renderInlineFragments(from: $0) }
            return wrapInlineFragments(childFragments) { core in
                "**\(core)**"
            }
        case "del", "s":
            let childFragments = try element.getChildNodes().flatMap { try renderInlineFragments(from: $0) }
            return wrapInlineFragments(childFragments) { core in
                "~~\(core)~~"
            }
        case "sup":
            let childFragments = try element.getChildNodes().flatMap { try renderInlineFragments(from: $0) }
            return wrapInlineFragments(childFragments) { core in
                "<sup>\(core)</sup>"
            }
        case "sub":
            let childFragments = try element.getChildNodes().flatMap { try renderInlineFragments(from: $0) }
            return wrapInlineFragments(childFragments) { core in
                "<sub>\(core)</sub>"
            }
        case "code":
            return [.text(try inlineCodeMarkdown(from: element))]
        case "img", "picture":
            guard let imageMarkdown = try primaryImageMarkdown(from: element) else {
                return try element.getChildNodes().flatMap { try renderInlineFragments(from: $0) }
            }
            return [.text(imageMarkdown)]
        case "video":
            let videoSrc = (try? element.attr("src")) ?? ""
            if videoSrc.isEmpty == false {
                return [.text("[Video](\(videoSrc))")]
            }
            if let sourceEl = try element.select("source").first(),
               let sourceSrc = try? sourceEl.attr("src"),
               sourceSrc.isEmpty == false {
                return [.text("[Video](\(sourceSrc))")]
            }
            return try element.getChildNodes().flatMap { try renderInlineFragments(from: $0) }
        case "audio":
            let audioSrc = (try? element.attr("src")) ?? ""
            if audioSrc.isEmpty == false {
                return [.text("[Audio](\(audioSrc))")]
            }
            if let sourceEl = try element.select("source").first(),
               let sourceSrc = try? sourceEl.attr("src"),
               sourceSrc.isEmpty == false {
                return [.text("[Audio](\(sourceSrc))")]
            }
            return try element.getChildNodes().flatMap { try renderInlineFragments(from: $0) }
        default:
            return try element.getChildNodes().flatMap { try renderInlineFragments(from: $0) }
        }
    }

    private static func inlineTextFragments(from raw: String) -> [InlineFragment] {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var fragments: [InlineFragment] = []
        var buffer = ""
        var pendingCollapsibleSpace = false

        for scalar in normalized.unicodeScalars {
            if isCollapsibleASCIIWhitespace(scalar) {
                if buffer.isEmpty == false {
                    fragments.append(.text(buffer))
                    buffer.removeAll(keepingCapacity: true)
                }
                pendingCollapsibleSpace = true
                continue
            }

            if pendingCollapsibleSpace {
                fragments.append(.collapsibleSpace)
                pendingCollapsibleSpace = false
            }
            buffer.unicodeScalars.append(scalar)
        }

        if buffer.isEmpty == false {
            fragments.append(.text(buffer))
        }
        if pendingCollapsibleSpace {
            fragments.append(.collapsibleSpace)
        }

        return fragments
    }

    private static func wrapInlineFragments(
        _ fragments: [InlineFragment],
        fallback: String? = nil,
        wrapper: (String) -> String
    ) -> [InlineFragment] {
        var leadingIndex = 0
        while leadingIndex < fragments.count, isCollapsibleSpace(fragments[leadingIndex]) {
            leadingIndex += 1
        }

        var trailingIndex = fragments.count
        while trailingIndex > leadingIndex, isCollapsibleSpace(fragments[trailingIndex - 1]) {
            trailingIndex -= 1
        }

        let hasBoundaryCollapsibleSpace = leadingIndex > 0 || trailingIndex < fragments.count
        let coreFragments = Array(fragments[leadingIndex..<trailingIndex])
        let core = assembleInlineFragments(coreFragments)
        let wrappedCore = core.isEmpty ? (fallback ?? "") : core

        guard wrappedCore.isEmpty == false else {
            return hasBoundaryCollapsibleSpace ? [.collapsibleSpace] : []
        }

        var result: [InlineFragment] = []
        if leadingIndex > 0 {
            result.append(.collapsibleSpace)
        }
        result.append(.text(wrapper(wrappedCore)))
        if trailingIndex < fragments.count {
            result.append(.collapsibleSpace)
        }
        return result
    }

    private static func assembleInlineFragments(_ fragments: [InlineFragment]) -> String {
        var result = ""
        var hasVisibleContent = false
        var pendingCollapsibleSpace = false

        for fragment in fragments {
            switch fragment {
            case .collapsibleSpace:
                if hasVisibleContent {
                    pendingCollapsibleSpace = true
                }
            case let .text(text):
                guard text.isEmpty == false else {
                    continue
                }
                if pendingCollapsibleSpace {
                    result += " "
                    pendingCollapsibleSpace = false
                }
                result += text
                hasVisibleContent = true
            }
        }

        return result
    }

    private static func inlineCodeMarkdown(from element: Element) throws -> String {
        let code = try preformattedText(from: element)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let fenceLength = max(longestBacktickRun(in: code) + 1, 1)
        let fence = String(repeating: "`", count: fenceLength)
        let needsPadding = code.first == " " || code.last == " " || code.first == "`" || code.last == "`"
        let payload = needsPadding ? " \(code) " : code
        return "\(fence)\(payload)\(fence)"
    }

    private static func longestBacktickRun(in text: String) -> Int {
        var longest = 0
        var current = 0

        for character in text {
            if character == "`" {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }

        return longest
    }

    private static func isCollapsibleSpace(_ fragment: InlineFragment) -> Bool {
        if case .collapsibleSpace = fragment {
            return true
        }
        return false
    }

    nonisolated private static func isCollapsibleASCIIWhitespace(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x09, 0x0A, 0x0D, 0x20:
            return true
        default:
            return false
        }
    }

    private static func isIgnorableInlineWhitespaceNode(_ node: Node) -> Bool {
        guard let textNode = node as? TextNode else {
            return false
        }

        return textNode.getWholeText().unicodeScalars.allSatisfy(isCollapsibleASCIIWhitespace)
    }

    private static func skipIgnorableInlineWhitespace(in nodes: [Node], index: inout Int) {
        while index < nodes.count, isIgnorableInlineWhitespaceNode(nodes[index]) {
            index += 1
        }
    }

    private static func isInlineWhitespacePolicy(_ whitespacePolicy: WhitespacePolicy) -> Bool {
        switch whitespacePolicy {
        case .preserveSingleSpaceTextNodes:
            return true
        case .discardWhitespaceOnlyTextNodes:
            return false
        }
    }

    private static func shouldRenderMediaInline(_ element: Element, whitespacePolicy: WhitespacePolicy) -> Bool {
        if isInlineWhitespacePolicy(whitespacePolicy) {
            return true
        }

        guard let parent = element.parent() else {
            return false
        }

        let siblings = parent.getChildNodes()
        guard let index = siblings.firstIndex(where: { sibling in
            guard let siblingElement = sibling as? Element else {
                return false
            }
            return siblingElement === element
        }) else {
            return false
        }

        if index > 0, nodeHasInlineVisibleContent(siblings[index - 1]) {
            return true
        }
        if index + 1 < siblings.count, nodeHasInlineVisibleContent(siblings[index + 1]) {
            return true
        }

        return false
    }

    private static func nodeHasInlineVisibleContent(_ node: Node) -> Bool {
        if let textNode = node as? TextNode {
            return inlineTextFragments(from: textNode.getWholeText()).contains { fragment in
                if case let .text(text) = fragment {
                    return text.isEmpty == false
                }
                return false
            }
        }

        guard let element = node as? Element else {
            return false
        }

        if isBlockElementTag(element.tagName().lowercased()) {
            return false
        }

        return true
    }

    private static func isBlockElementTag(_ tag: String) -> Bool {
        switch tag {
        case
            "html", "body", "article", "section", "main", "aside", "header", "footer", "nav",
            "div", "blockquote", "figure", "figcaption", "table", "thead", "tbody", "tfoot", "tr",
            "p", "ul", "ol", "li", "pre", "hr",
            "h1", "h2", "h3", "h4", "h5", "h6":
            return true
        default:
            return false
        }
    }

    private static func renderChildrenMarkdown(
        from element: Element,
        whitespacePolicy: WhitespacePolicy
    ) throws -> String {
        let children = element.getChildNodes()
        return try children.map { try renderMarkdown(from: $0, whitespacePolicy: whitespacePolicy) }.joined()
    }

    private static func inferredWhitespacePolicy(for element: Element) -> WhitespacePolicy {
        switch element.tagName().lowercased() {
        case "body", "html", "div", "article", "section", "main", "aside", "header", "footer", "nav", "blockquote", "figure", "table", "thead", "tbody", "tfoot", "tr":
            return .discardWhitespaceOnlyTextNodes
        default:
            return .preserveSingleSpaceTextNodes
        }
    }

    /// Returns inline image Markdown `![alt](src)` for a bare `img` or `picture` element.
    /// Returns `nil` when no usable `src` is found.
    private static func primaryImageMarkdown(from element: Element) throws -> String? {
        let tag = element.tagName().lowercased()
        if tag == "img" {
            let src = canonicalImageDestination((try? element.attr("src")) ?? "")
            guard !src.isEmpty else { return nil }
            let alt = (try? element.attr("alt")) ?? ""
            return "![\(alt)](\(src))"
        }
        if tag == "picture" {
            guard let img = try element.select("img").first() else { return nil }
            let src = canonicalImageDestination((try? img.attr("src")) ?? "")
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

        let descendantImages = try element.select("img").array()
        guard descendantImages.count == 1,
              let imageMarkdown = try primaryImageMarkdown(from: descendantImages[0]) else {
            return nil
        }

        return "[\(imageMarkdown)](\(href))"
    }

    /// Canonicalizes image destinations before emitting Markdown image syntax.
    /// Keep the rewrite narrow: only `data:*;base64,` payloads fold away ASCII
    /// layout whitespace inside the payload body so the result is a single
    /// parser-stable Markdown destination.
    private static func canonicalImageDestination(_ rawSource: String) -> String {
        let trimmed = rawSource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:"),
              let commaIndex = trimmed.firstIndex(of: ",") else {
            return trimmed
        }

        let metadata = String(trimmed[..<commaIndex])
        guard metadata.range(of: ";base64", options: [.caseInsensitive]) != nil else {
            return trimmed
        }

        let payloadStart = trimmed.index(after: commaIndex)
        let payload = trimmed[payloadStart...]
        let normalizedPayload = String(
            String.UnicodeScalarView(
                payload.unicodeScalars.filter { scalar in
                    switch scalar {
                    case " ", "\t", "\n", "\r", "\u{000C}":
                        return false
                    default:
                        return true
                    }
                }
            )
        )

        return metadata + "," + normalizedPayload
    }
}
