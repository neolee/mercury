import Foundation
import SwiftSoup

struct AITranslationBilingualComposeResult: Sendable {
    let html: String
    let snapshot: ReaderSourceSegmentsSnapshot
}

enum AITranslationBilingualComposer {
    static func compose(
        renderedHTML: String,
        entryId: Int64,
        translatedBySegmentID: [String: String],
        missingStatusText: String?
    ) throws -> AITranslationBilingualComposeResult {
        let document = try SwiftSoup.parse(renderedHTML)
        let root = try document.select("article.reader").first() ?? document.body()
        let snapshot = try AITranslationSegmentExtractor.extractFromRenderedHTML(
            entryId: entryId,
            renderedHTML: renderedHTML
        )
        let orderedSegments = snapshot.segments.sorted { lhs, rhs in lhs.orderIndex < rhs.orderIndex }
        let segmentElements = try collectSegmentElements(from: root)

        if orderedSegments.count == segmentElements.count {
            for (segment, element) in zip(orderedSegments, segmentElements) {
                if let translated = translatedBySegmentID[segment.sourceSegmentId]?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    translated.isEmpty == false {
                    try element.after(translationBlockHTML(text: translated))
                    continue
                }

                if let missingStatusText,
                   missingStatusText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                    try element.after(statusBlockHTML(text: missingStatusText))
                }
            }
        }

        let styleElement = try document.head()?.appendElement("style")
        try styleElement?.text(translationCSS)

        return AITranslationBilingualComposeResult(
            html: try document.outerHtml(),
            snapshot: snapshot
        )
    }

    private static func collectSegmentElements(from root: Element?) throws -> [Element] {
        guard let root else {
            return []
        }

        var output: [Element] = []
        for child in root.children() {
            try walk(element: child, insideList: false, output: &output)
        }
        return output
    }

    private static func walk(
        element: Element,
        insideList: Bool,
        output: inout [Element]
    ) throws {
        let tag = element.tagName().lowercased()
        if tag == "p" {
            if insideList == false {
                output.append(element)
            }
            return
        }

        if tag == "ul" || tag == "ol" {
            output.append(element)
            return
        }

        let nextInsideList = insideList || tag == "ul" || tag == "ol"
        for child in element.children() {
            try walk(element: child, insideList: nextInsideList, output: &output)
        }
    }

    private static func translationBlockHTML(text: String) -> String {
        let escaped = escapeHTML(text)
        return """
        <div class="mercury-translation-block mercury-translation-ready">
          <div class="mercury-translation-label">Translation</div>
          <div class="mercury-translation-text">\(escaped)</div>
        </div>
        """
    }

    private static func statusBlockHTML(text: String) -> String {
        let escaped = escapeHTML(text)
        return """
        <div class="mercury-translation-block mercury-translation-status">
          <div class="mercury-translation-text">\(escaped)</div>
        </div>
        """
    }

    private static func escapeHTML(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

private let translationCSS = """
.mercury-translation-block {
  margin: -0.35em 0 1.1em;
  padding: 0.55em 0.85em;
  border-left: 3px solid rgba(59, 130, 246, 0.55);
  background: rgba(59, 130, 246, 0.08);
  border-radius: 6px;
}
.mercury-translation-label {
  font-size: 0.76em;
  letter-spacing: 0.02em;
  text-transform: uppercase;
  opacity: 0.75;
  margin-bottom: 0.35em;
}
.mercury-translation-status .mercury-translation-text {
  opacity: 0.78;
  font-style: italic;
}
.mercury-translation-text {
  white-space: pre-wrap;
}
"""
