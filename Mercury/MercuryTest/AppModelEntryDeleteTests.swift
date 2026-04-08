import Foundation
import GRDB
import Testing
@testable import Mercury

@Suite("AppModel Entry Delete")
struct AppModelEntryDeleteTests {
    @Test("deleteEntry refreshes loaded entries and visible counts")
    @MainActor
    func deleteEntryRefreshesLoadedEntriesAndCounts() async throws {
        try await AppModelTestHarness.withInMemory(
            credentialStore: AppModelEntryDeleteTestCredentialStore()
        ) { harness in
            let appModel = harness.appModel
            let database = harness.database
            let seeded = try await seedEntries(database: database)

            _ = await appModel.entryStore.loadFirstPage(
                query: EntryStore.EntryListQuery(feedId: seeded.feedId, unreadOnly: false)
            )
            await appModel.refreshCounts()

            #expect(appModel.entryStore.entries.map(\.id).contains(seeded.deletedEntryId))
            #expect(appModel.entryCount == 2)

            let didDelete = try await appModel.deleteEntry(entryId: seeded.deletedEntryId)

            #expect(didDelete == true)
            #expect(appModel.entryStore.entries.map(\.id) == [seeded.remainingEntryId])
            #expect(appModel.entryCount == 1)

            let deletedEntry = await appModel.entryStore.loadEntry(id: seeded.deletedEntryId)
            #expect(deletedEntry == nil)
        }
    }

    @Test("deleteEntry cancels entry-scoped runtime and panel tasks before deletion")
    @MainActor
    func deleteEntryCancelsEntryScopedTasks() async throws {
        try await AppModelTestHarness.withInMemory(
            credentialStore: AppModelEntryDeleteTestCredentialStore()
        ) { harness in
            let appModel = harness.appModel
            let database = harness.database
            let seeded = try await seedEntries(database: database)
            let entryId = seeded.deletedEntryId

            let summaryOwner = AgentRunOwner(
                taskKind: .summary,
                entryId: entryId,
                slotKey: "delete-test-summary"
            )
            let summaryTaskId = UUID()
            let submitResult = await appModel.submitAgentTask(
                taskId: summaryTaskId,
                kind: .summary,
                owner: summaryOwner,
                requestSource: .manual
            )
            #expect(submitResult.decision == .startNow)

            let panelTaskId = UUID()
            appModel.activeTaggingPanelTaskIds[entryId] = panelTaskId

            _ = await appModel.enqueueTask(
                taskId: summaryTaskId,
                kind: .summary,
                title: AppTaskKind.summary.displayTitle,
                priority: .userInitiated
            ) { (_: AppTaskExecutionContext) in
                try await withTaskCancellationHandler {
                    while true {
                        try Task.checkCancellation()
                        await Task.yield()
                    }
                } onCancel: {
                }
            }

            _ = await appModel.enqueueTask(
                taskId: panelTaskId,
                kind: .tagging,
                title: AppTaskKind.tagging.displayTitle,
                priority: .userInitiated
            ) { (_: AppTaskExecutionContext) in
                try await withTaskCancellationHandler {
                    while true {
                        try Task.checkCancellation()
                        await Task.yield()
                    }
                } onCancel: {
                }
            }

            await waitForTaskState(appModel.taskCenter, taskId: summaryTaskId, expectedState: .running)
            await waitForTaskState(appModel.taskCenter, taskId: panelTaskId, expectedState: .running)

            let didDelete = try await appModel.deleteEntry(entryId: entryId)

            #expect(didDelete == true)
            #expect(appModel.activeTaggingPanelTaskIds[entryId] == nil)

            await waitForTaskState(appModel.taskCenter, taskId: summaryTaskId, expectedState: .cancelled)
            await waitForTaskState(appModel.taskCenter, taskId: panelTaskId, expectedState: .cancelled)

            let runtimeState = await appModel.agentRuntimeEngine.state(for: summaryOwner)
            #expect(runtimeState?.phase == .cancelled)
        }
    }

