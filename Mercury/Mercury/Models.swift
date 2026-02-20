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
    case cancelled
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
    static let databaseTableName = "ai_provider_profile"

    var id: Int64?
    var name: String
    var baseURL: String
    var apiKeyRef: String
    var testModel: String
    var isDefault: Bool
    var isEnabled: Bool
    var createdAt: Date
    var updatedAt: Date

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct AgentModelProfile: Codable, FetchableRecord, MutablePersistableRecord, Identifiable {
    static let databaseTableName = "ai_model_profile"

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
    var createdAt: Date
    var updatedAt: Date

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct AgentAssistantProfile: Codable, FetchableRecord, MutablePersistableRecord, Identifiable {
    static let databaseTableName = "ai_assistant_profile"

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
    static let databaseTableName = "ai_task_routing"

    var id: Int64?
    var taskType: AgentTaskType
    var assistantProfileId: Int64?
    var preferredModelProfileId: Int64
    var fallbackModelProfileId: Int64?
    var createdAt: Date
    var updatedAt: Date

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct AgentTaskRun: Codable, FetchableRecord, MutablePersistableRecord, Identifiable {
    static let databaseTableName = "ai_task_run"

    var id: Int64?
    var entryId: Int64
    var taskType: AgentTaskType
    var status: AgentTaskRunStatus
    var assistantProfileId: Int64?
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

struct SummaryResult: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "ai_summary_result"

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
    static let databaseTableName = "ai_translation_result"

    var taskRunId: Int64
    var entryId: Int64
    var targetLanguage: String
    var sourceContentHash: String
    var segmenterVersion: String
    var outputLanguage: String
    var createdAt: Date
    var updatedAt: Date
}

struct TranslationSegment: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "ai_translation_segment"

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
    var unreadCount: Int
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
    var feedSourceTitle: String?
}

enum ContentDisplayMode: String, Codable {
    case web
    case cleaned
}

struct Content: Codable, FetchableRecord, MutablePersistableRecord, Identifiable {
    static let databaseTableName = "content"

    var id: Int64?
    var entryId: Int64
    var html: String?
    var markdown: String?
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
    var updatedAt: Date
}
