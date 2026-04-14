import Testing
@testable import Mercury

@Suite("Translation Hash Baseline")
@MainActor
struct TranslationHashBaselineTests {
    @Test("Plain Markdown renderer hash remains stable")
    func plainMarkdownRendererHashStability() throws {
        let markdown = """
        # Baseline Title

        Lead paragraph with a [link](https://example.com).

        - Apple
        - Banana

        Another paragraph with `inline code`.

        ![Hero](https://example.com/hero.jpg)
        """

        let snapshot = try TranslationSegmentExtractor.extract(entryId: 9001, markdown: markdown)
        #expect(
            snapshot.sourceContentHash == "68770b0daaed59390801402c6842d2ed265984333cd7e4ccb74672761c504949",
            "Update this baseline only when intentionally redefining the plain-Markdown renderer contract. Actual: \(snapshot.sourceContentHash)"
        )
        #expect(snapshot.segments.map(\.segmentType) == [.p, .ul, .p])
    }
}
