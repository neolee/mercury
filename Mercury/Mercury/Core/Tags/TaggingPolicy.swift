//
//  TaggingPolicy.swift
//  Mercury
//

import Foundation

/// Centralizes tagging-related policy constants and thresholds for panel (single-article) mode.
enum TaggingPolicy {
    /// Maximum number of AI-suggested tag chips shown in the tagging panel.
    static let maxAIRecommendations = 5

    /// Maximum number of existing-tag prefix-match chips shown during input.
    static let maxExistingTagChips = 10

    /// Minimum `usageCount` a tag must reach before it is promoted from provisional to permanent.
    /// Governs manual + panel-accepted tags only; batch tags stay provisional until sign-off.
    static let provisionalPromotionThreshold = 2

    /// Maximum number of existing (non-provisional) tags injected into the prompt as vocabulary context.
    static let maxVocabularyInjection = 50

    /// Maximum new tag names (not in existing vocabulary) the panel prompt asks the LLM to propose.
    /// This is prompt-level guidance only — not enforced client-side.
    static let maxNewTagProposalsPerEntry = 3

    /// Hard execution cap for a panel tagging task (seconds). Matches `TaskTimeoutPolicy.executionTimeoutByTaskKind[.tagging]`.
    static let panelLLMTimeoutSeconds: TimeInterval = 60
}
