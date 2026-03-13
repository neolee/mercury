import Foundation
import Testing
@testable import Mercury

@Suite("Tag Batch Event Stream", .serialized)
struct TagBatchEventStreamTests {
    @Test("Entering review broadcasts a review transition")
    @MainActor
    func enterReviewBroadcastsTransition() async throws {
        try await AppModelTestHarness.withInMemory(
            credentialStore: TagBatchEventTestCredentialStore()
        ) { harness in
            let appModel = harness.appModel
            let runId = try await insertRun(database: harness.database, status: .readyNext)

            let eventsTask = await recordEvents(from: appModel)
            try await appModel.enterTaggingBatchReview(runId: runId)
            let events = await finishRecording(eventsTask)

            #expect(events.contains(.transitioned(runId: runId, status: .review)))
        }
    }

    @Test("Discarding a run broadcasts a cancelled transition")
    @MainActor
    func discardBroadcastsCancelledTransition() async throws {
        try await AppModelTestHarness.withInMemory(
            credentialStore: TagBatchEventTestCredentialStore()
        ) { harness in
            let appModel = harness.appModel
            let runId = try await insertRun(database: harness.database, status: .review)

            let eventsTask = await recordEvents(from: appModel)
            try await appModel.discardTaggingBatchRun(runId: runId)
            let events = await finishRecording(eventsTask)

            #expect(events.contains(.transitioned(runId: runId, status: .cancelled)))
        }
    }

    @Test("Applying a trivial run broadcasts applying then done")
    @MainActor
    func applyBroadcastsLifecycleTransitions() async throws {
        try await AppModelTestHarness.withInMemory(
            credentialStore: TagBatchEventTestCredentialStore()
        ) { harness in
            let appModel = harness.appModel
            let runId = try await insertRun(database: harness.database, status: .readyNext)

            let eventsTask = await recordEvents(from: appModel)
            try await appModel.applyTaggingBatchRun(runId: runId) { _ in }
            let events = await finishRecording(eventsTask)

            #expect(events.contains(.transitioned(runId: runId, status: .applying)))
            #expect(events.contains(.transitioned(runId: runId, status: .done)))
            #expect(events.contains(.terminal(.succeeded)))
        }
    }

    @Test("Done transition restores persisted completion counts before alert state")
    @MainActor
    func doneTransitionRestoresCompletionCountsBeforeAlertState() async throws {
        try await AppModelTestHarness.withInMemory(
            credentialStore: TagBatchEventTestCredentialStore()
        ) { harness in
            let appModel = harness.appModel
            let store = TagBatchStore(db: harness.database)
            let runId = try await insertRun(database: harness.database, status: .applying)
            try await store.updateRunCounters(
                runId: runId,
                processedEntries: 15,
                succeededEntries: 15,
                failedEntries: 0
            )
            try await store.finalizeRunAfterApply(
                runId: runId,
                keptProposalCount: 4,
                discardedProposalCount: 4,
                insertedEntryTagCount: 25,
                createdTagCount: 4
            )

            let viewModel = BatchTaggingSheetViewModel()
            await viewModel.bindIfNeeded(appModel: appModel)

            await viewModel.handle(event: .transitioned(runId: runId, status: .done))

            #expect(viewModel.completedRunIDForAlert == runId)
            #expect(viewModel.processedCount == 15)
            #expect(viewModel.succeededCount == 15)
            #expect(viewModel.failedCount == 0)
            #expect(viewModel.insertedEntryTagCount == 25)
            #expect(viewModel.createdTagCount == 4)
            #expect(viewModel.keptProposalCount == 4)
            #expect(viewModel.discardedProposalCount == 4)
        }
    }

    @Test("Prompt fallback notice maps to shared footer projected message")
    @MainActor
    func promptFallbackNoticeMapsToSharedFooterMessage() async throws {
        let viewModel = BatchTaggingSheetViewModel()

        await viewModel.handle(event: .notice(.promptTemplateFallback))

        #expect(
            viewModel.footerMessage == AgentRuntimeProjection.taggingBatchNoticeProjectedMessage(.promptTemplateFallback)
        )
    }

    @Test("Terminal failure maps to shared footer projected message")
    @MainActor
    func terminalFailureMapsToSharedFooterMessage() async throws {
        let viewModel = BatchTaggingSheetViewModel()

        await viewModel.handle(event: .terminal(.failed(failureReason: .storage, message: "db write failed")))

        #expect(
            viewModel.footerMessage == AgentRuntimeProjection.taggingBatchFailureProjectedMessage(reason: .storage)
        )
    }

    @MainActor
    private func recordEvents(from appModel: AppModel) async -> Task<[TagBatchRunEvent], Never> {
        let stream = await appModel.tagBatchRunEvents()
        return Task {
            var events: [TagBatchRunEvent] = []
            for await event in stream {
                events.append(event)
                // Self-terminate on terminal events so the task completes naturally
                // before finishRecording cancels it, avoiding the race where
                // isCancelled is checked after the event is already received but
                // before it would have been appended.
                if case .terminal = event { break }
                if Task.isCancelled { break }
            }
            return events
        }
    }

    @MainActor
    private func finishRecording(_ task: Task<[TagBatchRunEvent], Never>) async -> [TagBatchRunEvent] {
        await Task.yield()
        await Task.yield()
        task.cancel()
        return await task.value
    }

    private func insertRun(database: DatabaseManager, status: TagBatchRunStatus) async throws -> Int64 {
        let store = await TagBatchStore(db: database)
        let runId = try await store.createRun(
            scopeLabel: "all_entries",
            skipAlreadyApplied: true,
            skipAlreadyTagged: true,
            concurrency: 3,
            totalSelectedEntries: 1,
            totalPlannedEntries: 1
        )
        try await store.updateRunStatus(runId: runId, status: status)
        return runId
    }
}

private final class TagBatchEventTestCredentialStore: CredentialStore, @unchecked Sendable {
    func save(secret: String, for ref: String) throws {
    }

    func readSecret(for ref: String) throws -> String {
        throw CredentialStoreError.itemNotFound
    }

    func deleteSecret(for ref: String) throws {
    }
}
