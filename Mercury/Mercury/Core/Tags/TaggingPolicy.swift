//
//  TaggingPolicy.swift
//  Mercury
//

import Foundation

/// Centralizes tagging-related policy constants and thresholds.
enum TaggingPolicy {
    /// Maximum number of AI-suggested tag chips shown in the tagging panel at once.
    static let maxAIRecommendations = 3

    /// Maximum number of existing-tag prefix-match chips shown during input.
    static let maxExistingTagChips = 12

    /// Minimum `usageCount` a tag must reach before it is promoted from provisional to permanent.
    static let provisionalPromotionThreshold = 2
}
