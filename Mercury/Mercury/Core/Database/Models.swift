//
//  Models.swift
//  Mercury
//
//  Created by Neo on 2026/2/3.
//

import Foundation
import GRDB

enum AgentTaskType: String, Codable, CaseIterable {
    case tagging
    case summary
    case translation
}

enum AgentTaskRunStatus: String, Codable, CaseIterable {
    case queued
    case running
    case succeeded
    case failed
    case timedOut
    case cancelled
}

enum TranslationResultRunStatus: String, Codable, CaseIterable {
    case running
    case succeeded
}

enum LLMUsageRequestPhase: String, Codable, CaseIterable {
    case normal
    case repair
    case retry
}

enum LLMUsageRequestStatus: String, Codable, CaseIterable {
    case succeeded
    case failed
    case cancelled
    case timedOut
}

enum LLMUsageAvailability: String, Codable, CaseIterable {
    case actual
    case missing
}

enum SummaryDetailLevel: String, Codable, CaseIterable {
    case short
    case medium
    case detailed
}

enum TranslationSegmentType: String, Codable, CaseIterable {
    case p
    case ul
    case ol
}

enum AgentModelCapability: String, Codable, CaseIterable {
    case tagging
    case summary
    case translation
}

struct AgentProviderProfile: Codable, FetchableRecord, MutablePersistableRecord, Identifiable {
    static let databaseTableName = "agent_provider_profile"

