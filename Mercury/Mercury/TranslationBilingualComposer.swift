import Foundation
import SwiftSoup

struct TranslationRetryActionContext: Sendable {
    let entryId: Int64
    let slotKey: String
}

struct TranslationBilingualComposeResult: Sendable {
    let html: String
    let snapshot: ReaderSourceSegmentsSnapshot
}

enum TranslationBilingualComposer {
    static func compose(
        renderedHTML: String,
        entryId: Int64,
        translatedBySegmentID: [String: String],
        missingStatusText: String?,
        headerTranslatedText: String? = nil,
        headerStatusText: String? = nil,
        pendingSegmentIDs: Set<String> = [],
        failedSegmentIDs: Set<String> = [],
        pendingStatusText: String? = nil,
        failedStatusText: String? = nil,
        headerFailedSegmentID: String? = nil,
        retryActionContext: TranslationRetryActionContext? = nil
    ) throws -> TranslationBilingualComposeResult {
        let document = try SwiftSoup.parse(renderedHTML)
        document.outputSettings().prettyPrint(pretty: false)
        let root = try document.select("article.reader").first() ?? document.body()
        let snapshot = try TranslationSegmentExtractor.extractFromRenderedHTML(
            entryId: entryId,
            renderedHTML: renderedHTML
        )
        var insertedVisibleBlockCount = 0
        let orderedSegments = snapshot.segments.sorted { lhs, rhs in lhs.orderIndex < rhs.orderIndex }
        let segmentElements = try collectSegmentElements(from: root)
        var suppressedElementIDs = Set<ObjectIdentifier>()
        var suppressedBylineSegmentID: String?

        if let root {
            if (headerTranslatedText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ||
                headerStatusText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false),
               let titleElement = try root.select("> h1").first(),
               let bylineElement = try firstBylineElement(after: titleElement) {
                suppressedElementIDs.insert(ObjectIdentifier(bylineElement))
                if orderedSegments.count == segmentElements.count {
                    for (segment, element) in zip(orderedSegments, segmentElements) {
                        if ObjectIdentifier(element) == ObjectIdentifier(bylineElement) {
                            suppressedBylineSegmentID = segment.sourceSegmentId
                            break
                        }
                    }
                }
            }

            let mergedHeaderTranslatedText: String? = {
                guard let headerTranslatedText,
                      headerTranslatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                    return nil
                }
                guard let suppressedBylineSegmentID,
                      let bylineTranslated = translatedBySegmentID[suppressedBylineSegmentID]?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                      bylineTranslated.isEmpty == false else {
                    return headerTranslatedText
                }
                let normalizedHeader = normalizeTranslationDisplayText(headerTranslatedText)
                if normalizedHeader.contains("\n") {
                    return normalizedHeader
                }
                return normalizedHeader + "\n" + bylineTranslated
            }()

            if let mergedHeaderTranslatedText,
               mergedHeaderTranslatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                try insertHeaderBlock(
                    root: root,
                    blockHTML: translationBlockHTML(text: mergedHeaderTranslatedText)
                )
                insertedVisibleBlockCount += 1
            } else if let headerStatusText,
                      headerStatusText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                let retryURL: String? = {
                    guard let headerFailedSegmentID,
                          let retryActionContext else {
                        return nil
                    }
                    return makeRetrySegmentActionURL(
                        context: retryActionContext,
                        segmentID: headerFailedSegmentID
                    )
                }()
                try insertHeaderBlock(
                    root: root,
                    blockHTML: statusBlockHTML(text: headerStatusText, retryURL: retryURL)
                )
                insertedVisibleBlockCount += 1
            }
        }

        for (segment, element) in zip(orderedSegments, segmentElements) {
            if suppressedElementIDs.contains(ObjectIdentifier(element)) {
                continue
            }
            if let translated = translatedBySegmentID[segment.sourceSegmentId]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                translated.isEmpty == false {
                try element.after(translationBlockHTML(text: translated))
                insertedVisibleBlockCount += 1
                continue
            }

            if failedSegmentIDs.contains(segment.sourceSegmentId) {
                let statusText = failedStatusText ?? missingStatusText
                if let statusText,
                   statusText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                    let retryURL: String? = {
                        guard let retryActionContext else {
                            return nil
                        }
                        return makeRetrySegmentActionURL(
                            context: retryActionContext,
                            segmentID: segment.sourceSegmentId
                        )
                    }()
                    try element.after(statusBlockHTML(text: statusText, retryURL: retryURL))
                    insertedVisibleBlockCount += 1
                }
                continue
            }

            if pendingSegmentIDs.contains(segment.sourceSegmentId) {
                let statusText = pendingStatusText ?? missingStatusText
                if let statusText,
                   statusText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                    try element.after(statusBlockHTML(text: statusText))
                    insertedVisibleBlockCount += 1
                }
                continue
            }

            if let missingStatusText,
               missingStatusText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                try element.after(statusBlockHTML(text: missingStatusText))
                insertedVisibleBlockCount += 1
            }
        }

        if insertedVisibleBlockCount == 0,
           let root,
           let fallback = fallbackBlockHTML(
               translatedBySegmentID: translatedBySegmentID,
               missingStatusText: missingStatusText,
               headerTranslatedText: headerTranslatedText,
               headerStatusText: headerStatusText
           ) {
            try insertHeaderBlock(root: root, blockHTML: fallback)
        }

        let styleElement = try document.head()?.appendElement("style")
        try styleElement?.text(translationCSS)

        return TranslationBilingualComposeResult(
            html: try document.outerHtml(),
            snapshot: snapshot
        )
    }

    private static func collectSegmentElements(from root: Element?) throws -> [Element] {
        try TranslationSegmentTraversal.collectTranslatableElements(from: root)
    }

    private static func translationBlockHTML(text: String) -> String {
        let escaped = escapeHTML(normalizeTranslationDisplayText(text))
        return """
        <div class="mercury-translation-block mercury-translation-ready">
          <div class="mercury-translation-icon" aria-hidden="true">
            <svg viewBox="0 0 20 20" fill="none" xmlns="http://www.w3.org/2000/svg">
              <path d="M10 18.25C14.5563 18.25 18.25 14.5563 18.25 10C18.25 5.44365 14.5563 1.75 10 1.75C5.44365 1.75 1.75 5.44365 1.75 10C1.75 14.5563 5.44365 18.25 10 18.25Z" stroke="currentColor" stroke-width="1.5"/>
              <path d="M1.75 10H18.25" stroke="currentColor" stroke-width="1.5"/>
              <path d="M10 1.75C11.933 3.85486 13.0325 6.59172 13.1 9.45C13.0325 12.3083 11.933 15.0451 10 17.15C8.06701 15.0451 6.96754 12.3083 6.9 9.45C6.96754 6.59172 8.06701 3.85486 10 1.75Z" stroke="currentColor" stroke-width="1.5"/>
            </svg>
          </div>
          <div class="mercury-translation-text">\(escaped)</div>
        </div>
        """
    }

    private static func statusBlockHTML(text: String, retryURL: String? = nil) -> String {
        let escaped = escapeHTML(normalizeTranslationDisplayText(text))
        let retryHTML: String
        if let retryURL {
            retryHTML = """
            <a class="mercury-translation-retry" href="\(escapeHTML(retryURL))">Retry</a>
            """
        } else {
            retryHTML = ""
        }
        return """
        <div class="mercury-translation-block mercury-translation-status">
          <div class="mercury-translation-icon" aria-hidden="true">
            <svg viewBox="0 0 20 20" fill="none" xmlns="http://www.w3.org/2000/svg">
              <path d="M10 18.25C14.5563 18.25 18.25 14.5563 18.25 10C18.25 5.44365 14.5563 1.75 10 1.75C5.44365 1.75 1.75 5.44365 1.75 10C1.75 14.5563 5.44365 18.25 10 18.25Z" stroke="currentColor" stroke-width="1.5"/>
              <path d="M1.75 10H18.25" stroke="currentColor" stroke-width="1.5"/>
              <path d="M10 1.75C11.933 3.85486 13.0325 6.59172 13.1 9.45C13.0325 12.3083 11.933 15.0451 10 17.15C8.06701 15.0451 6.96754 12.3083 6.9 9.45C6.96754 6.59172 8.06701 3.85486 10 1.75Z" stroke="currentColor" stroke-width="1.5"/>
            </svg>
          </div>
          <div class="mercury-translation-text">\(escaped)</div>
          \(retryHTML)
        </div>
        """
    }

    private static func makeRetrySegmentActionURL(
        context: TranslationRetryActionContext,
        segmentID: String
    ) -> String? {
        guard let encodedSlot = context.slotKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let encodedSegmentID = segmentID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }
        return "mercury-action://translation/retry-segment?entryId=\(context.entryId)&slot=\(encodedSlot)&segmentId=\(encodedSegmentID)"
    }

    private static func normalizeTranslationDisplayText(_ raw: String) -> String {
        var text = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        while let scalar = text.unicodeScalars.last {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) ||
                scalar == "\u{2028}" ||
                scalar == "\u{2029}" ||
                scalar == "\u{200B}" ||
                scalar == "\u{FEFF}" {
                text.unicodeScalars.removeLast()
                continue
            }
            break
        }

        return text
    }

    private static func escapeHTML(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func insertHeaderBlock(root: Element, blockHTML: String) throws {
        if let titleElement = try root.select("> h1").first() {
            if let bylineElement = try firstBylineElement(after: titleElement) {
                try bylineElement.after(blockHTML)
                return
            }
            try titleElement.after(blockHTML)
            return
        }
        try root.prepend(blockHTML)
    }

    private static func fallbackBlockHTML(
        translatedBySegmentID: [String: String],
        missingStatusText: String?,
        headerTranslatedText: String?,
        headerStatusText: String?
    ) -> String? {
        if let headerTranslatedText,
           headerTranslatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return translationBlockHTML(text: headerTranslatedText)
        }

        if let firstTranslated = translatedBySegmentID
            .sorted(by: { lhs, rhs in lhs.key < rhs.key })
            .map({ $0.value })
            .first(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }) {
            return translationBlockHTML(text: firstTranslated)
        }

        if let headerStatusText,
           headerStatusText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return statusBlockHTML(text: headerStatusText)
        }

        if let missingStatusText,
           missingStatusText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return statusBlockHTML(text: missingStatusText)
        }

        return nil
    }

    private static func firstBylineElement(after titleElement: Element) throws -> Element? {
        var current = try titleElement.nextElementSibling()
        while let element = current {
            let tag = element.tagName().lowercased()
            if tag == "p" {
                let text = try element.text().trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty == false {
                    return element
                }
            }
            if tag == "h1" || tag == "h2" || tag == "h3" || tag == "h4" || tag == "h5" || tag == "h6" {
                break
            }
            current = try element.nextElementSibling()
        }
        return nil
    }
}

