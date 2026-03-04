//
//  BatchTaggingPolicy.swift
//  Mercury
//

import Foundation

/// Centralizes tagging-related policy constants for batch (background) mode.
enum BatchTaggingPolicy {
    /// Maximum number of articles processed in a single batch run.
    static let maxEntriesPerRun = 100

    /// Maximum total tags (matched + new) the batch prompt asks the LLM to assign per article.
    static let maxTagsPerEntry = 3

    /// Maximum new tag names the batch prompt asks the LLM to propose per article.
    /// More conservative than panel mode (3) because sign-off burden scales with corpus size.
    /// This is prompt-level guidance only — not enforced client-side.
    static let maxNewTagProposalsPerEntry = 2

    /// Maximum number of existing (non-provisional) tags injected into the prompt as vocabulary context.
    static let maxVocabularyInjection = 50

    /// Maximum number of simultaneous LLM requests within a single batch run.
    static let concurrencyLimit = 3
}
