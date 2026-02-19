import Foundation
import Testing
@testable import Mercury

@Suite("AI Translation Execution Support")
struct AITranslationExecutionSupportTests {
    @Test("Strategy A is selected under v1 thresholds")
    func strategyASelection() {
        let snapshot = makeSnapshot(segmentCount: 3, sourceText: "Short text.")
        let strategy = AITranslationExecutionSupport.chooseStrategy(snapshot: snapshot)
        #expect(strategy == .wholeArticleSingleRequest)
    }

    @Test("Strategy C is selected when segment count exceeds limit")
    func strategyCBySegmentCount() {
        let snapshot = makeSnapshot(
            segmentCount: AITranslationThresholds.v1.maxSegmentsForStrategyA + 1,
            sourceText: "Segment."
        )
        let strategy = AITranslationExecutionSupport.chooseStrategy(snapshot: snapshot)
        #expect(strategy == .chunkedRequests)
    }

    @Test("Strategy C is selected when estimated token budget exceeds limit")
    func strategyCByTokenBudget() {
        let longText = String(repeating: "a", count: 60_000)
        let snapshot = makeSnapshot(segmentCount: 1, sourceText: longText)
        let strategy = AITranslationExecutionSupport.chooseStrategy(snapshot: snapshot)
        #expect(strategy == .chunkedRequests)
    }

    @Test("Response parser supports array and fenced wrapper JSON")
    func parseArrayAndWrapperJSON() throws {
        let plain = """
        [
          {"sourceSegmentId":"seg_0_a","translatedText":"A"},
          {"sourceSegmentId":"seg_1_b","translatedText":"B"}
        ]
        """
        let parsedPlain = try AITranslationExecutionSupport.parseTranslatedSegments(from: plain)
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
        let parsedFenced = try AITranslationExecutionSupport.parseTranslatedSegments(from: fenced)
        #expect(parsedFenced["seg_0_a"] == "甲")
        #expect(parsedFenced["seg_1_b"] == "乙")
    }

    @Test("Response parser supports id-text map JSON")
    func parseMapJSON() throws {
        let mapped = """
        {"seg_0_a":"Uno","seg_1_b":"Dos"}
        """
        let parsed = try AITranslationExecutionSupport.parseTranslatedSegments(from: mapped)
        #expect(parsed["seg_0_a"] == "Uno")
        #expect(parsed["seg_1_b"] == "Dos")
    }

    @Test("Persisted segments builder enforces complete non-empty coverage")
    func buildPersistedSegmentsValidation() {
        let snapshot = makeSnapshot(segmentCount: 2, sourceText: "x")

        do {
            _ = try AITranslationExecutionSupport.buildPersistedSegments(
                sourceSegments: snapshot.segments,
                translatedBySegmentID: ["seg_0_a": "A"]
            )
            Issue.record("Expected missing segment validation failure, but succeeded.")
        } catch {
            #expect(error.localizedDescription.contains("Missing translated segment"))
        }

        do {
            _ = try AITranslationExecutionSupport.buildPersistedSegments(
                sourceSegments: snapshot.segments,
                translatedBySegmentID: [
                    "seg_0_a": "A",
                    "seg_1_b": "   "
                ]
            )
            Issue.record("Expected empty translated segment validation failure, but succeeded.")
        } catch {
            #expect(error.localizedDescription.contains("Translated segment is empty"))
        }
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
            segmenterVersion: AITranslationSegmentationContract.segmenterVersion,
            segments: segments
        )
    }
}
