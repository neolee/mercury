import Foundation
import GRDB
import Testing
@testable import Mercury

@Suite("Tagging Execution")
@MainActor
struct TaggingExecutionTests {

    // MARK: - parseTagsFromLLMResponse

    @Test("Returns tags from a valid flat JSON array")
    func parsesValidFlatArray() {
        let text = #"["machine learning", "open source", "wwdc"]"#
        let result = parseTagsFromLLMResponse(text)
        #expect(result == ["machine learning", "open source", "wwdc"])
    }

    @Test("Strips markdown code fences before parsing")
    func stripsMarkdownFences() {
        let text = "```json\n[\"swift\", \"developer tools\"]\n```"
        let result = parseTagsFromLLMResponse(text)
        #expect(result == ["swift", "developer tools"])
    }

    @Test("Strips bare triple-backtick fences before parsing")
    func stripsBareFences() {
        let text = "```\n[\"swift\"]\n```"
        let result = parseTagsFromLLMResponse(text)
        #expect(result == ["swift"])
    }

    @Test("Returns empty array for non-JSON response text")
    func returnsEmptyForNonJSON() {
        let result = parseTagsFromLLMResponse("Sorry, I cannot tag this article.")
        #expect(result.isEmpty)
    }

    @Test("Returns empty array for empty string input")
    func returnsEmptyForEmptyStringInput() {
        let result = parseTagsFromLLMResponse("")
        #expect(result.isEmpty)
    }

    @Test("Returns empty array for empty JSON array")
    func returnsEmptyForEmptyJSONArray() {
        let result = parseTagsFromLLMResponse("[]")
        #expect(result.isEmpty)
    }

    @Test("Trims whitespace from individual tag names")
    func trimsWhitespace() {
        let result = parseTagsFromLLMResponse(#"["  swift  ", " ai "]"#)
        #expect(result == ["swift", "ai"])
    }

    @Test("Filters out empty strings after trimming")
    func filtersEmptyStrings() {
        let result = parseTagsFromLLMResponse(#"["swift", "  ", "ai"]"#)
        #expect(result == ["swift", "ai"])
    }

    // MARK: - resolveTagNamesFromDB

    @Test("Returns canonical name when normalized form matches existing tag exactly")
    @MainActor
    func resolvesExactTagMatch() async throws {
        try await InMemoryDatabaseFixture.withFixture { fixture in
            let db = fixture.database

            try await db.write { d in
                var tag = Tag(id: nil, name: "Swift", normalizedName: "swift", isProvisional: false, usageCount: 10)
                try tag.insert(d)
            }

            let result = try await resolveTagNamesFromDB(["Swift"], database: db)
            #expect(result == ["Swift"])
        }
    }

    @Test("Case-insensitive: 'SWIFT' resolves to canonical 'Swift'")
    @MainActor
    func resolvesCaseInsensitiveMatch() async throws {
        try await InMemoryDatabaseFixture.withFixture { fixture in
            let db = fixture.database

            try await db.write { d in
                var tag = Tag(id: nil, name: "Swift", normalizedName: "swift", isProvisional: false, usageCount: 5)
                try tag.insert(d)
            }

            let result = try await resolveTagNamesFromDB(["SWIFT"], database: db)
            #expect(result == ["Swift"])
        }
    }

    @Test("Alias match resolves to canonical tag name")
    @MainActor
    func resolvesAliasToCanonicalName() async throws {
        try await InMemoryDatabaseFixture.withFixture { fixture in
            let db = fixture.database

            let tagId: Int64 = try await db.write { d in
                var tag = Tag(id: nil, name: "Machine Learning", normalizedName: "machine learning", isProvisional: false, usageCount: 3)
                try tag.insert(d)
                return tag.id!
            }

            try await db.write { d in
                var alias = TagAlias(id: nil, tagId: tagId, alias: "ML", normalizedAlias: "ml")
                try alias.insert(d)
            }

            let result = try await resolveTagNamesFromDB(["ML"], database: db)
            #expect(result == ["Machine Learning"])
        }
    }

    @Test("Unmatched name keeps the original display casing for new proposals")
    @MainActor
    func preservesOriginalDisplayNameForNewProposal() async throws {
        try await InMemoryDatabaseFixture.withFixture { fixture in
            let db = fixture.database

            let result = try await resolveTagNamesFromDB(["iOS"], database: db)
            #expect(result == ["iOS"])
        }
    }

    @Test("Deduplicates unmatched proposals by normalized name while keeping first display form")
    @MainActor
    func deduplicatesNewProposalsByNormalizedName() async throws {
        try await InMemoryDatabaseFixture.withFixture { fixture in
            let db = fixture.database

            let result = try await resolveTagNamesFromDB(["iOS", "IOS", " iOS "], database: db)
            #expect(result == ["iOS"])
        }
    }

    @Test("Deduplicates results when multiple inputs resolve to the same canonical name")
    @MainActor
    func deduplicatesDuplicateResolutions() async throws {
        try await InMemoryDatabaseFixture.withFixture { fixture in
            let db = fixture.database

            try await db.write { d in
                var tag = Tag(id: nil, name: "Swift", normalizedName: "swift", isProvisional: false, usageCount: 1)
                try tag.insert(d)
            }

            let result = try await resolveTagNamesFromDB(["swift", "Swift"], database: db)
            #expect(result == ["Swift"])
            #expect(result.count == 1)
        }
    }

    @Test("Preserves order of first occurrence across mixed matched and new proposals")
    @MainActor
    func preservesFirstOccurrenceOrdering() async throws {
        try await InMemoryDatabaseFixture.withFixture { fixture in
            let db = fixture.database

            try await db.write { d in
                var tag = Tag(id: nil, name: "Swift", normalizedName: "swift", isProvisional: false, usageCount: 2)
                try tag.insert(d)
            }

            let result = try await resolveTagNamesFromDB(["linux", "Swift", "open source"], database: db)
            #expect(result[0] == "linux")
            #expect(result[1] == "Swift")
            #expect(result[2] == "open source")
        }
    }

    @Test("Returns empty result for empty input array")
    @MainActor
    func returnsEmptyForEmptyInputArray() async throws {
        try await InMemoryDatabaseFixture.withFixture { fixture in
            let db = fixture.database

            let result = try await resolveTagNamesFromDB([], database: db)
            #expect(result.isEmpty)
        }
    }
}
