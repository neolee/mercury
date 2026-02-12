//
//  Markdown.swift
//  Mercury
//

import Foundation
import Readability
import SwiftSoup

enum MarkdownConverter {
    static func markdownFromReadability(_ result: ReadabilityResult) throws -> String {
        var parts: [String] = []

        let title = result.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty == false {
            parts.append("# \(title)")
        }

        if let byline = result.byline?.trimmingCharacters(in: .whitespacesAndNewlines), byline.isEmpty == false {
            parts.append("_\(byline)_")
        }

        let bodyMarkdown = try markdownFromHTML(result.content)
        if bodyMarkdown.isEmpty == false {
            parts.append(bodyMarkdown)
        } else {
            let fallback = result.textContent
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
            let text = try element.text().trimmingCharacters(in: .whitespacesAndNewlines)
            let href = (try? element.attr("href")) ?? ""
            guard href.isEmpty == false else { return text }
            return "[\(text.isEmpty ? href : text)](\(href))"
        default:
            return try renderChildrenMarkdown(from: element)
        }
    }

    private static func renderChildrenMarkdown(from element: Element) throws -> String {
        let children = element.getChildNodes()
        let rendered = try children.map { try renderMarkdown(from: $0) }.joined()
        return rendered.replacingOccurrences(of: "  ", with: " ")
    }
}
