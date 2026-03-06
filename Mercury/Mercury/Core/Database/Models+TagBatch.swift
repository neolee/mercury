import Foundation
import GRDB

enum TagBatchRunStatus: String, Codable, CaseIterable, Sendable {
    case configure
    case running
    case readyNext = "ready_next"
    case review
    case applying
    case done
    case cancelled
    case failed
}

extension TagBatchRunStatus {
    /// Active lifecycle states that keep a batch run open and block destructive tag mutations.
    static let activeLifecycleStatuses: [Self] = [
        .running,
        .readyNext,
        .review,
        .applying
    ]

    static let activeLifecycleRawValues = activeLifecycleStatuses.map(\.rawValue)

    var isActiveLifecycle: Bool {
        Self.activeLifecycleStatuses.contains(self)
    }

    var locksConfiguration: Bool {
        isActiveLifecycle
    }

    var blocksDestructiveTagMutation: Bool {
        isActiveLifecycle
    }
}

enum TagBatchEntryLifecycleState: String, Codable, CaseIterable, Sendable {
    case neverStarted = "never_started"
    case running
    case failed
    case stagedReady = "staged_ready"
    case applied
}

enum TagBatchAssignmentKind: String, Codable, CaseIterable, Sendable {
    case matched
    case newProposal = "new_proposal"
}

enum TagBatchReviewDecision: String, Codable, CaseIterable, Sendable {
    case pending
    case keep
    case discard
}

struct TagBatchRun: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Sendable {
    static let databaseTableName = "tag_batch_run"

    var id: Int64?
    var status: TagBatchRunStatus
    var scopeLabel: String
    var skipAlreadyApplied: Bool
    var skipAlreadyTagged: Bool
    var concurrency: Int
    var totalSelectedEntries: Int
    var totalPlannedEntries: Int
    var processedEntries: Int
    var succeededEntries: Int
    var failedEntries: Int
    var keptProposalCount: Int
    var discardedProposalCount: Int
    var insertedEntryTagCount: Int
    var createdTagCount: Int
    var startedAt: Date?
    var completedAt: Date?
    var createdAt: Date
    var updatedAt: Date

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct TagBatchEntry: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Sendable {
    static let databaseTableName = "tag_batch_entry"

    var id: Int64?
    var runId: Int64
    var entryId: Int64
    var lifecycleState: TagBatchEntryLifecycleState
    var attempts: Int
    var providerProfileId: Int64?
    var modelProfileId: Int64?
    var promptTokens: Int?
    var completionTokens: Int?
    var durationMs: Int?
    var rawResponse: String?
    var errorMessage: String?
    var createdAt: Date
    var updatedAt: Date

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct TagBatchAssignmentStaging: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Sendable {
    static let databaseTableName = "tag_batch_assignment_staging"

    var id: Int64?
    var runId: Int64
    var entryId: Int64
    var normalizedName: String
    var displayName: String
    var resolvedTagId: Int64?
    var assignmentKind: TagBatchAssignmentKind
    var createdAt: Date
    var updatedAt: Date

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct TagBatchNewTagReview: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Sendable {
    static let databaseTableName = "tag_batch_new_tag_review"

    var id: Int64?
    var runId: Int64
    var normalizedName: String
    var displayName: String
    var hitCount: Int
    var sampleEntryCount: Int
    var decision: TagBatchReviewDecision
    var createdAt: Date
    var updatedAt: Date

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct TagBatchApplyCheckpoint: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Sendable {
    static let databaseTableName = "tag_batch_apply_checkpoint"

    var id: Int64?
    var runId: Int64
    var lastAppliedChunkIndex: Int
    var totalChunks: Int
    var lastAppliedEntryId: Int64?
    var updatedAt: Date

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension TagBatchRun {
    static let entries = hasMany(TagBatchEntry.self)
    static let assignments = hasMany(TagBatchAssignmentStaging.self)
    static let reviews = hasMany(TagBatchNewTagReview.self)
    static let checkpoints = hasMany(TagBatchApplyCheckpoint.self)
}

extension TagBatchEntry {
    static let run = belongsTo(TagBatchRun.self)
    static let entry = belongsTo(Entry.self)
}

extension TagBatchAssignmentStaging {
    static let run = belongsTo(TagBatchRun.self)
    static let entry = belongsTo(Entry.self)
    static let tag = belongsTo(Tag.self)
}

extension TagBatchNewTagReview {
    static let run = belongsTo(TagBatchRun.self)
}

extension TagBatchApplyCheckpoint {
    static let run = belongsTo(TagBatchRun.self)
}
