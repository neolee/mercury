import Foundation
import SwiftSoup

enum TranslationHeaderTextBuilder {
    static func buildHeaderSourceText(
        entryTitle: String?,
        entryAuthor: String?,
        renderedHTML: String?
    ) -> String? {
        let title = normalize(entryTitle)
        let authorFromEntry = normalize(entryAuthor)
        let author = authorFromEntry ?? extractBylineText(from: renderedHTML)

        if let title, let author {
            return "\(title)\n\(author)"
        }
        if let title {
            return title
        }
        if let author {
            return author
        }
        return nil
    }

    private static func normalize(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.isEmpty == false else {
            return nil
        }
        return trimmed
    }

    private static func extractBylineText(from renderedHTML: String?) -> String? {
        guard let renderedHTML,
              renderedHTML.isEmpty == false else {
            return nil
        }
        guard let document = try? SwiftSoup.parse(renderedHTML) else {
            return nil
        }
        document.outputSettings().prettyPrint(pretty: false)
        guard let root = (try? document.select("article.reader").first()) ?? document.body(),
              let titleElement = try? root.select("> h1").first() else {
            return nil
        }

        var current = try? titleElement.nextElementSibling()
        var siblingOffset = 0
        while let element = current {
            let tag = element.tagName().lowercased()
            if tag == "h1" || tag == "h2" || tag == "h3" || tag == "h4" || tag == "h5" || tag == "h6" {
                break
            }

            let className = ((try? element.className()) ?? "").lowercased()
            let text = normalize(try? element.text())
            if let text {
                if className.contains("byline") || className.contains("author") {
                    return text
                }
                if tag == "p" {
                    let hasBylineLikeInlineMarker = ((try? element.select("em,small,a,span,strong").first()) ?? nil) != nil
                    if hasBylineLikeInlineMarker, text.count <= 120 {
                        return text
                    }
                    if siblingOffset == 0, text.count <= 80 {
                        return text
                    }
                }
                if (tag == "div" || tag == "span" || tag == "em"), siblingOffset == 0, text.count <= 120 {
                    return text
                }
            }
            siblingOffset += 1
            current = try? element.nextElementSibling()
        }
        return nil
    }
}
