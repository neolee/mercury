import Foundation
import GRDB

extension DatabaseManager {
    var migrator: DatabaseMigrator {
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

        migrator.registerMigration("createAgentProviderProfile") { db in
            try db.create(table: AgentProviderProfile.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("baseURL", .text).notNull()
                t.column("apiKeyRef", .text).notNull()
                t.column("testModel", .text).notNull().defaults(to: "qwen3")
                t.column("isDefault", .boolean).notNull().defaults(to: false)
                t.column("isEnabled", .boolean).notNull().defaults(to: true)
                t.column("isArchived", .boolean).notNull().defaults(to: false)
                t.column("archivedAt", .datetime)
                t.column("createdAt", .datetime).notNull().defaults(to: Date())
                t.column("updatedAt", .datetime).notNull().defaults(to: Date())
            }
            try db.create(index: "idx_agent_provider_name", on: AgentProviderProfile.databaseTableName, columns: ["name"], unique: true)
        }

        migrator.registerMigration("addAgentProviderTestModel") { db in
            let existingColumns = try db.columns(in: AgentProviderProfile.databaseTableName).map(\ .name)
            guard existingColumns.contains("testModel") == false else {
                return
            }
            try db.alter(table: AgentProviderProfile.databaseTableName) { t in
                t.add(column: "testModel", .text).notNull().defaults(to: "qwen3")
            }
        }

        migrator.registerMigration("addAgentProviderIsDefault") { db in
            let existingColumns = try db.columns(in: AgentProviderProfile.databaseTableName).map(\ .name)
            if existingColumns.contains("isDefault") == false {
                try db.alter(table: AgentProviderProfile.databaseTableName) { t in
                    t.add(column: "isDefault", .boolean).notNull().defaults(to: false)
                }
            }

            let hasDefault = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM \(AgentProviderProfile.databaseTableName) WHERE isDefault = 1)") ?? false
            if hasDefault == false {
                try db.execute(sql: """
                UPDATE \(AgentProviderProfile.databaseTableName)
                SET isDefault = 1
                WHERE id = (
                    SELECT id
                    FROM \(AgentProviderProfile.databaseTableName)
                    ORDER BY updatedAt DESC
                    LIMIT 1
                )
                """)
            }
        }

        migrator.registerMigration("createAgentModelProfile") { db in
            try db.create(table: AgentModelProfile.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("providerProfileId", .integer)
                    .notNull()
                    .indexed()
                    .references(AgentProviderProfile.databaseTableName, onDelete: .cascade)
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
                t.column("isArchived", .boolean).notNull().defaults(to: false)
                t.column("archivedAt", .datetime)
                t.column("createdAt", .datetime).notNull().defaults(to: Date())
                t.column("updatedAt", .datetime).notNull().defaults(to: Date())
            }
            try db.create(index: "idx_agent_model_provider", on: AgentModelProfile.databaseTableName, columns: ["providerProfileId"])
            try db.create(index: "idx_agent_model_name", on: AgentModelProfile.databaseTableName, columns: ["name"], unique: true)
        }

