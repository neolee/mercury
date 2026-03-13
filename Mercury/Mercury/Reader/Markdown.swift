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
            return textNode.text().replacingOccurrences(of: "\n", with: " ")
        }

        guard let element = node as? Element else {
            return ""
        }

        let tag = element.tagName().lowercased()
        switch tag {
        case "h1", "h2", "h3", "h4", "h5", "h6":
            let level = Int(tag.dropFirst()) ?? 1
            let text = try element.text().trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(String(repeating: "#", count: level)) \(text)\n\n"
        case "p":
            let text = try renderChildrenMarkdown(from: element)
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\(text)\n\n"
        case "br":
            return "\n"
        case "ul":
            return try element.children().map { child in
                guard child.tagName().lowercased() == "li" else { return "" }
                let text = try renderChildrenMarkdown(from: child).trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? "" : "- \(text)"
            }.joined(separator: "\n") + "\n\n"
        case "ol":
            var index = 1
            let lines = try element.children().compactMap { child -> String? in
                guard child.tagName().lowercased() == "li" else { return nil }
                let text = try renderChildrenMarkdown(from: child).trimmingCharacters(in: .whitespacesAndNewlines)
                defer { index += 1 }
                return text.isEmpty ? nil : "\(index). \(text)"
            }
            return lines.joined(separator: "\n") + "\n\n"
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
        default:
            return try renderChildrenMarkdown(from: element)
        }
    }

    private static func renderChildrenMarkdown(from element: Element) throws -> String {
        let children = element.getChildNodes()
        let rendered = try children.map { try renderMarkdown(from: $0) }.joined()
        return rendered.replacingOccurrences(of: "  ", with: " ")
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
}