private let translationCSS = """
.mercury-translation-block {
  margin: 0;
  padding: 0.6em 0.4em 0.6em 0.6em;
  border-left: 3px solid rgba(59, 130, 246, 0.55);
  background: rgba(59, 130, 246, 0.08);
  border-radius: 4px;
  display: flex;
  align-items: flex-start;
  gap: 0.1em;
}
p + .mercury-translation-block,
ul + .mercury-translation-block,
ol + .mercury-translation-block {
  margin-top: 1em;
}
.mercury-translation-block + p,
.mercury-translation-block + ul,
.mercury-translation-block + ol {
  margin-top: 1em;
}
.mercury-translation-icon {
  width: 0.8em;
  height: 0.8em;
  opacity: 0.7;
  margin-top: 0.2em;
  margin-right: 0.4em;
  flex: 0 0 auto;
}
.mercury-translation-icon svg {
  width: 100%;
  height: 100%;
  display: block;
}
.mercury-translation-status .mercury-translation-text {
  opacity: 0.7;
  font-style: italic;
}
.mercury-translation-text {
  white-space: pre-wrap;
  line-height: 1.4;
  flex: 1 1 auto;
}
.mercury-translation-retry {
  color: inherit;
  font-size: 0.85em;
  text-decoration: underline;
  margin-left: 0.6em;
  opacity: 0.9;
  flex: 0 0 auto;
}
"""
