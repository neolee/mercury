import Foundation
import SwiftSoup

enum TranslationSegmentTraversal {
    static func collectTranslatableElements(from root: Element?) throws -> [Element] {
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
            if insideList == false, hasTranslatableText(element) {
                output.append(element)
            }
            return
        }

        if tag == "ul" || tag == "ol" {
            if hasTranslatableText(element) {
                output.append(element)
            }
            return
        }

        let nextInsideList = insideList || tag == "ul" || tag == "ol"
        for child in element.children() {
            try walk(element: child, insideList: nextInsideList, output: &output)
        }
    }

    private static func hasTranslatableText(_ element: Element) -> Bool {
        let text = (try? element.text()) ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}
