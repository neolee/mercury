import CryptoKit
import Foundation
import SwiftSoup

struct ReaderSourceSegment: Sendable, Equatable {
    var sourceSegmentId: String
    var orderIndex: Int
    var sourceHTML: String
    var sourceText: String
    var segmentType: TranslationSegmentType
}

struct ReaderSourceSegmentsSnapshot: Sendable, Equatable {
    var entryId: Int64
    var sourceContentHash: String
    var segmenterVersion: String
    var segments: [ReaderSourceSegment]
}

enum TranslationSegmentExtractor {
    static func extract(entryId: Int64, markdown: String) throws -> ReaderSourceSegmentsSnapshot {
        let renderedHTML = try ReaderHTMLRenderer.render(markdown: markdown, themeId: "light")
        return try extractFromRenderedHTML(entryId: entryId, renderedHTML: renderedHTML)
    }

    static func extractFromRenderedHTML(entryId: Int64, renderedHTML: String) throws -> ReaderSourceSegmentsSnapshot {
        let document = try SwiftSoup.parse(renderedHTML)
        let rootElement = try document.select("article.reader").first() ?? document.body()

        let segments = try collectSegments(from: rootElement)
        let sourceContentHash = hashSourceSegments(segments)

        return ReaderSourceSegmentsSnapshot(
            entryId: entryId,
            sourceContentHash: sourceContentHash,
            segmenterVersion: TranslationSegmentationContract.segmenterVersion,
            segments: segments
        )
    }

    private static func collectSegments(from root: Element?) throws -> [ReaderSourceSegment] {
        guard let root else {
            return []
        }

        var collected: [ReaderSourceSegment] = []
        var nextOrderIndex = 0

        for child in root.children() {
            try walk(element: child, insideList: false, nextOrderIndex: &nextOrderIndex, output: &collected)
        }

        return collected
    }

    private static func walk(
        element: Element,
        insideList: Bool,
        nextOrderIndex: inout Int,
        output: inout [ReaderSourceSegment]
    ) throws {
        let tagName = element.tagName().lowercased()

        if tagName == "p" {
            if insideList == false {
                output.append(makeSegment(element: element, type: .p, orderIndex: nextOrderIndex))
                nextOrderIndex += 1
            }
            return
        }

        if tagName == "ul" {
            output.append(makeSegment(element: element, type: .ul, orderIndex: nextOrderIndex))
            nextOrderIndex += 1
            return
        }

        if tagName == "ol" {
            output.append(makeSegment(element: element, type: .ol, orderIndex: nextOrderIndex))
            nextOrderIndex += 1
            return
        }

        let childInsideList = insideList || tagName == "ul" || tagName == "ol"
        for child in element.children() {
            try walk(
                element: child,
                insideList: childInsideList,
                nextOrderIndex: &nextOrderIndex,
                output: &output
            )
        }
    }

    private static func makeSegment(element: Element, type: TranslationSegmentType, orderIndex: Int) -> ReaderSourceSegment {
        let sourceHTML = (try? element.outerHtml()) ?? ""
        let sourceText = (try? element.text()) ?? ""

        let normalizedHTML = normalizeTextForHash(sourceHTML)
        let normalizedText = normalizeTextForHash(sourceText)
        let idPayload = [
            type.rawValue,
            String(orderIndex),
            normalizedHTML,
            normalizedText
        ].joined(separator: "\n")
        let hash12 = String(sha256Hex(idPayload).prefix(12))

        return ReaderSourceSegment(
            sourceSegmentId: "seg_\(orderIndex)_\(hash12)",
            orderIndex: orderIndex,
            sourceHTML: sourceHTML,
            sourceText: sourceText,
            segmentType: type
        )
    }

    private static func hashSourceSegments(_ segments: [ReaderSourceSegment]) -> String {
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
