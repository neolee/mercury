import Foundation
import Testing
@testable import Mercury

@Suite("Translation Execution Support")
struct TranslationExecutionSupportTests {
    @Test("Strategy A is selected under v1 thresholds")
    func strategyASelection() {
        let snapshot = makeSnapshot(segmentCount: 3, sourceText: "Short text.")
        let strategy = TranslationExecutionSupport.chooseStrategy(snapshot: snapshot)
        #expect(strategy == .wholeArticleSingleRequest)
    }

    @Test("Strategy C is selected when segment count exceeds limit")
    func strategyCBySegmentCount() {
        let snapshot = makeSnapshot(
            segmentCount: TranslationThresholds.v1.maxSegmentsForStrategyA + 1,
            sourceText: "Segment."
        )
        let strategy = TranslationExecutionSupport.chooseStrategy(snapshot: snapshot)
        #expect(strategy == .chunkedRequests)
    }

    @Test("Strategy C is selected when estimated token budget exceeds limit")
    func strategyCByTokenBudget() {
        let longText = String(repeating: "a", count: 60_000)
        let snapshot = makeSnapshot(segmentCount: 1, sourceText: longText)
        let strategy = TranslationExecutionSupport.chooseStrategy(snapshot: snapshot)
        #expect(strategy == .chunkedRequests)
    }

    @Test("Token-aware chunking merges short segments into fewer requests")
    func tokenAwareChunkingMergesShortSegments() {
        let segments = makeSnapshot(segmentCount: 100, sourceText: "Short.").segments
        let fixedChunks = TranslationExecutionSupport.chunks(from: segments, chunkSize: 24)
        let tokenAware = TranslationExecutionSupport.tokenAwareChunks(
            from: segments,
            minimumChunkSize: 24,
            targetEstimatedTokensPerChunk: 9_000
        )
        #expect(tokenAware.count < fixedChunks.count)
        #expect(tokenAware.count == 1)
    }

    @Test("Token-aware chunking still splits very large segments")
    func tokenAwareChunkingSplitsLongSegments() {
        let longText = String(repeating: "a", count: 40_000)
        let segments = makeSnapshot(segmentCount: 5, sourceText: longText).segments
        let tokenAware = TranslationExecutionSupport.tokenAwareChunks(
            from: segments,
            minimumChunkSize: 2,
            targetEstimatedTokensPerChunk: 9_000
        )
        #expect(tokenAware.count >= 2)
    }

    @Test("Response parser supports array and fenced wrapper JSON")
    func parseArrayAndWrapperJSON() throws {
        let plain = """
        [
          {"sourceSegmentId":"seg_0_a","translatedText":"A"},
          {"sourceSegmentId":"seg_1_b","translatedText":"B"}
        ]
        """
        let parsedPlain = try TranslationExecutionSupport.parseTranslatedSegments(from: plain)
        #expect(parsedPlain["seg_0_a"] == "A")
        #expect(parsedPlain["seg_1_b"] == "B")

        let fenced = """
        Here is output:
        ```json
        {
          "segments": [
            {"id":"seg_0_a","text":"甲"},
            {"id":"seg_1_b","text":"乙"}
          ]
        }
        ```
        """
        let parsedFenced = try TranslationExecutionSupport.parseTranslatedSegments(from: fenced)
        #expect(parsedFenced["seg_0_a"] == "甲")
        #expect(parsedFenced["seg_1_b"] == "乙")
    }

    @Test("Response parser supports id-text map JSON")
    func parseMapJSON() throws {
        let mapped = """
        {"seg_0_a":"Uno","seg_1_b":"Dos"}
        """
        let parsed = try TranslationExecutionSupport.parseTranslatedSegments(from: mapped)
        #expect(parsed["seg_0_a"] == "Uno")
        #expect(parsed["seg_1_b"] == "Dos")
    }

    @Test("Response parser normalizes malformed JSON errors to invalidModelResponse")
    func parseMalformedJSONThrowsInvalidModelResponse() {
        let malformed = """
        {"seg_0_a":
        """
        do {
            _ = try TranslationExecutionSupport.parseTranslatedSegments(from: malformed)
            Issue.record("Expected invalidModelResponse, but parser succeeded.")
        } catch let error as TranslationExecutionError {
            switch error {
            case .invalidModelResponse:
                break
            default:
                Issue.record("Expected invalidModelResponse, got \(error).")
            }
        } catch {
            Issue.record("Expected TranslationExecutionError.invalidModelResponse, got \(error).")
        }
    }

    @Test("Guarded recovery parses loose line-based output")
    func parseLooseLineBasedRecovery() throws {
        let loose = """
        seg_0_a: 甲
        seg_1_b => 乙
        """
        let parsed = try TranslationExecutionSupport.parseTranslatedSegmentsRecovering(
            from: loose,
            expectedSegmentIDs: Set(["seg_0_a", "seg_1_b"])
        )
        #expect(parsed["seg_0_a"] == "甲")
        #expect(parsed["seg_1_b"] == "乙")
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

    private func makeSnapshot(segmentCount: Int, sourceText: String) -> ReaderSourceSegmentsSnapshot {
        var segments: [ReaderSourceSegment] = []
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
                ReaderSourceSegment(
                    sourceSegmentId: id,
                    orderIndex: index,
                    sourceHTML: "<p>\(sourceText)</p>",
                    sourceText: sourceText,
                    segmentType: .p
                )
            )
        }

        return ReaderSourceSegmentsSnapshot(
            entryId: 1,
            sourceContentHash: "hash-\(segmentCount)-\(sourceText.count)",
            segmenterVersion: TranslationSegmentationContract.segmenterVersion,
            segments: segments
        )
    }
}
