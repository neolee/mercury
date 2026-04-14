//
//  TagInputSuggestionEngineTests.swift
//  MercuryTest
//

import Testing
@testable import Mercury

@Suite("TagInputSuggestionEngine")
@MainActor
struct TagInputSuggestionEngineTests {

    // MARK: - Helpers

    private func makeTag(id: Int64 = 1, name: String) -> Mercury.Tag {
        Mercury.Tag(
            id: id,
            name: name,
            normalizedName: TagNormalization.normalize(name),
            isProvisional: false,
            usageCount: 1
        )
    }

    // MARK: - Empty and nil inputs

    @Test("returns nil for empty token")
    func returnsNilForEmptyToken() {
        let result = TagInputSuggestionEngine.suggest(for: "", in: [makeTag(name: "swift")], excluding: [])
        #expect(result == nil)
    }

    @Test("returns nil for whitespace-only token")
    func returnsNilForWhitespaceToken() {
        let result = TagInputSuggestionEngine.suggest(for: "   ", in: [makeTag(name: "swift")], excluding: [])
        #expect(result == nil)
    }

    @Test("returns nil for empty library")
    func returnsNilForEmptyLibrary() {
        let result = TagInputSuggestionEngine.suggest(for: "swift", in: [], excluding: [])
        #expect(result == nil)
    }

    // MARK: - Exact match suppression

    @Test("returns nil when token exactly matches a library tag")
    func returnsNilForExactMatch() {
        // "Swift" normalizes to "swift", which is an exact match.
        let library = [makeTag(name: "Swift")]
        let result = TagInputSuggestionEngine.suggest(for: "Swift", in: library, excluding: [])
        #expect(result == nil)
    }

    @Test("returns nil when token matches a library tag after normalization")
    func returnsNilForNormalizedExactMatch() {
        // "SWIFT" and "swift" share the same normalized form.
        let library = [makeTag(name: "swift")]
        let result = TagInputSuggestionEngine.suggest(for: "SWIFT", in: library, excluding: [])
        #expect(result == nil)
    }

    // MARK: - Fuzzy tag matching

    @Test("returns existingMatch for edit distance 1")
    func returnsFuzzyMatchForEditDistance1() {
        // "swiftz" vs "swift": one insertion, edit distance = 1.
        let library = [makeTag(name: "swift")]
        let result = TagInputSuggestionEngine.suggest(for: "swiftz", in: library, excluding: [])
        guard case .existingMatch(let tag, let original) = result else {
            Issue.record("Expected .existingMatch, got \(String(describing: result))")
            return
        }
        #expect(tag.normalizedName == "swift")
        #expect(original == "swiftz")
    }

    @Test("returns existingMatch for edit distance 2")
    func returnsFuzzyMatchForEditDistance2() {
        // "swiftzz" vs "swift": two insertions, edit distance = 2.
        let library = [makeTag(name: "swift")]
        let result = TagInputSuggestionEngine.suggest(for: "swiftzz", in: library, excluding: [])
        guard case .existingMatch(_, _) = result else {
            Issue.record("Expected .existingMatch, got \(String(describing: result))")
            return
        }
    }

    @Test("returns nil for edit distance above threshold")
    func returnsNilForEditDistanceAboveThreshold() {
        // "swiftzzz" vs "swift": three insertions, edit distance = 3 > 2.
        let library = [makeTag(name: "swift")]
        let result = TagInputSuggestionEngine.suggest(for: "swiftzzz", in: library, excluding: [])
        #expect(result == nil)
    }

    @Test("selects the closest library tag when multiple candidates qualify")
    func selectsClosestFuzzyMatch() {
        // "pytohn" is a transposition of "python" (edit distance 2).
        // "pytest" differs by 3 edits from "pytohn" and should be skipped.
        let library = [
            makeTag(id: 1, name: "pytest"),
            makeTag(id: 2, name: "python")
        ]
        let result = TagInputSuggestionEngine.suggest(for: "pytohn", in: library, excluding: [])
        guard case .existingMatch(let tag, _) = result else {
            Issue.record("Expected .existingMatch, got \(String(describing: result))")
            return
        }
        #expect(tag.id == 2, "Expected match to be 'python', not 'pytest'")
    }