    var id: Int64?
    var name: String
    var baseURL: String
    var apiKeyRef: String
    var testModel: String
    var isDefault: Bool
    var isEnabled: Bool
    var isArchived: Bool
    var archivedAt: Date?
    var createdAt: Date
    var updatedAt: Date

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct AgentModelProfile: Codable, FetchableRecord, MutablePersistableRecord, Identifiable {
    static let databaseTableName = "agent_model_profile"

    var id: Int64?
    var providerProfileId: Int64
    var name: String
    var modelName: String
    var temperature: Double?
    var topP: Double?
    var maxTokens: Int?
    var isStreaming: Bool
    var supportsTagging: Bool
    var supportsSummary: Bool
    var supportsTranslation: Bool
    var isDefault: Bool
    var isEnabled: Bool
    var isArchived: Bool
    var archivedAt: Date?
    var lastTestedAt: Date?
    var createdAt: Date
    var updatedAt: Date

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct AgentProfile: Codable, FetchableRecord, MutablePersistableRecord, Identifiable {
    static let databaseTableName = "agent_profile"

    var id: Int64?
    var name: String
    var taskType: AgentTaskType
    var systemPrompt: String
    var outputStyle: String?
    var defaultModelProfileId: Int64?
    var isEnabled: Bool
    var createdAt: Date
    var updatedAt: Date

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct AgentTaskRouting: Codable, FetchableRecord, MutablePersistableRecord, Identifiable {
    static let databaseTableName = "agent_task_routing"

    var id: Int64?
    var taskType: AgentTaskType
    var agentProfileId: Int64?
    var preferredModelProfileId: Int64
    var fallbackModelProfileId: Int64?
    var createdAt: Date
    var updatedAt: Date

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct AgentTaskRun: Codable, FetchableRecord, MutablePersistableRecord, Identifiable {
    static let databaseTableName = "agent_task_run"

    var id: Int64?
    var entryId: Int64
    var taskType: AgentTaskType
    var status: AgentTaskRunStatus
    var agentProfileId: Int64?
    var providerProfileId: Int64?
    var modelProfileId: Int64?
    var promptVersion: String?
    var targetLanguage: String?
    var templateId: String?
    var templateVersion: String?
    var runtimeParameterSnapshot: String?
    var durationMs: Int?
    var createdAt: Date
    var updatedAt: Date

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct LLMUsageEvent: Codable, FetchableRecord, MutablePersistableRecord, Identifiable {
    static let databaseTableName = "llm_usage_event"

    var id: Int64?
    var taskRunId: Int64?
    var entryId: Int64?
    var taskType: AgentTaskType
    var providerProfileId: Int64?
    var modelProfileId: Int64?
    var providerBaseURLSnapshot: String
    var providerResolvedURLSnapshot: String?
    var providerResolvedHostSnapshot: String?
    var providerResolvedPathSnapshot: String?
    var providerNameSnapshot: String?
    var modelNameSnapshot: String
    var requestPhase: LLMUsageRequestPhase
    var requestStatus: LLMUsageRequestStatus
    var promptTokens: Int?
    var completionTokens: Int?
    var totalTokens: Int?
    var usageAvailability: LLMUsageAvailability
    var startedAt: Date?
    var finishedAt: Date?
    var createdAt: Date

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct SummaryResult: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "summary_result"

    var taskRunId: Int64
    var entryId: Int64
    var targetLanguage: String
    var detailLevel: SummaryDetailLevel
    var outputLanguage: String
    var text: String
    var createdAt: Date
    var updatedAt: Date
}

struct TranslationResult: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "translation_result"

    var taskRunId: Int64
    var entryId: Int64
    var targetLanguage: String
    var sourceContentHash: String
    var segmenterVersion: String
    var outputLanguage: String
    var runStatus: TranslationResultRunStatus
    var createdAt: Date
    var updatedAt: Date
}

struct TranslationSegment: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "translation_segment"

    var taskRunId: Int64
    var sourceSegmentId: String
    var orderIndex: Int
    var sourceTextSnapshot: String?
    var translatedText: String
    var createdAt: Date
    var updatedAt: Date
}

struct Feed: Codable, FetchableRecord, MutablePersistableRecord, Identifiable {
    static let databaseTableName = "feed"

    var id: Int64?
    var title: String?
    var feedURL: String
    var siteURL: String?
    var feedParserVersion: Int? = nil
    var lastFetchedAt: Date?
    var createdAt: Date

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct Entry: Codable, FetchableRecord, MutablePersistableRecord, Identifiable {
    static let databaseTableName = "entry"

    var id: Int64?
    var feedId: Int64
    var guid: String?
    var url: String?
    var title: String?
    var author: String?
    var publishedAt: Date?
    var summary: String?
    var isRead: Bool
    var isStarred: Bool = false
    var createdAt: Date

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct EntryListItem: Identifiable, Hashable {
    var id: Int64
    var feedId: Int64
    var title: String?
    var publishedAt: Date?
    var createdAt: Date
    var isRead: Bool
    var isStarred: Bool = false
    var feedSourceTitle: String?
}

struct EntryNote: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "entry_note"

    var entryId: Int64
    var markdownText: String
    var createdAt: Date
    var updatedAt: Date
}

enum ContentDisplayMode: String, Codable {
    case web
    case cleaned
}

struct Content: Codable, FetchableRecord, MutablePersistableRecord, Identifiable {
    static let databaseTableName = "content"

    var id: Int64?
    var entryId: Int64
    /// Fetched source HTML for the article URL.
    var html: String?
    /// Cleaned HTML produced by Readability.parse().
    var cleanedHtml: String?
    /// Title extracted by Readability at the time cleanedHtml was built.
    var readabilityTitle: String?
    /// Byline extracted by Readability at the time cleanedHtml was built.
    var readabilityByline: String?
    /// Version of Readability extraction rules used to build cleanedHtml. Nil == 0.
    var readabilityVersion: Int?
    /// Canonical Markdown payload derived from cleanedHtml.
    var markdown: String?
    /// Version of the Markdown converter rules used to build markdown. Nil == 0.
    var markdownVersion: Int?
    var displayMode: String
    var createdAt: Date

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct ContentHTMLCache: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "content_html_cache"

    var entryId: Int64
    var themeId: String
    var html: String
    /// Version of the reader renderer rules used to build this cache record. Nil == 0.
    var readerRenderVersion: Int?
    var updatedAt: Date
}

struct Tag: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Sendable {
    static let databaseTableName = "tag"

    var id: Int64?
    var name: String
    var normalizedName: String
    var isProvisional: Bool
    var usageCount: Int

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct TagAlias: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Sendable {
    static let databaseTableName = "tag_alias"

    var id: Int64?
    var tagId: Int64
    var alias: String
    var normalizedAlias: String

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct EntryTag: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    static let databaseTableName = "entry_tag"

    var entryId: Int64
    var tagId: Int64
    var source: String
    var confidence: Double?
}

extension Entry {
    static let entryTags = hasMany(EntryTag.self)
    static let tags = hasMany(Tag.self, through: entryTags, using: EntryTag.tag)
}

extension Tag {
    static let entryTags = hasMany(EntryTag.self)
    static let entries = hasMany(Entry.self, through: entryTags, using: EntryTag.entry)
    static let aliases = hasMany(TagAlias.self)
}

extension EntryTag {
    static let entry = belongsTo(Entry.self)
    static let tag = belongsTo(Tag.self)
}

extension TagAlias {
    static let tag = belongsTo(Tag.self)
}
