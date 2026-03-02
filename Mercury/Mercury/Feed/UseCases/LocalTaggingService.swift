//
//  LocalTaggingService.swift
//  Mercury
//

import Foundation
import NaturalLanguage

/// A local NLP service that extracts tag candidates from entry title and summary
/// using macOS `NLTagger`. Results are used as provisional suggestions in the tagging panel.
///
/// Extraction strategy:
/// - Title: named entities (organizations, people, places) + capitalized nouns.
///   Titles are typically short and well-formed; capitalized nouns reliably surface
///   product names, technologies, and frameworks (e.g. "GraphQL", "Kubernetes", "Swift").
/// - Summary: named entities only.
///   RSS summaries are often truncated HTML fragments with inconsistent capitalization,
///   making noun extraction noisy. Restricting to named entities keeps quality higher.
actor LocalTaggingService {
    private static let namedEntityTypes: Set<NLTag> = [.organizationName, .personalName, .placeName]
    private static let taggerOptions: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]

    // MARK: - Public API

    /// Extracts tag candidates from an entry's title and summary.
    ///
    /// Returns deduplicated, quality-filtered strings in order of appearance (title first).
    /// Returns an empty array when both inputs are nil or produce no candidates.
    ///
    /// Quality filters applied after extraction:
    /// 1. Character filter: tokens containing characters other than letters, digits, spaces,
    ///    or hyphens are dropped.
    /// 2. Length filter: tokens with more than 4 words or more than 25 characters are dropped.
    /// 3. Superset dedup: when token A's normalizedName is a word-prefix of token B's,
    ///    B is dropped and A is kept (handles "Intel" vs "Intel CPUs").
    ///
    /// This method has no side-effects; it does not write to any database or persistent store.
    func extractEntities(title: String?, summary: String?) -> [String] {
        var seen = Set<String>()
        var results: [String] = []

        if let title, title.isEmpty == false {
            for candidate in extractFromTitle(title) {
                if seen.insert(candidate).inserted {
                    results.append(candidate)
                }
            }
        }

        if let summary, summary.isEmpty == false {
            for candidate in extractNamedEntities(from: summary) {
                if seen.insert(candidate).inserted {
                    results.append(candidate)
                }
            }
        }

        return Self.applyQualityFilters(to: results)
    }

    // MARK: - Extraction

    /// Extracts named entities AND capitalized nouns from title text.
    private func extractFromTitle(_ text: String) -> [String] {
        let entities = extractNamedEntities(from: text)
        let nouns = extractCapitalizedNouns(from: text, excludingEntities: entities)
        // Named entities first, nouns appended: NLP-recognized names carry higher confidence
        // than raw capitalized nouns.
        return entities + nouns
    }

    /// Extracts named entities (organization, person, place) from text using the nameType scheme.
    private func extractNamedEntities(from text: String) -> [String] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text

        var seen = Set<String>()
        var results: [String] = []

        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .nameType,
            options: Self.taggerOptions
        ) { tag, tokenRange in
            guard let tag, Self.namedEntityTypes.contains(tag) else { return true }
            let token = String(text[tokenRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard token.isEmpty == false, seen.insert(token).inserted else { return true }
            results.append(token)
            return true
        }

        return results
    }

    /// Extracts capitalized single-token nouns from title text using the lexicalClass scheme.
    ///
    /// Candidates must:
    /// - Have NLTag `.noun`
    /// - Start with an uppercase letter (surfaces proper nouns and technical terms)
    /// - Be at least 3 characters long
    /// - Not already be covered by `excludingEntities` (case-insensitive)
    private func extractCapitalizedNouns(from text: String, excludingEntities entities: [String]) -> [String] {
        let entitySet = Set(entities.map { $0.lowercased() })
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text

        var seen = Set<String>()
        var results: [String] = []

        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .lexicalClass,
            options: [.omitWhitespace, .omitPunctuation]
        ) { tag, tokenRange in
            guard tag == .noun else { return true }
            let token = String(text[tokenRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard token.count >= 3,
                  token.first?.isUppercase == true,
                  entitySet.contains(token.lowercased()) == false,
                  seen.insert(token).inserted
            else { return true }
            results.append(token)
            return true
        }

        return results
    }

    // MARK: - Quality Filters

    private static let allowedEntityCharacters: CharacterSet = {
        CharacterSet.letters
            .union(.decimalDigits)
            .union(CharacterSet(charactersIn: " -"))
    }()

    /// Applies post-extraction quality filters and returns the cleaned candidate list.
    nonisolated static func applyQualityFilters(to entities: [String]) -> [String] {
        // Pass 1: character filter and length filter.
        let filtered = entities.filter { entity in
            guard entity.unicodeScalars.allSatisfy({ allowedEntityCharacters.contains($0) }) else {
                return false
            }
            let words = entity.components(separatedBy: .whitespaces).filter { $0.isEmpty == false }
            guard words.count <= 4, entity.count <= 25 else { return false }
            return true
        }

        // Pass 2: superset dedup — if entity A's normalizedName is a word-prefix of entity B's
        // normalizedName, B is a superset of A and is removed.
        let normedForms = filtered.map { TagNormalization.normalize($0) }
        let supersetsToRemove: Set<Int> = Set(
            filtered.indices.filter { i in
                let iNorm = normedForms[i]
                return filtered.indices.contains { j in
                    guard j != i else { return false }
                    let jNorm = normedForms[j]
                    return iNorm.hasPrefix(jNorm + " ")
                }
            }
        )

        return filtered
            .enumerated()
            .filter { supersetsToRemove.contains($0.offset) == false }
            .map { $0.element }
    }
}