        migrator.registerMigration("addAgentModelIsDefault") { db in
            let existingColumns = try db.columns(in: AgentModelProfile.databaseTableName).map(\ .name)
            if existingColumns.contains("isDefault") == false {
                try db.alter(table: AgentModelProfile.databaseTableName) { t in
                    t.add(column: "isDefault", .boolean).notNull().defaults(to: false)
                }
            }

            let hasDefault = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM \(AgentModelProfile.databaseTableName) WHERE isDefault = 1)") ?? false
            if hasDefault == false {
                try db.execute(sql: """
                UPDATE \(AgentModelProfile.databaseTableName)
                SET isDefault = 1
                WHERE id = (
                    SELECT id
                    FROM \(AgentModelProfile.databaseTableName)
                    ORDER BY updatedAt DESC
                    LIMIT 1
                )
                """)
            }
        }

        migrator.registerMigration("createAgentProfile") { db in
            try db.create(table: AgentProfile.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("taskType", .text).notNull()
                t.column("systemPrompt", .text).notNull()
                t.column("outputStyle", .text)
                t.column("defaultModelProfileId", .integer)
                    .references(AgentModelProfile.databaseTableName, onDelete: .setNull)
                t.column("isEnabled", .boolean).notNull().defaults(to: true)
                t.column("createdAt", .datetime).notNull().defaults(to: Date())
                t.column("updatedAt", .datetime).notNull().defaults(to: Date())
            }
            try db.create(index: "idx_agent_profile_name", on: AgentProfile.databaseTableName, columns: ["name"], unique: true)
            try db.create(index: "idx_agent_profile_task", on: AgentProfile.databaseTableName, columns: ["taskType"])
        }

        migrator.registerMigration("createAgentTaskRouting") { db in
            try db.create(table: AgentTaskRouting.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("taskType", .text).notNull()
                t.column("agentProfileId", .integer)
                    .references(AgentProfile.databaseTableName, onDelete: .setNull)
                t.column("preferredModelProfileId", .integer)
                    .notNull()
                    .references(AgentModelProfile.databaseTableName, onDelete: .cascade)
                t.column("fallbackModelProfileId", .integer)
                    .references(AgentModelProfile.databaseTableName, onDelete: .setNull)
                t.column("createdAt", .datetime).notNull().defaults(to: Date())
                t.column("updatedAt", .datetime).notNull().defaults(to: Date())
            }
            try db.create(index: "idx_agent_routing_task", on: AgentTaskRouting.databaseTableName, columns: ["taskType"])
            try db.create(index: "idx_agent_routing_agent", on: AgentTaskRouting.databaseTableName, columns: ["agentProfileId"])
        }

        migrator.registerMigration("createAgentTaskRun") { db in
            try db.create(table: AgentTaskRun.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("entryId", .integer)
                    .notNull()
                    .indexed()
                    .references(Entry.databaseTableName, onDelete: .cascade)
                t.column("taskType", .text).notNull()
                t.column("status", .text).notNull()
                t.column("agentProfileId", .integer)
                    .references(AgentProfile.databaseTableName, onDelete: .setNull)
                t.column("providerProfileId", .integer)
                    .references(AgentProviderProfile.databaseTableName, onDelete: .setNull)
                t.column("modelProfileId", .integer)
                    .references(AgentModelProfile.databaseTableName, onDelete: .setNull)
                t.column("promptVersion", .text)
                t.column("targetLanguage", .text)
                t.column("templateId", .text)
                t.column("templateVersion", .text)
                t.column("runtimeParameterSnapshot", .text)
                t.column("durationMs", .integer)
                t.column("createdAt", .datetime).notNull().defaults(to: Date())
                t.column("updatedAt", .datetime).notNull().defaults(to: Date())
            }

            try db.create(index: "idx_agent_task_run_entry", on: AgentTaskRun.databaseTableName, columns: ["entryId"])
            try db.create(index: "idx_agent_task_run_task", on: AgentTaskRun.databaseTableName, columns: ["taskType"])
            try db.create(index: "idx_agent_task_run_status", on: AgentTaskRun.databaseTableName, columns: ["status"])
            try db.create(index: "idx_agent_task_run_updated", on: AgentTaskRun.databaseTableName, columns: ["updatedAt"])
        }

        migrator.registerMigration("createLLMUsageEvent") { db in
            try db.create(table: LLMUsageEvent.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("taskRunId", .integer)
                    .references(AgentTaskRun.databaseTableName, onDelete: .setNull)
                t.column("entryId", .integer)
                    .references(Entry.databaseTableName, onDelete: .setNull)
                t.column("taskType", .text).notNull()

                t.column("providerProfileId", .integer)
                    .references(AgentProviderProfile.databaseTableName, onDelete: .setNull)
                t.column("modelProfileId", .integer)
                    .references(AgentModelProfile.databaseTableName, onDelete: .setNull)

                t.column("providerBaseURLSnapshot", .text).notNull()
                t.column("providerResolvedURLSnapshot", .text)
                t.column("providerResolvedHostSnapshot", .text)
                t.column("providerResolvedPathSnapshot", .text)
                t.column("providerNameSnapshot", .text)
                t.column("modelNameSnapshot", .text).notNull()

                t.column("requestPhase", .text).notNull()
                t.column("requestStatus", .text).notNull()

                t.column("promptTokens", .integer)
                t.column("completionTokens", .integer)
                t.column("totalTokens", .integer)
                t.column("usageAvailability", .text).notNull()

                t.column("startedAt", .datetime)
                t.column("finishedAt", .datetime)
                t.column("createdAt", .datetime).notNull().defaults(to: Date())
            }

            try db.create(index: "idx_llm_usage_created", on: LLMUsageEvent.databaseTableName, columns: ["createdAt"])
            try db.create(index: "idx_llm_usage_task_created", on: LLMUsageEvent.databaseTableName, columns: ["taskType", "createdAt"])
            try db.create(index: "idx_llm_usage_provider_created", on: LLMUsageEvent.databaseTableName, columns: ["providerProfileId", "createdAt"])
            try db.create(index: "idx_llm_usage_model_created", on: LLMUsageEvent.databaseTableName, columns: ["modelProfileId", "createdAt"])
            try db.create(index: "idx_llm_usage_status_created", on: LLMUsageEvent.databaseTableName, columns: ["requestStatus", "createdAt"])
            try db.create(index: "idx_llm_usage_task_run", on: LLMUsageEvent.databaseTableName, columns: ["taskRunId"])
        }

        migrator.registerMigration("createSummaryResult") { db in
            try db.create(table: SummaryResult.databaseTableName) { t in
                t.column("taskRunId", .integer)
                    .notNull()
                    .references(AgentTaskRun.databaseTableName, onDelete: .cascade)
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
                index: "idx_summary_slot",
                on: SummaryResult.databaseTableName,
                columns: ["entryId", "targetLanguage", "detailLevel"],
                unique: true
            )
            try db.create(index: "idx_summary_updated", on: SummaryResult.databaseTableName, columns: ["updatedAt"])
        }

        migrator.registerMigration("createAgentTranslationPayload") { db in
            try db.create(table: TranslationResult.databaseTableName) { t in
                t.column("taskRunId", .integer)
                    .notNull()
                    .references(AgentTaskRun.databaseTableName, onDelete: .cascade)
                t.column("entryId", .integer)
                    .notNull()
                    .indexed()
                    .references(Entry.databaseTableName, onDelete: .cascade)
                t.column("targetLanguage", .text).notNull()
                t.column("sourceContentHash", .text).notNull()
                t.column("segmenterVersion", .text).notNull()
                t.column("outputLanguage", .text).notNull()
                t.column("createdAt", .datetime).notNull().defaults(to: Date())
                t.column("updatedAt", .datetime).notNull().defaults(to: Date())
                t.primaryKey(["taskRunId"])
            }

            try db.create(
                index: "idx_translation_slot",
                on: TranslationResult.databaseTableName,
                columns: ["entryId", "targetLanguage", "sourceContentHash", "segmenterVersion"],
                unique: true
            )
            try db.create(index: "idx_translation_updated", on: TranslationResult.databaseTableName, columns: ["updatedAt"])

            try db.create(table: TranslationSegment.databaseTableName) { t in
                t.column("taskRunId", .integer)
                    .notNull()
                    .indexed()
                    .references(TranslationResult.databaseTableName, onDelete: .cascade)
                t.column("sourceSegmentId", .text).notNull()
                t.column("orderIndex", .integer).notNull()
                t.column("sourceTextSnapshot", .text)
                t.column("translatedText", .text).notNull()
                t.column("createdAt", .datetime).notNull().defaults(to: Date())
                t.column("updatedAt", .datetime).notNull().defaults(to: Date())
            }

            try db.create(
                index: "idx_translation_segment_order",
                on: TranslationSegment.databaseTableName,
                columns: ["taskRunId", "orderIndex"]
            )
            try db.create(
                index: "idx_translation_segment_unique",
                on: TranslationSegment.databaseTableName,
                columns: ["taskRunId", "sourceSegmentId"],
                unique: true
            )
        }

        migrator.registerMigration("addAgentModelLastTestedAt") { db in
            let existingColumns = try db.columns(in: AgentModelProfile.databaseTableName).map(\.name)
            guard existingColumns.contains("lastTestedAt") == false else { return }
            try db.alter(table: AgentModelProfile.databaseTableName) { t in
                t.add(column: "lastTestedAt", .datetime)
            }
        }

        migrator.registerMigration("addAgentArchiveLifecycleFields") { db in
            let providerColumns = try db.columns(in: AgentProviderProfile.databaseTableName).map(\.name)
            if providerColumns.contains("isArchived") == false || providerColumns.contains("archivedAt") == false {
                try db.alter(table: AgentProviderProfile.databaseTableName) { t in
                    if providerColumns.contains("isArchived") == false {
                        t.add(column: "isArchived", .boolean).notNull().defaults(to: false)
                    }
                    if providerColumns.contains("archivedAt") == false {
                        t.add(column: "archivedAt", .datetime)
                    }
                }
            }

            let modelColumns = try db.columns(in: AgentModelProfile.databaseTableName).map(\.name)
            if modelColumns.contains("isArchived") == false || modelColumns.contains("archivedAt") == false {
                try db.alter(table: AgentModelProfile.databaseTableName) { t in
                    if modelColumns.contains("isArchived") == false {
                        t.add(column: "isArchived", .boolean).notNull().defaults(to: false)
                    }
                    if modelColumns.contains("archivedAt") == false {
                        t.add(column: "archivedAt", .datetime)
                    }
                }
            }
        }

        migrator.registerMigration("addTranslationResultStatus") { db in
            let columns = try db.columns(in: TranslationResult.databaseTableName).map(\.name)
            guard columns.contains("runStatus") == false else { return }
            try db.alter(table: TranslationResult.databaseTableName) { t in
                t.add(column: "runStatus", .text).notNull().defaults(to: TranslationResultRunStatus.succeeded.rawValue)
            }
        }

        migrator.registerMigration("addEntryIsStarred") { db in
            let columns = try db.columns(in: Entry.databaseTableName).map(\.name)
            if columns.contains("isStarred") == false {
                try db.alter(table: Entry.databaseTableName) { t in
                    t.add(column: "isStarred", .boolean).notNull().defaults(to: false)
                }
            }

            try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_entry_starred_published_created
            ON entry (publishedAt DESC, createdAt DESC)
            WHERE isStarred = 1
            """)
        }

        migrator.registerMigration("createTags") { db in
            try db.create(table: Tag.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("normalizedName", .text).notNull()
                t.column("isProvisional", .boolean).notNull().defaults(to: true)
                t.column("usageCount", .integer).notNull().defaults(to: 0)
            }
            try db.create(index: "idx_tag_normalized_name", on: Tag.databaseTableName, columns: ["normalizedName"], unique: true)

            try db.create(table: TagAlias.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("tagId", .integer)
                    .notNull()
                    .indexed()
                    .references(Tag.databaseTableName, onDelete: .cascade)
                t.column("alias", .text).notNull()
                t.column("normalizedAlias", .text).notNull()
            }
            try db.create(index: "idx_tag_alias_normalized_alias", on: TagAlias.databaseTableName, columns: ["normalizedAlias"], unique: true)

            try db.create(table: EntryTag.databaseTableName) { t in
                t.column("entryId", .integer)
                    .notNull()
                    .indexed()
                    .references(Entry.databaseTableName, onDelete: .cascade)
                t.column("tagId", .integer)
                    .notNull()
                    .indexed()
                    .references(Tag.databaseTableName, onDelete: .cascade)
                t.column("source", .text).notNull()
                t.column("confidence", .double)
                t.primaryKey(["entryId", "tagId"])
            }
            try db.create(index: "idx_entry_tag_tag_entry", on: EntryTag.databaseTableName, columns: ["tagId", "entryId"])
        }

        migrator.registerMigration("dropFeedUnreadCount") { db in
            let columns = try db.columns(in: Feed.databaseTableName).map(\.name)
            guard columns.contains("unreadCount") else { return }
            try db.execute(sql: "ALTER TABLE feed DROP COLUMN unreadCount")
        }

        migrator.registerMigration("createTagBatchStagingTables") { db in
            try db.create(table: TagBatchRun.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("status", .text).notNull().defaults(to: TagBatchRunStatus.configure.rawValue)
                t.column("scopeLabel", .text).notNull()
                t.column("skipAlreadyApplied", .boolean).notNull().defaults(to: true)
                t.column("skipAlreadyTagged", .boolean).notNull().defaults(to: true)
                t.column("concurrency", .integer).notNull().defaults(to: 3)
                t.column("totalSelectedEntries", .integer).notNull().defaults(to: 0)
                t.column("totalPlannedEntries", .integer).notNull().defaults(to: 0)
                t.column("processedEntries", .integer).notNull().defaults(to: 0)
                t.column("succeededEntries", .integer).notNull().defaults(to: 0)
                t.column("failedEntries", .integer).notNull().defaults(to: 0)
                t.column("keptProposalCount", .integer).notNull().defaults(to: 0)
                t.column("discardedProposalCount", .integer).notNull().defaults(to: 0)
                t.column("insertedEntryTagCount", .integer).notNull().defaults(to: 0)
                t.column("createdTagCount", .integer).notNull().defaults(to: 0)
                t.column("startedAt", .datetime)
                t.column("completedAt", .datetime)
                t.column("createdAt", .datetime).notNull().defaults(to: Date())
                t.column("updatedAt", .datetime).notNull().defaults(to: Date())
            }
            try db.create(index: "idx_tag_batch_run_status_updated", on: TagBatchRun.databaseTableName, columns: ["status", "updatedAt"])
            try db.create(index: "idx_tag_batch_run_created", on: TagBatchRun.databaseTableName, columns: ["createdAt"])

            try db.create(table: TagBatchEntry.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("runId", .integer)
                    .notNull()
                    .indexed()
                    .references(TagBatchRun.databaseTableName, onDelete: .cascade)
                t.column("entryId", .integer)
                    .notNull()
                    .indexed()
                    .references(Entry.databaseTableName, onDelete: .cascade)
                t.column("lifecycleState", .text).notNull().defaults(to: TagBatchEntryLifecycleState.neverStarted.rawValue)
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("providerProfileId", .integer)
                    .references(AgentProviderProfile.databaseTableName, onDelete: .setNull)
                t.column("modelProfileId", .integer)
                    .references(AgentModelProfile.databaseTableName, onDelete: .setNull)
                t.column("promptTokens", .integer)
                t.column("completionTokens", .integer)
                t.column("durationMs", .integer)
                t.column("rawResponse", .text)
                t.column("errorMessage", .text)
                t.column("createdAt", .datetime).notNull().defaults(to: Date())
                t.column("updatedAt", .datetime).notNull().defaults(to: Date())
            }
            try db.create(index: "idx_tag_batch_entry_run_state", on: TagBatchEntry.databaseTableName, columns: ["runId", "lifecycleState"])
            try db.create(index: "idx_tag_batch_entry_run_entry", on: TagBatchEntry.databaseTableName, columns: ["runId", "entryId"], unique: true)

            try db.create(table: TagBatchAssignmentStaging.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("runId", .integer)
                    .notNull()
                    .indexed()
                    .references(TagBatchRun.databaseTableName, onDelete: .cascade)
                t.column("entryId", .integer)
                    .notNull()
                    .indexed()
                    .references(Entry.databaseTableName, onDelete: .cascade)
                t.column("normalizedName", .text).notNull()
                t.column("displayName", .text).notNull()
                t.column("resolvedTagId", .integer)
                    .references(Tag.databaseTableName, onDelete: .setNull)
                t.column("assignmentKind", .text).notNull()
                t.column("createdAt", .datetime).notNull().defaults(to: Date())
                t.column("updatedAt", .datetime).notNull().defaults(to: Date())
            }
            try db.create(index: "idx_tag_batch_assignment_run_entry", on: TagBatchAssignmentStaging.databaseTableName, columns: ["runId", "entryId"])
            try db.create(index: "idx_tag_batch_assignment_run_name", on: TagBatchAssignmentStaging.databaseTableName, columns: ["runId", "normalizedName"])
            try db.create(
                index: "idx_tag_batch_assignment_unique",
                on: TagBatchAssignmentStaging.databaseTableName,
                columns: ["runId", "entryId", "normalizedName"],
                unique: true
            )

            try db.create(table: TagBatchNewTagReview.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("runId", .integer)
                    .notNull()
                    .indexed()
                    .references(TagBatchRun.databaseTableName, onDelete: .cascade)
                t.column("normalizedName", .text).notNull()
                t.column("displayName", .text).notNull()
                t.column("hitCount", .integer).notNull().defaults(to: 0)
                t.column("sampleEntryCount", .integer).notNull().defaults(to: 0)
                t.column("decision", .text).notNull().defaults(to: TagBatchReviewDecision.pending.rawValue)
                t.column("createdAt", .datetime).notNull().defaults(to: Date())
                t.column("updatedAt", .datetime).notNull().defaults(to: Date())
            }
            try db.create(index: "idx_tag_batch_review_run_decision", on: TagBatchNewTagReview.databaseTableName, columns: ["runId", "decision"])
            try db.create(index: "idx_tag_batch_review_run_name", on: TagBatchNewTagReview.databaseTableName, columns: ["runId", "normalizedName"], unique: true)

            try db.create(table: TagBatchApplyCheckpoint.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("runId", .integer)
                    .notNull()
                    .indexed()
                    .references(TagBatchRun.databaseTableName, onDelete: .cascade)
                t.column("lastAppliedChunkIndex", .integer).notNull().defaults(to: 0)
                t.column("totalChunks", .integer).notNull().defaults(to: 0)
                t.column("lastAppliedEntryId", .integer)
                t.column("updatedAt", .datetime).notNull().defaults(to: Date())
            }
            try db.create(index: "idx_tag_batch_checkpoint_run", on: TagBatchApplyCheckpoint.databaseTableName, columns: ["runId"], unique: true)
        }

        migrator.registerMigration("addTagBatchRunSkipAlreadyTagged") { db in
            let columns = try db.columns(in: TagBatchRun.databaseTableName).map(\.name)
            guard columns.contains("skipAlreadyTagged") == false else { return }
            try db.alter(table: TagBatchRun.databaseTableName) { t in
                t.add(column: "skipAlreadyTagged", .boolean).notNull().defaults(to: true)
            }
        }

        // MARK: - Dev-only cleanup migrations
        // These migrations exist to clean up data produced during development.
        // They are compiled only in DEBUG builds and must be removed before the 1.0 release.
#if DEBUG
        migrator.registerMigration("purgeRSSImportedTags") { db in
            // Decrement usageCount for each tag by the number of rss-sourced entry_tag rows
            // that are about to be deleted.
            try db.execute(sql: """
                UPDATE tag
                SET usageCount = MAX(0, usageCount - (
                    SELECT COUNT(*) FROM entry_tag WHERE tagId = tag.id AND source = 'rss'
                ))
                WHERE id IN (SELECT DISTINCT tagId FROM entry_tag WHERE source = 'rss')
                """)

            // Remove all rss-sourced tag assignments.
            try db.execute(sql: "DELETE FROM entry_tag WHERE source = 'rss'")

            // Re-evaluate provisional status based on updated usageCount.
            try db.execute(sql: "UPDATE tag SET isProvisional = 1 WHERE usageCount < 2")
            try db.execute(sql: "UPDATE tag SET isProvisional = 0 WHERE usageCount >= 2")

            // Remove tags that are now unreferenced (usageCount = 0 with no remaining entry_tag rows).
            // The tag_alias table will cascade-delete via foreign key.
            try db.execute(sql: """
                DELETE FROM tag
                WHERE usageCount <= 0
                  AND id NOT IN (SELECT DISTINCT tagId FROM entry_tag)
                """)
        }
#endif

        return migrator
    }
}
