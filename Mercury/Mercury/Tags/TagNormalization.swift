//
//  TagNormalization.swift
//  Mercury
//

import Foundation

/// Centralized normalization logic for tag names.
///
/// All tag write paths and read paths that compare or deduplicate by canonical form must
/// route through `TagNormalization.normalize(_:)` to guarantee consistent behavior.
enum TagNormalization {

    /// Returns the canonical normalized form of a raw tag name string.
    ///
    /// Pipeline (applied in order):
    /// 1. Trim leading/trailing whitespace and newlines.
    /// 2. Lowercase.
    /// 3. Collapse any run of separator characters (`-`, `_`, `.`) or whitespace
    ///    (including multiple spaces) into a single space.
    ///
    /// Examples:
    /// - `"  AI-generated  "` → `"ai generated"`
    /// - `"Intel_CPU"` → `"intel cpu"`
    /// - `"foo...bar"` → `"foo bar"`
    /// - `"hello   world"` → `"hello world"`
    ///
    /// Returns an empty string when the input is empty or whitespace-only.
    nonisolated static func normalize(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return "" }
        let lowercased = trimmed.lowercased()
        // Replace any run of separators or whitespace with a single space.
        let separators = CharacterSet(charactersIn: "-_.")
            .union(.whitespaces)
            .union(.newlines)
        let components = lowercased.components(separatedBy: separators).filter { $0.isEmpty == false }
        return components.joined(separator: " ")
    }
}
