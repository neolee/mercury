//
//  TagInputSuggestion.swift
//  Mercury
//

import AppKit

/// A suggestion presented in the "Did you mean:" row of the tagging panel input field.
///
/// Generated at word boundaries (space or comma) via `TagInputSuggestionEngine.suggest(for:in:excluding:)`.
/// The UI treats all cases identically — a single inline link — so adding new case kinds
/// (e.g. AI-suggested) does not require UI changes.
enum TagInputSuggestion {
    /// A tag already in the library whose normalized form is close to the typed token.
    case existingMatch(tag: Tag, original: String)
    /// A spelling correction produced by `NSSpellChecker`.
    case spelling(correction: String, original: String)
    // future: case aiSuggested(name: String, original: String)

    /// The text to substitute when the user accepts this suggestion.
    var correctedText: String {
        switch self {
        case .existingMatch(let tag, _): return tag.name
        case .spelling(let correction, _): return correction
        }
    }

    /// The token string as originally typed by the user.
    var original: String {
        switch self {
        case .existingMatch(_, let o): return o
        case .spelling(_, let o): return o
        }
    }
}

/// Stateless engine that computes a `TagInputSuggestion` for a typed token.
/// All methods are synchronous and side-effect-free.
enum TagInputSuggestionEngine {

    // MARK: - Public API

    /// Returns the best suggestion for `token`, or `nil` if none is appropriate.
    ///
    /// Priority order:
    /// 1. Exact tag match in `library` → no suggestion (token is already a valid known tag).
    /// 2. Fuzzy tag match (Levenshtein ≤ 2) against `library` → suggest adopting the existing tag.
    /// 3. `NSSpellChecker` correction → suggest corrected spelling.
    ///
    /// Tags whose `normalizedName` is in `excluding` are skipped for fuzzy matching.
    static func suggest(
        for token: String,
        in library: [Tag],
        excluding: Set<String>
    ) -> TagInputSuggestion? {
        let normed = TagNormalization.normalize(token)
        guard normed.isEmpty == false else { return nil }

        // Exact match: token is already in the library — no nudge needed.
        if library.contains(where: { $0.normalizedName == normed }) { return nil }

        // Fuzzy tag match.
        if let match = closestTag(in: library, excluding: excluding, to: normed) {
            return .existingMatch(tag: match, original: token)
        }

        // Spelling correction.
        if let correction = spellCheck(token) {
            return .spelling(correction: correction, original: token)
        }

        return nil
    }

    // MARK: - Fuzzy Tag Match

    private static func closestTag(
        in tags: [Tag],
        excluding: Set<String>,
        to normedInput: String
    ) -> Tag? {
        guard normedInput.count >= 3 else { return nil }
        var best: (tag: Tag, dist: Int)?
        for tag in tags {
            guard excluding.contains(tag.normalizedName) == false else { continue }
            let dist = editDistance(normedInput, tag.normalizedName)
            guard dist > 0, dist <= 2 else { continue }
            if best == nil || dist < best!.dist { best = (tag, dist) }
        }
        return best?.tag
    }

    // MARK: - Spell Check

    /// Returns a corrected version of `token`, or `nil` if no correction is needed.
    ///
    /// Multi-word tokens are checked word by word; corrections are joined back into the
    /// original token shape. Guard rules are applied per word before calling `NSSpellChecker`.
    private static func spellCheck(_ token: String) -> String? {
        let words = token.components(separatedBy: .whitespaces).filter { $0.isEmpty == false }
        let checker = NSSpellChecker.shared
        var correctedWords: [String] = []
        var hadCorrection = false

        for word in words {
            guard shouldSpellCheck(word) else {
                correctedWords.append(word)
                continue
            }
            let misspelledRange = checker.checkSpelling(of: word, startingAt: 0)
            guard misspelledRange.location != NSNotFound,
                  let correction = checker.correction(
                      forWordRange: misspelledRange,
                      in: word,
                      language: checker.language(),
                      inSpellDocumentWithTag: 0
                  )
            else {
                correctedWords.append(word)
                continue
            }
            correctedWords.append(correction)
            hadCorrection = true
        }

        return hadCorrection ? correctedWords.joined(separator: " ") : nil
    }

    /// Returns `false` for word forms that must bypass spell checking:
    /// - ALL-CAPS (e.g. `WWDC`, `API`, `LLM`) — treated as abbreviations.
    /// - CamelCase (e.g. `SwiftUI`, `CoreML`, `iPhone`) — treated as technical identifiers.
    ///
    /// All other forms — including short lowercase words like `teh` — are checked normally.
    private static func shouldSpellCheck(_ word: String) -> Bool {
        let letters = word.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard letters.isEmpty == false else { return false }
        // ALL-CAPS: every letter character is uppercase.
        if letters.allSatisfy({ CharacterSet.uppercaseLetters.contains($0) }) { return false }
        // CamelCase: has an uppercase letter after the first character.
        if word.dropFirst().contains(where: { $0.isUppercase }) { return false }
        return true
    }

    // MARK: - Edit Distance

    /// Standard Levenshtein edit distance between two strings.
    static func editDistance(_ s: String, _ t: String) -> Int {
        let s = Array(s), t = Array(t)
        let m = s.count, n = t.count
        if m == 0 { return n }
        if n == 0 { return m }
        var dp = Array(0...n)
        for i in 1...m {
            var prev = dp[0]
            dp[0] = i
            for j in 1...n {
                let temp = dp[j]
                dp[j] = s[i - 1] == t[j - 1] ? prev : min(prev, min(dp[j - 1], dp[j])) + 1
                prev = temp
            }
        }
        return dp[n]
    }
}
