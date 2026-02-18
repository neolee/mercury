//
//  DatabaseManager.swift
//  Mercury
//
//  Created by Neo on 2026/2/3.
//

import Foundation
import GRDB

final class DatabaseManager {
    let dbQueue: DatabaseQueue
    private let queue: DispatchQueue

    init(path: String? = nil) throws {
        if let path {
            dbQueue = try DatabaseQueue(path: path)
        } else {
            let fileManager = FileManager.default
            let appSupport = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let folder = appSupport.appendingPathComponent("Mercury", isDirectory: true)
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

            let dbURL = folder.appendingPathComponent("mercury.sqlite")
            dbQueue = try DatabaseQueue(path: dbURL.path)
        }

        queue = DispatchQueue(label: "Mercury.Database")

        try migrator.migrate(dbQueue)
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("createFeed") { db in
            try db.create(table: Feed.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("title", .text)
                t.column("feedURL", .text).notNull()
                t.column("siteURL", .text)
                t.column("unreadCount", .integer).notNull().defaults(to: 0)
                t.column("lastFetchedAt", .datetime)
                t.column("createdAt", .datetime).notNull().defaults(to: Date())
            }
            try db.create(index: "idx_feed_feedURL", on: Feed.databaseTableName, columns: ["feedURL"], unique: true)
        }

        migrator.registerMigration("createEntry") { db in
            try db.create(table: Entry.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("feedId", .integer).notNull().indexed().references(Feed.databaseTableName, onDelete: .cascade)
                t.column("guid", .text)
                t.column("url", .text)
                t.column("title", .text)
                t.column("author", .text)
                t.column("publishedAt", .datetime)
                t.column("summary", .text)
                t.column("isRead", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull().defaults(to: Date())
            }
            try db.create(index: "idx_entry_feed_guid", on: Entry.databaseTableName, columns: ["feedId", "guid"], unique: true)
            try db.create(index: "idx_entry_feed_url", on: Entry.databaseTableName, columns: ["feedId", "url"], unique: true)
        }

        migrator.registerMigration("createContent") { db in
            try db.create(table: Content.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("entryId", .integer).notNull().indexed().references(Entry.databaseTableName, onDelete: .cascade)
                t.column("html", .text)
                t.column("markdown", .text)
                t.column("displayMode", .text).notNull().defaults(to: ContentDisplayMode.web.rawValue)
                t.column("createdAt", .datetime).notNull().defaults(to: Date())
            }
            try db.create(index: "idx_content_entry", on: Content.databaseTableName, columns: ["entryId"], unique: true)
        }

        migrator.registerMigration("createContentHTMLCache") { db in
            try db.create(table: ContentHTMLCache.databaseTableName) { t in
                t.column("entryId", .integer).notNull().references(Entry.databaseTableName, onDelete: .cascade)
                t.column("themeId", .text).notNull()
                t.column("html", .text).notNull()
                t.column("updatedAt", .datetime).notNull().defaults(to: Date())
                t.primaryKey(["themeId", "entryId"])
            }
        }

        migrator.registerMigration("addEntryListIndexes") { db in
            try db.create(index: "idx_entry_published_created", on: Entry.databaseTableName, columns: ["publishedAt", "createdAt"])
            try db.create(index: "idx_entry_feed_published_created", on: Entry.databaseTableName, columns: ["feedId", "publishedAt", "createdAt"])
            try db.create(index: "idx_entry_isRead_published_created", on: Entry.databaseTableName, columns: ["isRead", "publishedAt", "createdAt"])
        }

        migrator.registerMigration("createAIProviderProfile") { db in
            try db.create(table: AIProviderProfile.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("baseURL", .text).notNull()
                t.column("apiKeyRef", .text).notNull()
                t.column("testModel", .text).notNull().defaults(to: "qwen3")
                t.column("isDefault", .boolean).notNull().defaults(to: false)
                t.column("isEnabled", .boolean).notNull().defaults(to: true)
                t.column("createdAt", .datetime).notNull().defaults(to: Date())
                t.column("updatedAt", .datetime).notNull().defaults(to: Date())
            }
            try db.create(index: "idx_ai_provider_name", on: AIProviderProfile.databaseTableName, columns: ["name"], unique: true)
        }

        migrator.registerMigration("addAIProviderTestModel") { db in
            let existingColumns = try db.columns(in: AIProviderProfile.databaseTableName).map(\ .name)
            guard existingColumns.contains("testModel") == false else {
                return
            }
            try db.alter(table: AIProviderProfile.databaseTableName) { t in
                t.add(column: "testModel", .text).notNull().defaults(to: "qwen3")
            }
        }

        migrator.registerMigration("addAIProviderIsDefault") { db in
            let existingColumns = try db.columns(in: AIProviderProfile.databaseTableName).map(\ .name)
            if existingColumns.contains("isDefault") == false {
                try db.alter(table: AIProviderProfile.databaseTableName) { t in
                    t.add(column: "isDefault", .boolean).notNull().defaults(to: false)
                }
            }

            let hasDefault = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM ai_provider_profile WHERE isDefault = 1)") ?? false
            if hasDefault == false {
                try db.execute(sql: """
                UPDATE ai_provider_profile
                SET isDefault = 1
                WHERE id = (
                    SELECT id
                    FROM ai_provider_profile
                    ORDER BY updatedAt DESC
                    LIMIT 1
                )
                """)
            }
        }

        migrator.registerMigration("createAIModelProfile") { db in
            try db.create(table: AIModelProfile.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("providerProfileId", .integer)
                    .notNull()
                    .indexed()
                    .references(AIProviderProfile.databaseTableName, onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("modelName", .text).notNull()
                t.column("temperature", .double)
                t.column("topP", .double)
                t.column("maxTokens", .integer)
                t.column("isStreaming", .boolean).notNull().defaults(to: true)
                t.column("supportsTagging", .boolean).notNull().defaults(to: false)
                t.column("supportsSummary", .boolean).notNull().defaults(to: false)
                t.column("supportsTranslation", .boolean).notNull().defaults(to: false)
                t.column("isDefault", .boolean).notNull().defaults(to: false)
                t.column("isEnabled", .boolean).notNull().defaults(to: true)
                t.column("createdAt", .datetime).notNull().defaults(to: Date())
                t.column("updatedAt", .datetime).notNull().defaults(to: Date())
            }
            try db.create(index: "idx_ai_model_provider", on: AIModelProfile.databaseTableName, columns: ["providerProfileId"])
            try db.create(index: "idx_ai_model_name", on: AIModelProfile.databaseTableName, columns: ["name"], unique: true)
        }

        migrator.registerMigration("addAIModelIsDefault") { db in
            let existingColumns = try db.columns(in: AIModelProfile.databaseTableName).map(\ .name)
            if existingColumns.contains("isDefault") == false {
                try db.alter(table: AIModelProfile.databaseTableName) { t in
                    t.add(column: "isDefault", .boolean).notNull().defaults(to: false)
                }
            }

            let hasDefault = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM ai_model_profile WHERE isDefault = 1)") ?? false
            if hasDefault == false {
                try db.execute(sql: """
                UPDATE ai_model_profile
                SET isDefault = 1
                WHERE id = (
                    SELECT id
                    FROM ai_model_profile
                    ORDER BY updatedAt DESC
                    LIMIT 1
                )
                """)
            }
        }

        migrator.registerMigration("createAIAssistantProfile") { db in
            try db.create(table: AIAssistantProfile.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("taskType", .text).notNull()
                t.column("systemPrompt", .text).notNull()
                t.column("outputStyle", .text)
                t.column("defaultModelProfileId", .integer)
                    .references(AIModelProfile.databaseTableName, onDelete: .setNull)
                t.column("isEnabled", .boolean).notNull().defaults(to: true)
                t.column("createdAt", .datetime).notNull().defaults(to: Date())
                t.column("updatedAt", .datetime).notNull().defaults(to: Date())
            }
            try db.create(index: "idx_ai_assistant_name", on: AIAssistantProfile.databaseTableName, columns: ["name"], unique: true)
            try db.create(index: "idx_ai_assistant_task", on: AIAssistantProfile.databaseTableName, columns: ["taskType"])
        }

        migrator.registerMigration("createAITaskRouting") { db in
            try db.create(table: AITaskRouting.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("taskType", .text).notNull()
                t.column("assistantProfileId", .integer)
                    .references(AIAssistantProfile.databaseTableName, onDelete: .setNull)
                t.column("preferredModelProfileId", .integer)
                    .notNull()
                    .references(AIModelProfile.databaseTableName, onDelete: .cascade)
                t.column("fallbackModelProfileId", .integer)
                    .references(AIModelProfile.databaseTableName, onDelete: .setNull)
                t.column("createdAt", .datetime).notNull().defaults(to: Date())
                t.column("updatedAt", .datetime).notNull().defaults(to: Date())
            }
            try db.create(index: "idx_ai_routing_task", on: AITaskRouting.databaseTableName, columns: ["taskType"])
            try db.create(index: "idx_ai_routing_assistant", on: AITaskRouting.databaseTableName, columns: ["assistantProfileId"])
        }

        migrator.registerMigration("createAITaskRun") { db in
            try db.create(table: AITaskRun.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("entryId", .integer)
                    .notNull()
                    .indexed()
                    .references(Entry.databaseTableName, onDelete: .cascade)
                t.column("taskType", .text).notNull()
                t.column("status", .text).notNull()
                t.column("assistantProfileId", .integer)
                    .references(AIAssistantProfile.databaseTableName, onDelete: .setNull)
                t.column("providerProfileId", .integer)
                    .references(AIProviderProfile.databaseTableName, onDelete: .setNull)
                t.column("modelProfileId", .integer)
                    .references(AIModelProfile.databaseTableName, onDelete: .setNull)
                t.column("promptVersion", .text)
                t.column("targetLanguage", .text)
                t.column("templateId", .text)
                t.column("templateVersion", .text)
                t.column("runtimeParameterSnapshot", .text)
                t.column("durationMs", .integer)
                t.column("createdAt", .datetime).notNull().defaults(to: Date())
                t.column("updatedAt", .datetime).notNull().defaults(to: Date())
            }

            try db.create(index: "idx_ai_task_run_entry", on: AITaskRun.databaseTableName, columns: ["entryId"])
            try db.create(index: "idx_ai_task_run_task", on: AITaskRun.databaseTableName, columns: ["taskType"])
            try db.create(index: "idx_ai_task_run_status", on: AITaskRun.databaseTableName, columns: ["status"])
            try db.create(index: "idx_ai_task_run_updated", on: AITaskRun.databaseTableName, columns: ["updatedAt"])
        }

        migrator.registerMigration("createAISummaryResult") { db in
            try db.create(table: AISummaryResult.databaseTableName) { t in
                t.column("taskRunId", .integer)
                    .notNull()
                    .references(AITaskRun.databaseTableName, onDelete: .cascade)
                t.column("entryId", .integer)
                    .notNull()
                    .indexed()
                    .references(Entry.databaseTableName, onDelete: .cascade)
                t.column("targetLanguage", .text).notNull()
                t.column("detailLevel", .text).notNull()
                t.column("outputLanguage", .text).notNull()
                t.column("text", .text).notNull()
                t.column("createdAt", .datetime).notNull().defaults(to: Date())
                t.column("updatedAt", .datetime).notNull().defaults(to: Date())
                t.primaryKey(["taskRunId"])
            }

            try db.create(
                index: "idx_ai_summary_slot",
                on: AISummaryResult.databaseTableName,
                columns: ["entryId", "targetLanguage", "detailLevel"],
                unique: true
            )
            try db.create(index: "idx_ai_summary_updated", on: AISummaryResult.databaseTableName, columns: ["updatedAt"])
        }

        return migrator
    }

    func read<T>(_ block: @escaping (Database) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let value = try self.dbQueue.read(block)
                    continuation.resume(returning: value)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func write<T>(_ block: @escaping (Database) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let value = try self.dbQueue.write(block)
                    continuation.resume(returning: value)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
