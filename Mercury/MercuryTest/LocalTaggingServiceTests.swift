import Foundation
import Testing
@testable import Mercury

@Suite("LocalTaggingService")
struct LocalTaggingServiceTests {

    // MARK: - Dual-path extraction

    @Test("Extracts named entities when title contains known organizations and people")
    func extractsEntitiesFromTitle() async {
        let service = LocalTaggingService()
        let title = "Apple announced new products at WWDC. CEO Tim Cook presented the keynote in Cupertino."
        let entities = await service.extractEntities(title: title, summary: nil)
        // NLTagger output may vary by OS version, but must return non-empty results
        // for a title that contains well-known named entities.
        #expect(entities.isEmpty == false)
    }

    @Test("Extracts named entities when only summary is provided")
    func extractsEntitiesFromSummaryOnly() async {
        let service = LocalTaggingService()
        let summary = "Apple announced new products at WWDC. CEO Tim Cook presented the keynote."
        let entities = await service.extractEntities(title: nil, summary: summary)
        // Summary path uses named-entities only; should still find Apple / Tim Cook.
        #expect(entities.isEmpty == false)
    }

    @Test("Returns empty array when both title and summary are nil")
    func returnsEmptyWhenBothInputsAreNil() async {
        let service = LocalTaggingService()
        let entities = await service.extractEntities(title: nil, summary: nil)
        #expect(entities.isEmpty)
    }

    @Test("Returns empty array when both title and summary are empty strings")
    func returnsEmptyForEmptyStrings() async {
        let service = LocalTaggingService()
        let entities = await service.extractEntities(title: "", summary: "")
        #expect(entities.isEmpty)
    }

    @Test("Deduplicates repeated entity occurrences across title and summary")
    func deduplicatesRepeatedEntities() async {
        let service = LocalTaggingService()
        let title = "Apple released a product."
        let summary = "Apple announced another product from Apple."
        let entities = await service.extractEntities(title: title, summary: summary)
        let appleCount = entities.filter { $0 == "Apple" }.count
        #expect(appleCount <= 1)
    }

    @Test("Returns low entity count for plain prose with no named entities")
    func returnsEmptyForPlainProse() async {
        let service = LocalTaggingService()
        let entities = await service.extractEntities(
            title: "the quick brown fox jumps over the lazy dog",
            summary: nil
        )
        // NLTagger should not extract named entities from plain common words.
        // We test for a low count rather than exact zero since NLTagger confidence can vary.
        #expect(entities.count < 3)
    }

    @Test("Title path extracts capitalized nouns absent from summary path")
    func titlePathExtractsCapitalizedNouns() async {
        // "Swift" and "GraphQL" are not named entities but are capitalized nouns.
        // They should appear when the title is provided, but summary-only should not include them.
        let service = LocalTaggingService()
        let titleText = "Building a Swift app with GraphQL"
        let titleOnly = await service.extractEntities(title: titleText, summary: nil)
        let summaryOnly = await service.extractEntities(title: nil, summary: titleText)
        // The title path (entities + capitalized nouns) should produce >= result of summary path
        // (entities only) for the same source text.
        #expect(titleOnly.count >= summaryOnly.count)
    }

    // MARK: - Quality Filter Tests

    @Test("Character filter removes entities containing disallowed characters")
    func characterFilterRemovesNoisyFragments() {
        // Entities containing apostrophes and similar punctuation are dropped.
        let result = LocalTaggingService.applyQualityFilters(to: ["Intel", "AMD didn't", "Apple"])
        #expect(result.contains("Intel"))
        #expect(result.contains("Apple"))
        #expect(result.contains("AMD didn't") == false)
    }

    @Test("Superset dedup keeps shorter canonical form and removes the longer superset")
    func supersetDedupDropsLongerForm() {
        // "Intel CPUs" normalizes to "intel cpus"; "intel" is a word-prefix of "intel cpus",
        // so "Intel CPUs" is identified as a superset and removed.
        let result = LocalTaggingService.applyQualityFilters(to: ["Intel", "Intel CPUs", "Apple"])
        #expect(result.contains("Intel"))
        #expect(result.contains("Apple"))
        #expect(result.contains("Intel CPUs") == false)
    }

    // MARK: - Purity Contract

    @Test("extractEntities is a pure function with no database side-effects")
    func extractEntitiesHasNoDatabaseSideEffects() async {
        // This test enforces the behavioral contract: extractEntities must be callable without
        // any database setup, produce no mutations, and return deterministic results.
        let service = LocalTaggingService()
        let title = "Apple announced new products at WWDC. CEO Tim Cook presented the keynote in Cupertino."
        let first = await service.extractEntities(title: title, summary: nil)
        let second = await service.extractEntities(title: title, summary: nil)
        // Calling twice on the same input must yield identical results.
        #expect(first == second)
    }
}
