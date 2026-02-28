import SwiftUI

extension ReaderTranslationView {
    @MainActor
    func applyProjection(
        entryId: Int64,
        slotKey: TranslationSlotKey,
        sourceReaderHTML: String,
        sourceSnapshot: TranslationSourceSegmentsSnapshot,
        translatedBySegmentID: [String: String],
        pendingSegmentIDs: Set<String>,
        failedSegmentIDs: Set<String>,
        pendingStatusText: String?,
        failedStatusText: String?,
        defaultMissingStatusText: String? = nil
    ) {
        let headerTranslatedText = translatedBySegmentID[Self.translationHeaderSegmentID]
        let hasHeaderSegment = sourceSnapshot.segments.contains { $0.sourceSegmentId == Self.translationHeaderSegmentID }
        let headerStatusText: String? = {
            guard hasHeaderSegment else {
                return nil
            }
            if let headerTranslatedText,
               headerTranslatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                return nil
            }
            if pendingSegmentIDs.contains(Self.translationHeaderSegmentID) {
                return pendingStatusText
            }
            if failedSegmentIDs.contains(Self.translationHeaderSegmentID) {
                return failedStatusText
            }
            return defaultMissingStatusText
        }()

        let bodyTranslatedBySegmentID = translatedBySegmentID.filter { key, _ in
            key != Self.translationHeaderSegmentID
        }
        let bodyPendingSegmentIDs = Set(
            pendingSegmentIDs.filter { $0 != Self.translationHeaderSegmentID }
        )
        let bodyFailedSegmentIDs = Set(
            failedSegmentIDs.filter { $0 != Self.translationHeaderSegmentID }
        )

        do {
            let composed = try TranslationBilingualComposer.compose(
                renderedHTML: sourceReaderHTML,
                entryId: entryId,
                translatedBySegmentID: bodyTranslatedBySegmentID,
                missingStatusText: defaultMissingStatusText,
                headerTranslatedText: headerTranslatedText,
                headerStatusText: headerStatusText,
                pendingSegmentIDs: bodyPendingSegmentIDs,
                failedSegmentIDs: bodyFailedSegmentIDs,
                pendingStatusText: pendingStatusText,
                failedStatusText: failedStatusText,
                headerFailedSegmentID: failedSegmentIDs.contains(Self.translationHeaderSegmentID)
                    ? Self.translationHeaderSegmentID
                    : nil,
                retryActionContext: TranslationRetryActionContext(
                    entryId: slotKey.entryId,
                    slotKey: slotKey.targetLanguage
                )
            )
            let visibleHTML = ensureVisibleTranslationBlockIfNeeded(
                composedHTML: composed.html,
                translatedBySegmentID: bodyTranslatedBySegmentID,
                headerTranslatedText: headerTranslatedText,
                missingStatusText: pendingStatusText ?? failedStatusText ?? defaultMissingStatusText
            )
            setReaderHTML(visibleHTML)
        } catch {
            appModel.reportDebugIssue(
                title: "Translation Render Failed",
                detail: "entryId=\(entryId)\nslot=\(slotKey.targetLanguage)\nreason=\(error.localizedDescription)",
                category: .task
            )
        }
    }

    func ensureVisibleTranslationBlockIfNeeded(
        composedHTML: String,
        translatedBySegmentID: [String: String],
        headerTranslatedText: String?,
        missingStatusText: String?
    ) -> String {
        let marker = "mercury-translation-block"
        if composedHTML.contains(marker) {
            return composedHTML
        }

        let fallbackText = preferredVisibleTranslationText(
            translatedBySegmentID: translatedBySegmentID,
            headerTranslatedText: headerTranslatedText,
            missingStatusText: missingStatusText
        )
        guard let fallbackText,
              fallbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return composedHTML
        }

        let escaped = escapeHTMLForTranslationFallback(fallbackText)
        let blockHTML = """
        <div class=\"mercury-translation-block mercury-translation-ready\"><div class=\"mercury-translation-text\">\(escaped)</div></div>
        """
        if composedHTML.contains("<article class=\"reader\">") {
            return composedHTML.replacingOccurrences(
                of: "<article class=\"reader\">",
                with: "<article class=\"reader\">\n\(blockHTML)",
                options: [],
                range: composedHTML.range(of: "<article class=\"reader\">")
            )
        }
        if composedHTML.contains("<body>") {
            return composedHTML.replacingOccurrences(
                of: "<body>",
                with: "<body>\n\(blockHTML)",
                options: [],
                range: composedHTML.range(of: "<body>")
            )
        }
        return blockHTML + composedHTML
    }

    func preferredVisibleTranslationText(
        translatedBySegmentID: [String: String],
        headerTranslatedText: String?,
        missingStatusText: String?
    ) -> String? {
        if let headerTranslatedText,
           headerTranslatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return headerTranslatedText
        }

        if let translated = translatedBySegmentID
            .sorted(by: { lhs, rhs in lhs.key < rhs.key })
            .map({ $0.value })
            .first(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }) {
            return translated
        }

        if let missingStatusText,
           missingStatusText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return missingStatusText
        }
        return nil
    }

    func escapeHTMLForTranslationFallback(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
