import Foundation
import GRDB
import Testing
@testable import Mercury

@Suite("Usage Report Query")
struct UsageReportQueryTests {
    @Test("Provider report returns fixed-window buckets, summary, quality and period deltas")
    @MainActor
    func providerReportComputesExpectedMetrics() async throws {
        let dbPath = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let appModel = AppModel(
            databaseManager: try DatabaseManager(path: dbPath),
            credentialStore: InMemoryCredentialStoreForUsageReportTests()
        )

        let providerId = try await seedProvider(using: appModel.database)
        let entryId = try await seedEntry(using: appModel.database)

        let now = Date()
        try await insertUsageRow(
            database: appModel.database,
            providerId: providerId,
            entryId: entryId,
            createdAt: now.addingTimeInterval(-1 * 24 * 60 * 60),
            requestStatus: .succeeded,
            usageAvailability: .actual,
            promptTokens: 10,
            completionTokens: 20,
            totalTokens: 30
        )
        try await insertUsageRow(
            database: appModel.database,
            providerId: providerId,
            entryId: entryId,
            createdAt: now.addingTimeInterval(-2 * 24 * 60 * 60),
            requestStatus: .failed,
            usageAvailability: .missing,
            promptTokens: nil,
            completionTokens: nil,
            totalTokens: nil
        )
        try await insertUsageRow(
            database: appModel.database,
            providerId: providerId,
            entryId: entryId,
            createdAt: now.addingTimeInterval(-3 * 24 * 60 * 60),
            requestStatus: .succeeded,
            usageAvailability: .actual,
            promptTokens: 5,
            completionTokens: 5,
            totalTokens: 10
        )

        try await insertUsageRow(
            database: appModel.database,
            providerId: providerId,
            entryId: entryId,
            createdAt: now.addingTimeInterval(-8 * 24 * 60 * 60),
            requestStatus: .succeeded,
            usageAvailability: .actual,
            promptTokens: 4,
            completionTokens: 6,
            totalTokens: 10
        )

        let snapshot = try await appModel.fetchProviderUsageReport(
            providerId: providerId,
            windowPreset: .last1Week,
            referenceDate: now
        )

        #expect(snapshot.dailyBuckets.count == 7)
        #expect(snapshot.summary.promptTokens == 15)
        #expect(snapshot.summary.completionTokens == 25)
        #expect(snapshot.summary.totalTokens == 40)
        #expect(snapshot.summary.requestCount == 3)
        #expect(snapshot.summary.succeededCount == 2)
        #expect(snapshot.summary.failedCount == 1)
        #expect(snapshot.summary.missingUsageCount == 1)

        #expect(abs(snapshot.quality.successRate - (2.0 / 3.0)) < 0.0001)
        #expect(abs(snapshot.quality.usageCoverageRate - (2.0 / 3.0)) < 0.0001)
        #expect(abs(snapshot.quality.averageTokensPerRequest - (40.0 / 3.0)) < 0.0001)

        #expect(abs(snapshot.periodComparison.totalTokens.delta - 30.0) < 0.0001)
        #expect(abs(snapshot.periodComparison.totalTokens.deltaRatio! - 3.0) < 0.0001)
        #expect(abs(snapshot.periodComparison.requestCount.delta - 2.0) < 0.0001)
        #expect(abs(snapshot.periodComparison.requestCount.deltaRatio! - 2.0) < 0.0001)
    }

    @Test("Provider report returns zero summary for empty window")
    @MainActor
    func providerReportHandlesEmptyWindow() async throws {
        let dbPath = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let appModel = AppModel(
            databaseManager: try DatabaseManager(path: dbPath),
            credentialStore: InMemoryCredentialStoreForUsageReportTests()
        )

        let providerId = try await seedProvider(using: appModel.database)
        let snapshot = try await appModel.fetchProviderUsageReport(
            providerId: providerId,
            windowPreset: .last2Weeks,
            referenceDate: Date()
        )

        #expect(snapshot.dailyBuckets.count == 14)
        #expect(snapshot.summary.requestCount == 0)
        #expect(snapshot.summary.totalTokens == 0)
        #expect(snapshot.quality.successRate == 0)
        #expect(snapshot.quality.usageCoverageRate == 0)
        #expect(snapshot.quality.averageTokensPerRequest == 0)
    }

