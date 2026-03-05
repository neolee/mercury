//
//  BatchTaggingPolicy.swift
//  Mercury
//

import Foundation

/// Centralizes tagging-related policy constants for batch (background) mode.
enum BatchTaggingPolicy {
    /// Soft warning threshold for large target sets.
    static let warningThreshold = 100

    /// Hard safety cap to prevent runaway workloads due to accidental query bugs.
    static let absoluteSafetyCap = 2000

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

    /// Number of entries applied in a single transactional chunk during review apply.
    static let applyChunkSize = 50

    /// Maximum number of retries when an entry-level request is rate limited.
    static let maxRateLimitRetries = 3

    /// Base delay for exponential backoff on HTTP 429 or rate-limit-equivalent errors.
    static let retryBaseDelaySeconds: Double = 1.0

    /// Cap for exponential backoff delays to keep worst-case run times bounded.
    static let retryMaxDelaySeconds: Double = 12.0
}
