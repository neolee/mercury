import CryptoKit
import Foundation
import SwiftSoup

enum TranslationSegmentExtractor {
    static func extract(entryId: Int64, markdown: String) throws -> TranslationSourceSegmentsSnapshot {
        let renderedHTML = try ReaderHTMLRenderer.render(markdown: markdown, themeId: "light")
        return try extractFromRenderedHTML(entryId: entryId, renderedHTML: renderedHTML)
    }

    static func extractFromRenderedHTML(entryId: Int64, renderedHTML: String) throws -> TranslationSourceSegmentsSnapshot {
        let document = try SwiftSoup.parse(renderedHTML)
        let rootElement = try document.select("article.reader").first() ?? document.body()

        let segments = try collectSegments(from: rootElement)
        let sourceContentHash = hashSourceSegments(segments)

        return TranslationSourceSegmentsSnapshot(
            entryId: entryId,
            sourceContentHash: sourceContentHash,
            segmenterVersion: TranslationSegmentationContract.segmenterVersion,
            segments: segments
        )
    }

    private static func collectSegments(from root: Element?) throws -> [TranslationSourceSegment] {
        let elements = try TranslationSegmentTraversal.collectTranslatableElements(from: root)
        var collected: [TranslationSourceSegment] = []
        collected.reserveCapacity(elements.count)
        var nextOrderIndex = 0

        for element in elements {
            let type: TranslationSegmentType
            switch element.tagName().lowercased() {
            case "p":
                type = .p
            case "ul":
                type = .ul
            case "ol":
                type = .ol
            default:
                continue
            }
            if let segment = makeSegment(element: element, type: type, orderIndex: nextOrderIndex) {
                collected.append(segment)
                nextOrderIndex += 1
            }
        }
        return collected
    }

    private static func makeSegment(
        element: Element,
        type: TranslationSegmentType,
        orderIndex: Int
    ) -> TranslationSourceSegment? {
        let sourceHTML = (try? element.outerHtml()) ?? ""
        let sourceText = (try? element.text()) ?? ""

        let normalizedHTML = normalizeTextForHash(sourceHTML)
        let normalizedText = normalizeTextForHash(sourceText)
        guard normalizedText.isEmpty == false else {
            return nil
        }
        let idPayload = [
            type.rawValue,
            String(orderIndex),
            normalizedHTML,
            normalizedText
        ].joined(separator: "\n")
        let hash12 = String(sha256Hex(idPayload).prefix(12))

        return TranslationSourceSegment(
            sourceSegmentId: "seg_\(orderIndex)_\(hash12)",
            orderIndex: orderIndex,
            sourceHTML: sourceHTML,
            sourceText: sourceText,
            segmentType: type
        )
    }

    private static func hashSourceSegments(_ segments: [TranslationSourceSegment]) -> String {
        let payload = segments
            .sorted { lhs, rhs in lhs.orderIndex < rhs.orderIndex }
            .map { segment in
                [
                    segment.segmentType.rawValue,
                    String(segment.orderIndex),
                    normalizeTextForHash(segment.sourceHTML),
                    normalizeTextForHash(segment.sourceText)
                ].joined(separator: "\n")
            }
            .joined(separator: "\n---\n")

        return sha256Hex(payload)
    }

    private static func normalizeTextForHash(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sha256Hex(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