    private func temporaryDatabasePath() -> String {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mercury-usage-report-tests-\(UUID().uuidString).sqlite")
            .path
    }

    private func seedProvider(using database: DatabaseManager) async throws -> Int64 {
        try await database.write { db in
            var provider = AgentProviderProfile(
                id: nil,
                name: "Provider \(UUID().uuidString)",
                baseURL: "https://example.com/v1",
                apiKeyRef: "key-ref",
                testModel: "model",
                isDefault: true,
                isEnabled: true,
                isArchived: false,
                archivedAt: nil,
                createdAt: Date(),
                updatedAt: Date()
            )
            try provider.insert(db)
            guard let providerId = provider.id else {
                throw UsageReportTestError.missingProviderID
            }
            return providerId
        }
    }

    private func seedEntry(using database: DatabaseManager) async throws -> Int64 {
        try await database.write { db in
            var feed = Feed(
                id: nil,
                title: "Usage Report Test Feed",
                feedURL: "https://example.com/feed-\(UUID().uuidString)",
                siteURL: "https://example.com",
                unreadCount: 0,
                lastFetchedAt: nil,
                createdAt: Date()
            )
            try feed.insert(db)
            guard let feedId = feed.id else {
                throw UsageReportTestError.missingFeedID
            }

            var entry = Entry(
                id: nil,
                feedId: feedId,
                guid: "usage-report-guid-\(UUID().uuidString)",
                url: "https://example.com/item",
                title: "Usage Report Entry",
                author: "tester",
                publishedAt: Date(),
                summary: "Summary",
                isRead: false,
                createdAt: Date()
            )
            try entry.insert(db)
            guard let entryId = entry.id else {
                throw UsageReportTestError.missingEntryID
            }
            return entryId
        }
    }

    private func insertUsageRow(
        database: DatabaseManager,
        providerId: Int64,
        entryId: Int64,
        createdAt: Date,
        requestStatus: LLMUsageRequestStatus,
        usageAvailability: LLMUsageAvailability,
        promptTokens: Int?,
        completionTokens: Int?,
        totalTokens: Int?
    ) async throws {
        try await database.write { db in
            var row = LLMUsageEvent(
                id: nil,
                taskRunId: nil,
                entryId: entryId,
                taskType: .summary,
                providerProfileId: providerId,
                modelProfileId: nil,
                providerBaseURLSnapshot: "https://example.com/v1",
                providerResolvedURLSnapshot: "https://example.com/v1/chat/completions",
                providerResolvedHostSnapshot: "example.com",
                providerResolvedPathSnapshot: "/v1/chat/completions",
                providerNameSnapshot: "Provider",
                modelNameSnapshot: "model",
                requestPhase: .normal,
                requestStatus: requestStatus,
                promptTokens: promptTokens,
                completionTokens: completionTokens,
                totalTokens: totalTokens,
                usageAvailability: usageAvailability,
                startedAt: createdAt,
                finishedAt: createdAt,
                createdAt: createdAt
            )
            try row.insert(db)
        }
    }
}

private enum UsageReportTestError: Error {
    case missingProviderID
    case missingFeedID
    case missingEntryID
}

private final class InMemoryCredentialStoreForUsageReportTests: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    func save(secret: String, for ref: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[ref] = secret
    }

    func readSecret(for ref: String) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        if let value = storage[ref] {
            return value
        }
        throw CredentialStoreError.itemNotFound
    }

    func deleteSecret(for ref: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: ref)
    }
}
