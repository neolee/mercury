import Foundation
import Testing
@testable import Mercury

@Suite("Translation Execution Support")
@MainActor
struct TranslationExecutionSupportTests {
    @Test("Per-segment retry route policy uses primary only when no fallback exists")
    func perSegmentRetryRouteIndicesPrimaryOnly() {
        #expect(TranslationExecutionSupport.perSegmentAttemptRouteIndices(candidateCount: 0).isEmpty)
        #expect(TranslationExecutionSupport.perSegmentAttemptRouteIndices(candidateCount: 1) == [0])
    }

    @Test("Per-segment retry route policy uses primary then fallback")
    func perSegmentRetryRouteIndicesPrimaryThenFallback() {
        #expect(TranslationExecutionSupport.perSegmentAttemptRouteIndices(candidateCount: 2) == [0, 1])
        #expect(TranslationExecutionSupport.perSegmentAttemptRouteIndices(candidateCount: 5) == [0, 1])
    }

    @Test("Concurrency degree normalization clamps to supported range")
    func normalizeConcurrencyDegree() {
        #expect(
            TranslationExecutionSupport.normalizeConcurrencyDegree(0)
                == TranslationSettingsKey.concurrencyRange.lowerBound
        )
        #expect(
            TranslationExecutionSupport.normalizeConcurrencyDegree(-1)
                == TranslationSettingsKey.concurrencyRange.lowerBound
        )
        #expect(TranslationExecutionSupport.normalizeConcurrencyDegree(2) == 2)
        #expect(
            TranslationExecutionSupport.normalizeConcurrencyDegree(99)
                == TranslationSettingsKey.concurrencyRange.upperBound
        )
    }

    @Test("Model output normalization rejects empty translations")
    func normalizedModelOutputRejectsEmpty() {
        #expect(TranslationExecutionSupport.normalizedModelTranslationOutput(" \n\t ") == nil)
        #expect(TranslationExecutionSupport.normalizedModelTranslationOutput(" translated ") == "translated")
    }

    @Test("Persisted segments builder allows partial non-empty coverage")
    func buildPersistedSegmentsValidation() throws {
        let snapshot = makeSnapshot(segmentCount: 2, sourceText: "x")
        let persisted = try TranslationExecutionSupport.buildPersistedSegments(
            sourceSegments: snapshot.segments,
            translatedBySegmentID: ["seg_0_a": "A"]
        )
        #expect(persisted.count == 1)
        #expect(persisted.first?.sourceSegmentId == "seg_0_a")

        let filtered = try TranslationExecutionSupport.buildPersistedSegments(
            sourceSegments: snapshot.segments,
            translatedBySegmentID: [
                "seg_0_a": "A",
                "seg_1_b": "   "
            ]
        )
        #expect(filtered.count == 1)
        #expect(filtered.first?.sourceSegmentId == "seg_0_a")
    }

    @Test("Translation prompt builder omits previous-source parameter when absent")
    func promptBuilderOmitsContextWhenPreviousMissing() throws {
        let template = try loadInlineTranslationTemplate()
        let messages = try buildTranslationPromptMessages(
            template: template,
            targetLanguageDisplayName: "English (en)",
            sourceText: "Translate this.",
            previousSourceText: nil
        )

        #expect(messages.userPrompt.contains("Context:") == false)
        #expect(messages.userPrompt.trimmingCharacters(in: .whitespacesAndNewlines) == "Translate this.")
    }

    @Test("Translation prompt builder passes previous-source parameter into template")
    func promptBuilderIncludesContextWhenPreviousPresent() throws {
        let template = try loadInlineTranslationTemplate()
        let messages = try buildTranslationPromptMessages(
            template: template,
            targetLanguageDisplayName: "English (en)",
            sourceText: "Translate this.",
            previousSourceText: "Previous paragraph."
        )

        #expect(messages.userPrompt.contains("Context:"))
        #expect(messages.userPrompt.contains("Previous paragraph."))
        #expect(messages.userPrompt.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("Translate this."))
    }

    private func loadInlineTranslationTemplate() throws -> AgentPromptTemplate {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mercury-translation-support-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let content = """
        id: translation.inline
        version: v1
        taskType: translation
        requiredPlaceholders:
          - sourceText
        optionalPlaceholders:
          - previousSourceText
        template: |
          {{#previousSourceText}}Context:
          {{previousSourceText}}

          {{/previousSourceText}}{{sourceText}}
        """
        let fileURL = directory.appendingPathComponent("translation.inline.yaml")
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        let store = AgentPromptTemplateStore()
        try store.loadTemplates(from: directory)
        return try store.template(id: "translation.inline")
    }

    private func makeSnapshot(segmentCount: Int, sourceText: String) -> TranslationSourceSegmentsSnapshot {
        var segments: [TranslationSourceSegment] = []
        segments.reserveCapacity(segmentCount)
        for index in 0..<segmentCount {
            let id: String
            if index == 0 {
                id = "seg_0_a"
            } else if index == 1 {
                id = "seg_1_b"
            } else {
                id = "seg_\(index)_\(index)"
            }
            segments.append(
                TranslationSourceSegment(
                    sourceSegmentId: id,
                    orderIndex: index,
                    sourceHTML: "<p>\(sourceText)</p>",
                    sourceText: sourceText,
                    segmentType: .p
                )
            )
        }

        return TranslationSourceSegmentsSnapshot(
            entryId: 1,
            sourceContentHash: "hash-\(segmentCount)-\(sourceText.count)",
            segmenterVersion: TranslationSegmentationContract.segmenterVersion,
            segments: segments
        )
    }
}
