import Foundation
import GRDB
import Testing
@testable import Mercury

@Suite("LLM Usage Event Persistence")
struct LLMUsageEventPersistenceTests {
    @Test("Record preserves major fields and usage availability")
    @MainActor
    func recordPreservesMajorFields() async throws {
        let dbPath = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let database = try DatabaseManager(path: dbPath)
        let entryId = try await seedEntry(using: database)

        let startedAt = Date().addingTimeInterval(-2)
        let finishedAt = Date().addingTimeInterval(-1)
        let context = LLMUsageEventContext(
            taskRunId: nil,
            entryId: entryId,
            taskType: .summary,
            providerProfileId: nil,
            modelProfileId: nil,
            providerBaseURLSnapshot: "https://example.com/v1",
            providerResolvedURLSnapshot: "https://example.com/v1/chat/completions",
            providerResolvedHostSnapshot: "example.com",
            providerResolvedPathSnapshot: "/v1/chat/completions",
            providerNameSnapshot: "Test Provider",
            modelNameSnapshot: "test-model",
            requestPhase: .normal,
            requestStatus: .succeeded,
            promptTokens: 12,
            completionTokens: 34,
            startedAt: startedAt,
            finishedAt: finishedAt
        )

        try await recordLLMUsageEvent(database: database, context: context)

        let row = try await database.read { db in
            try LLMUsageEvent
                .order(Column("id").desc)
                .fetchOne(db)
        }

        #expect(row != nil)
        #expect(row?.entryId == entryId)
        #expect(row?.taskType == .summary)
        #expect(row?.providerBaseURLSnapshot == "https://example.com/v1")
        #expect(row?.providerResolvedURLSnapshot == "https://example.com/v1/chat/completions")
        #expect(row?.providerResolvedHostSnapshot == "example.com")
        #expect(row?.providerResolvedPathSnapshot == "/v1/chat/completions")
        #expect(row?.providerNameSnapshot == "Test Provider")
        #expect(row?.modelNameSnapshot == "test-model")
        #expect(row?.requestPhase == .normal)
        #expect(row?.requestStatus == .succeeded)
        #expect(row?.promptTokens == 12)
        #expect(row?.completionTokens == 34)
        #expect(row?.totalTokens == 46)
        #expect(row?.usageAvailability == .actual)
        #expect(row?.taskRunId == nil)
    }

    @Test("Multiple request events for one run are all recorded and linked")
    @MainActor
    func multipleRequestsAreRecordedAndLinkedToRun() async throws {
        let dbPath = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let database = try DatabaseManager(path: dbPath)
        let entryId = try await seedEntry(using: database)

        let windowStart = Date().addingTimeInterval(-10)

        try await recordLLMUsageEvent(
            database: database,
            context: LLMUsageEventContext(
                taskRunId: nil,
                entryId: entryId,
                taskType: .translation,
                providerProfileId: nil,
                modelProfileId: nil,
                providerBaseURLSnapshot: "https://api.test/v1",
                providerResolvedURLSnapshot: "https://api.test/v1/chat/completions",
                providerResolvedHostSnapshot: "api.test",
                providerResolvedPathSnapshot: "/v1/chat/completions",
                providerNameSnapshot: "Provider A",
                modelNameSnapshot: "model-a",
                requestPhase: .normal,
                requestStatus: .succeeded,
                promptTokens: 10,
                completionTokens: 20,
                startedAt: Date().addingTimeInterval(-8),
                finishedAt: Date().addingTimeInterval(-7)
            )
        )

        try await recordLLMUsageEvent(
            database: database,
            context: LLMUsageEventContext(
                taskRunId: nil,
                entryId: entryId,
                taskType: .translation,
                providerProfileId: nil,
                modelProfileId: nil,
                providerBaseURLSnapshot: "https://api.test/v1",
                providerResolvedURLSnapshot: "https://api.test/v1/chat/completions",
                providerResolvedHostSnapshot: "api.test",
                providerResolvedPathSnapshot: "/v1/chat/completions",
                providerNameSnapshot: "Provider A",
                modelNameSnapshot: "model-a",
                requestPhase: .repair,
                requestStatus: .succeeded,
                promptTokens: 4,
                completionTokens: 6,
                startedAt: Date().addingTimeInterval(-6),
                finishedAt: Date().addingTimeInterval(-5)
            )
        )

        let runID = try await recordAgentTerminalRun(
            database: database,
            entryId: entryId,
            taskType: .translation,
            status: .succeeded,
            context: AgentTerminalRunContext(
                providerProfileId: nil,
                modelProfileId: nil,
                templateId: "translation.default",
                templateVersion: "v1",
                runtimeSnapshot: ["reason": "test"]
            ),
            targetLanguage: "en",
            durationMs: 123
        )

        try await linkRecentUsageEventsToTaskRun(
            database: database,
            taskRunId: runID,
            entryId: entryId,
            taskType: .translation,
            startedAt: windowStart,
            finishedAt: Date()
        )

        let rows = try await database.read { db in
            try LLMUsageEvent
                .filter(Column("entryId") == entryId)
                .filter(Column("taskType") == AgentTaskType.translation.rawValue)
                .order(Column("id").asc)
                .fetchAll(db)
        }

        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.taskRunId == runID })
        #expect(rows.map(\.requestPhase) == [.normal, .repair])
        #expect(rows.map(\.requestStatus) == [.succeeded, .succeeded])
        #expect(rows.map(\.totalTokens) == [30, 10])
        #expect(rows.map(\.usageAvailability) == [.actual, .actual])
    }

    private func seedEntry(using database: DatabaseManager) async throws -> Int64 {
        try await database.write { db in
            var feed = Feed(
                id: nil,
                title: "Usage Test Feed",
                feedURL: "https://example.com/feed-\(UUID().uuidString)",
                siteURL: "https://example.com",
                unreadCount: 0,
                lastFetchedAt: nil,
                createdAt: Date()
            )
            try feed.insert(db)
            guard let feedId = feed.id else {
                throw UsageEventTestError.missingFeedID
            }

            var entry = Entry(
                id: nil,
                feedId: feedId,
                guid: "usage-guid-\(UUID().uuidString)",
                url: "https://example.com/item",
                title: "Usage Entry",
                author: "tester",
                publishedAt: Date(),
                summary: "Summary",
                isRead: false,
                createdAt: Date()
            )
            try entry.insert(db)
            guard let entryId = entry.id else {
                throw UsageEventTestError.missingEntryID
            }
            return entryId
        }
    }

    private func temporaryDatabasePath() -> String {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mercury-usage-event-tests-\(UUID().uuidString).sqlite")
            .path
    }
}

private enum UsageEventTestError: Error {
    case missingFeedID
    case missingEntryID
}
