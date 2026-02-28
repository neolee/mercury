import Foundation
import Testing
@testable import Mercury

@Suite("Translation Execution Support")
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

    @Test("Prompt builder omits context section when previous source is absent")
    func promptBuilderOmitsContextWhenPreviousMissing() {
        let prompt = TranslationExecutionSupport.promptWithOptionalPreviousContext(
            basePrompt: "Translate this.",
            previousSourceText: nil
        )
        #expect(prompt == "Translate this.")
        #expect(prompt.contains("Context (preceding paragraph, do not translate):") == false)
    }

    @Test("Prompt builder injects previous-source context when present")
    func promptBuilderIncludesContextWhenPreviousPresent() {
        let prompt = TranslationExecutionSupport.promptWithOptionalPreviousContext(
            basePrompt: "Translate this.",
            previousSourceText: "Previous paragraph."
        )
        #expect(prompt.contains("Context (preceding paragraph, do not translate):"))
        #expect(prompt.contains("Previous paragraph."))
        #expect(prompt.contains("Translate this."))
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
