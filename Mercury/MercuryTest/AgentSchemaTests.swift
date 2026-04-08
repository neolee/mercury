import Foundation
import GRDB
import Testing
@testable import Mercury

@Suite("Agent Schema")
struct AgentSchemaTests {
    @Test("Migration produces the final agent profile route schema")
    @MainActor
    func migrationProducesFinalAgentProfileSchema() async throws {
        try await InMemoryDatabaseFixture.withFixture { fixture in
            try fixture.database.dbQueue.write { db in
                #expect(try db.tableExists(AgentProfile.databaseTableName))
                #expect(try db.tableExists("agent_task_routing") == false)

                try assertFinalAgentProfileSchema(in: db)
                try assertAgentProfileAgentTypeIsUnique(in: db)
            }
        }
    }

    @Test("Migration upgrades legacy agent profile schema and removes routing table")
    func migrationUpgradesLegacyAgentProfileSchema() throws {
        let dbQueue = try makeMigrationQueue()
        let migrator = DatabaseManager.makeMigrator()
        var expectedModelID: Int64 = 0

        try migrator.migrate(dbQueue, upTo: legacySchemaLastMigration)

        try dbQueue.write { db in
            #expect(try db.tableExists(AgentProfile.databaseTableName))
            #expect(try db.tableExists("agent_task_routing"))

            let legacyColumns = Set(try db.columns(in: AgentProfile.databaseTableName).map(\.name))
            #expect(legacyColumns.contains("defaultModelProfileId"))
            #expect(legacyColumns.contains("name"))
            #expect(legacyColumns.contains("systemPrompt"))
            #expect(legacyColumns.contains("outputStyle"))
            #expect(legacyColumns.contains("isEnabled"))

            try db.execute(
                sql: """
                    INSERT INTO agent_provider_profile (name, baseURL, apiKeyRef)
                    VALUES (?, ?, ?)
                    """,
                arguments: ["Provider", "http://localhost:5810/v1", "provider.ref"]
            )
            let providerID = db.lastInsertedRowID

            try db.execute(
                sql: """
                    INSERT INTO agent_model_profile (
                        providerProfileId,
                        name,
                        modelName
                    ) VALUES (?, ?, ?)
                    """,
                arguments: [providerID, "Model", "qwen3"]
            )
            let modelID = db.lastInsertedRowID
            expectedModelID = modelID

            try db.execute(
                sql: """
                    INSERT INTO agent_profile (
                        name,
                        taskType,
                        systemPrompt,
                        defaultModelProfileId
                    ) VALUES (?, ?, ?, ?)
                    """,
                arguments: ["Legacy Summary", AgentTaskType.summary.rawValue, "legacy", modelID]
            )
        }

        try migrator.migrate(dbQueue)

        try dbQueue.read { db in
            #expect(try db.tableExists("agent_task_routing") == false)
            try assertFinalAgentProfileSchema(in: db)

            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT agentType, primaryModelProfileId, fallbackModelProfileId
                    FROM agent_profile
                    WHERE agentType = ?
                    """,
                arguments: [AgentTaskType.summary.rawValue]
            )
            #expect(row != nil)
            #expect(row?["agentType"] as String? == AgentTaskType.summary.rawValue)
            #expect(row?["primaryModelProfileId"] as Int64? == expectedModelID)
            #expect(row?["fallbackModelProfileId"] as Int64? == nil)
        }
    }
}

private let legacySchemaLastMigration = "addContentDocumentBaseURL"

private func makeMigrationQueue() throws -> DatabaseQueue {
    var configuration = Configuration()
    configuration.prepareDatabase { db in
        try db.execute(sql: "PRAGMA foreign_keys = ON")
    }
    return try DatabaseQueue(path: ":memory:", configuration: configuration)
}

private func assertFinalAgentProfileSchema(in db: Database) throws {
    let columns = Set(try db.columns(in: AgentProfile.databaseTableName).map(\.name))
    #expect(columns == Set([
        "id",
        "agentType",
        "primaryModelProfileId",
        "fallbackModelProfileId",
        "createdAt",
        "updatedAt"
    ]))

    let indexNames = Set(try db.indexes(on: AgentProfile.databaseTableName).map(\.name))
    #expect(indexNames.contains("idx_agent_profile_agent_type_unique"))
    #expect(indexNames.contains("idx_agent_profile_name") == false)
    #expect(indexNames.contains("idx_agent_profile_task") == false)
    #expect(indexNames.contains("idx_agent_profile_task_unique") == false)

    let foreignKeys = try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(agent_profile)")
    let foreignKeySummaries = Set(foreignKeys.map { row in
        let source = row["from"] as String
        let targetTable = row["table"] as String
        let targetColumn = row["to"] as String
        let deleteAction = row["on_delete"] as String
        return "\(source):\(targetTable):\(targetColumn):\(deleteAction)"
    })
    #expect(foreignKeySummaries.contains("primaryModelProfileId:agent_model_profile:id:SET NULL"))
    #expect(foreignKeySummaries.contains("fallbackModelProfileId:agent_model_profile:id:SET NULL"))
    #expect(foreignKeySummaries.count == 2)
}

private func assertAgentProfileAgentTypeIsUnique(in db: Database) throws {
    try db.execute(
        sql: "INSERT INTO agent_profile (agentType) VALUES (?)",
        arguments: [AgentTaskType.summary.rawValue]
    )

    do {
        try db.execute(
            sql: "INSERT INTO agent_profile (agentType) VALUES (?)",
            arguments: [AgentTaskType.summary.rawValue]
        )
        Issue.record("Expected duplicate agentType insert to fail due to the unique index.")
    } catch {
    }
}
