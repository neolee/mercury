import XCTest
@testable import Mercury

final class TranslationHashBaselineTests: XCTestCase {
    func test_plainMarkdownRendererHashStability() throws {
        let markdown = """
        # Baseline Title

        Lead paragraph with a [link](https://example.com).

        - Apple
        - Banana

        Another paragraph with `inline code`.

        ![Hero](https://example.com/hero.jpg)
        """

        let snapshot = try TranslationSegmentExtractor.extract(entryId: 9001, markdown: markdown)
        XCTAssertEqual(
            snapshot.sourceContentHash,
            "68770b0daaed59390801402c6842d2ed265984333cd7e4ccb74672761c504949",
            "Update this baseline only when intentionally redefining the plain-Markdown renderer contract. Actual: \(snapshot.sourceContentHash)"
        )
        XCTAssertEqual(snapshot.segments.map(\.segmentType), [.p, .ul, .p])
    }
}