    @Test("deleteEntry is blocked before cancellation when batch lifecycle is active")
    @MainActor
    func deleteEntryIsBlockedBeforeCancellationWhenBatchLifecycleIsActive() async throws {
        try await AppModelTestHarness.withInMemory(
            credentialStore: AppModelEntryDeleteTestCredentialStore()
        ) { harness in
            let appModel = harness.appModel
            let database = harness.database
            let seeded = try await seedEntries(database: database)
            let entryId = seeded.deletedEntryId

            let panelTaskId = UUID()
            appModel.activeTaggingPanelTaskIds[entryId] = panelTaskId
            appModel.isTagBatchLifecycleActive = true

            await #expect(throws: EntryDeleteError.blockedByActiveTagBatch) {
                try await appModel.deleteEntry(entryId: entryId)
            }

            #expect(appModel.activeTaggingPanelTaskIds[entryId] == panelTaskId)
            let visibleEntry = await appModel.entryStore.loadEntry(id: entryId)
            #expect(visibleEntry?.id == entryId)
        }
    }
}

private struct AppModelEntryDeleteSeed {
    let feedId: Int64
    let deletedEntryId: Int64
    let remainingEntryId: Int64
}

private func seedEntries(database: DatabaseManager) async throws -> AppModelEntryDeleteSeed {
    try await database.write { db in
        var feed = Feed(
            id: nil,
            title: "Feed",
            feedURL: "https://example.com/feed-\(UUID().uuidString)",
            siteURL: "https://example.com",
            lastFetchedAt: nil,
            createdAt: Date()
        )
        try feed.insert(db)
        let feedId = try #require(feed.id)

        var deletedEntry = Entry(
            id: nil,
            feedId: feedId,
            guid: "delete-\(UUID().uuidString)",
            url: "https://example.com/delete",
            title: "Delete",
            author: nil,
            publishedAt: Date(timeIntervalSince1970: 2_000),
            summary: "Delete",
            isRead: false,
            isStarred: false,
            createdAt: Date(timeIntervalSince1970: 2_000)
        )
        try deletedEntry.insert(db)

        var remainingEntry = Entry(
            id: nil,
            feedId: feedId,
            guid: "keep-\(UUID().uuidString)",
            url: "https://example.com/keep",
            title: "Keep",
            author: nil,
            publishedAt: Date(timeIntervalSince1970: 1_000),
            summary: "Keep",
            isRead: false,
            isStarred: false,
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        try remainingEntry.insert(db)

        return AppModelEntryDeleteSeed(
            feedId: feedId,
            deletedEntryId: try #require(deletedEntry.id),
            remainingEntryId: try #require(remainingEntry.id)
        )
    }
}

@MainActor
private func waitForTaskState(
    _ taskCenter: TaskCenter,
    taskId: UUID,
    expectedState: AppTaskState,
    maxIterations: Int = 1_000
) async {
    for _ in 0..<maxIterations {
        if let currentState = taskCenter.tasks.first(where: { $0.id == taskId })?.state,
           taskStatesMatch(currentState, expectedState) {
            return
        }
        await Task.yield()
    }

    Issue.record("Timed out waiting for task \(taskId) to reach state \(expectedState).")
}

private func taskStatesMatch(_ lhs: AppTaskState, _ rhs: AppTaskState) -> Bool {
    switch (lhs, rhs) {
    case (.queued, .queued),
         (.running, .running),
         (.succeeded, .succeeded),
         (.cancelled, .cancelled):
        return true
    case (.failed(let lhsMessage), .failed(let rhsMessage)),
         (.timedOut(let lhsMessage), .timedOut(let rhsMessage)):
        return lhsMessage == rhsMessage
    default:
        return false
    }
}

private final class AppModelEntryDeleteTestCredentialStore: CredentialStore, @unchecked Sendable {
    func save(secret: String, for ref: String) throws {
    }

    func readSecret(for ref: String) throws -> String {
        throw CredentialStoreError.itemNotFound
    }

    func deleteSecret(for ref: String) throws {
    }
}