    // MARK: - Short token guard

    @Test("skips fuzzy matching for normalized tokens shorter than 3 characters")
    func returnsNilForShortNormalizedToken() {
        // "ab" normalizes to "ab" (length 2), which is below the fuzzy-match floor.
        let library = [makeTag(name: "ab")]
        let result = TagInputSuggestionEngine.suggest(for: "ab", in: library, excluding: [])
        #expect(result == nil)
    }

    // MARK: - Excluding set

    @Test("skips tags in the excluding set and returns nil when no other match")
    func skipsExcludedTag() {
        // "kotlinz" would fuzzily match "kotlin" (distance 1), but "kotlin" is excluded.
        // "kotlinz" does not produce a spell-checker correction so no fallback suggestion exists.
        let library = [makeTag(name: "kotlin")]
        let result = TagInputSuggestionEngine.suggest(
            for: "kotlinz",
            in: library,
            excluding: ["kotlin"]
        )
        #expect(result == nil)
    }

    @Test("falls through to a non-excluded tag when the closer match is excluded")
    func fallsThroughToNonExcludedTag() {
        // "kotlinz" (dist 1 from "kotlin", dist 2 from "kotlins").
        // "kotlin" is excluded so "kotlins" should be returned.
        // Neither input nor library tags produce spell-checker corrections.
        let library = [
            makeTag(id: 1, name: "kotlin"),
            makeTag(id: 2, name: "kotlins")
        ]
        let result = TagInputSuggestionEngine.suggest(
            for: "kotlinz",
            in: library,
            excluding: ["kotlin"]
        )
        guard case .existingMatch(let tag, _) = result else {
            Issue.record("Expected .existingMatch, got \(String(describing: result))")
            return
        }
        #expect(tag.id == 2, "Expected fallback to 'kotlins'")
    }

    // MARK: - Suggestion value properties

    @Test("existingMatch correctedText returns the canonical tag name")
    func existingMatchCorrectedTextReturnsTagName() {
        let tag = makeTag(name: "SwiftUI")
        let suggestion = TagInputSuggestion.existingMatch(tag: tag, original: "swiftuix")
        #expect(suggestion.correctedText == "SwiftUI")
        #expect(suggestion.original == "swiftuix")
    }

    @Test("spelling correctedText returns the corrected word")
    func spellingCorrectedTextReturnsCorrection() {
        let suggestion = TagInputSuggestion.spelling(correction: "receive", original: "recieve")
        #expect(suggestion.correctedText == "receive")
        #expect(suggestion.original == "recieve")
    }

    // MARK: - Edit distance utility

    @Test("editDistance returns 0 for identical strings")
    func editDistanceIdentical() {
        #expect(TagInputSuggestionEngine.editDistance("swift", "swift") == 0)
    }

    @Test("editDistance returns length for comparison with empty string")
    func editDistanceAgainstEmpty() {
        #expect(TagInputSuggestionEngine.editDistance("swift", "") == 5)
        #expect(TagInputSuggestionEngine.editDistance("", "swift") == 5)
    }

    @Test("editDistance counts single substitution as 1")
    func editDistanceSingleSubstitution() {
        #expect(TagInputSuggestionEngine.editDistance("swift", "swaft") == 1)
    }

    @Test("editDistance counts single insertion as 1")
    func editDistanceSingleInsertion() {
        #expect(TagInputSuggestionEngine.editDistance("swift", "swifft") == 1)
    }

    @Test("editDistance counts single deletion as 1")
    func editDistanceSingleDeletion() {
        #expect(TagInputSuggestionEngine.editDistance("swift", "swft") == 1)
    }
}
