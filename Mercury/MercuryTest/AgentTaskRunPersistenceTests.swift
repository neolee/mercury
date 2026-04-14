import Foundation
import GRDB
import Testing
@testable import Mercury

@Suite("Agent Task Run Persistence")
@MainActor
struct AgentTaskRunPersistenceTests {
    @Test("Terminal run recording preserves agent profile linkage")
    func recordAgentTerminalRunPreservesAgentProfileLinkage() async throws {
        try await InMemoryDatabaseFixture.withFixture { fixture in
            let database = fixture.database
            let entryId = try await seedEntry(in: database)
            let agentProfileId = try await seedAgentProfile(in: database, agentType: .tagging)

            let runId = try await recordAgentTerminalRun(
                database: database,
                entryId: entryId,
                taskType: .tagging,
                status: .failed,
                context: AgentTerminalRunContext(
                    agentProfileId: agentProfileId,
                    providerProfileId: nil,
                    modelProfileId: nil,
                    templateId: "tagging.default",
                    templateVersion: "v2",
                    runtimeSnapshot: ["reason": "test"]
                ),
                targetLanguage: "",
                durationMs: 10
            )

            let run = try await database.read { db in
                try AgentTaskRun
                    .filter(Column("id") == runId)
                    .fetchOne(db)
            }

            #expect(run?.agentProfileId == agentProfileId)
        }
    }
}

private func seedEntry(in database: DatabaseManager) async throws -> Int64 {
    try await database.write { db in
        var feed = Feed(
            id: nil,
            title: "Run Persistence Feed",
            feedURL: "https://example.com/run-persistence-\(UUID().uuidString)",
            siteURL: "https://example.com",
            lastFetchedAt: nil,
            createdAt: Date()
        )
        try feed.insert(db)
        let feedId = try #require(feed.id)

        var entry = Entry(
            id: nil,
            feedId: feedId,
            guid: UUID().uuidString,
            url: "https://example.com/run-persistence-entry",
            title: "Run Persistence Entry",
            author: "tester",
            publishedAt: Date(),
            summary: "summary",
            isRead: false,
            createdAt: Date()
        )
        try entry.insert(db)
        return try #require(entry.id)
    }
}

private func seedAgentProfile(
    in database: DatabaseManager,
    agentType: AgentType
) async throws -> Int64 {
    try await database.write { db in
        var profile = AgentProfile(
            id: nil,
            agentType: agentType,
            primaryModelProfileId: nil,
            fallbackModelProfileId: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
        try profile.insert(db)
        return try #require(profile.id)
    }
}
