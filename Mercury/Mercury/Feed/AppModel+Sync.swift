//
//  AppModel+Sync.swift
//  Mercury
//

import Foundation
import GRDB

actor FeedTaskProjection {
    weak var appModel: AppModel?

    init(appModel: AppModel) {
        self.appModel = appModel
    }

    func beginSyncState() async {
        guard let appModel else { return }
        await appModel.beginSyncState()
    }

    func completeBootstrapSuccess() async {
        guard let appModel else { return }
        await appModel.completeBootstrapSuccess()
    }

    func completeBootstrapCancellation() async {
        guard let appModel else { return }
        await appModel.completeBootstrapCancellation()
    }

    func completeBootstrapFailure(_ message: String) async {
        guard let appModel else { return }
        await appModel.completeBootstrapFailure(message)
    }

    func finishSyncStateSuccess() async {
        guard let appModel else { return }
        await appModel.finishSyncStateSuccess()
    }

    func finishSyncStateFailure(_ message: String) async {
        guard let appModel else { return }
        await appModel.finishSyncStateFailure(message)
    }

    func refreshAfterBackgroundMutation() async {
        guard let appModel else { return }
        await appModel.refreshAfterBackgroundMutation()
    }

    func reportFeedSyncFailure(feedId: Int64, error: Error, source: String) async {
        guard let appModel else { return }
        await appModel.reportFeedSyncFailure(feedId: feedId, error: error, source: source)
    }

    func removeFeedAfterPermanentImportFailure(feedId: Int64, source: String, error: Error) async {
        guard let appModel else { return }
        await appModel.removeFeedAfterPermanentImportFailure(feedId: feedId, source: source, error: error)
    }

    func reportSkippedInsecureFeed(feedURL: String, source: String) async {
        guard let appModel else { return }
        await appModel.reportSkippedInsecureFeed(feedURL: feedURL, source: source)
    }

    func reportFeedParserRepairEvent(_ event: FeedParserRepairEvent, source: String) async {
        guard let appModel else { return }
        await appModel.reportFeedParserRepairEvent(event, source: source)
    }

    func releaseReservedFeedSyncIDs(_ feedIds: [Int64]) async {
        guard let appModel else { return }
        await appModel.releaseReservedFeedSyncIDs(feedIds)
    }
}

private struct FeedSyncTaskDependencies: Sendable {
    let useCase: FeedSyncUseCase
    let maxConcurrentFeeds: Int
    let projection: FeedTaskProjection
}

private struct BootstrapTaskDependencies: Sendable {
    let useCase: BootstrapUseCase
    let maxConcurrentFeeds: Int
    let projection: FeedTaskProjection
}

private func runVerifiedFeedSync(
    feedIds: [Int64],
    report: TaskProgressReporter,
    progressStart: Double,
    progressSpan: Double,
    refreshStride: Int,
    continueOnError: Bool = true,
    dependencies: FeedSyncTaskDependencies
) async throws {
    try await dependencies.useCase.syncWithVerify(
        feedIds: feedIds,
        report: report,
        maxConcurrentFeeds: dependencies.maxConcurrentFeeds,
        progressStart: progressStart,
        progressSpan: progressSpan,
        refreshStride: refreshStride,
        continueOnError: continueOnError,
        onError: { feedId, error in
            await dependencies.projection.reportFeedSyncFailure(feedId: feedId, error: error, source: "sync")
        },
        onRepairEvent: { event in
            await dependencies.projection.reportFeedParserRepairEvent(event, source: "sync")
        },
        onRefresh: {
            await dependencies.projection.refreshAfterBackgroundMutation()
        }
    )
}

private func runPlainFeedSync(
    feedIds: [Int64],
    report: TaskProgressReporter,
    progressStart: Double,
    progressSpan: Double,
    refreshStride: Int,
    continueOnError: Bool = true,
    dependencies: FeedSyncTaskDependencies
) async throws {
    try await dependencies.useCase.sync(
        feedIds: feedIds,
        report: report,
        maxConcurrentFeeds: dependencies.maxConcurrentFeeds,
        progressStart: progressStart,
        progressSpan: progressSpan,
        refreshStride: refreshStride,
        continueOnError: continueOnError,
        onError: { feedId, error in
            await dependencies.projection.reportFeedSyncFailure(feedId: feedId, error: error, source: "sync")
        },
        onRefresh: {
            await dependencies.projection.refreshAfterBackgroundMutation()
        }
    )
}

private func withReleasedFeedSyncReservations(
    _ feedIds: [Int64],
    projection: FeedTaskProjection,
    operation: @escaping @Sendable () async throws -> Void
) async throws {
    do {
        try await operation()
        await projection.releaseReservedFeedSyncIDs(feedIds)
    } catch {
        await projection.releaseReservedFeedSyncIDs(feedIds)
        throw error
    }
}

extension AppModel {
    func reportFeedParserRepairEvent(_ event: FeedParserRepairEvent, source: String) {
        let category: DebugIssueCategory = .task

        switch event {
        case .started(let payload):
            reportDebugIssue(
                title: "Feed Entry URL Repair Started",
                detail: feedParserRepairDetailLines(
                    payload: payload,
                    source: source
                ).joined(separator: "\n"),
                category: category
            )
        case .completed(let payload):
            reportDebugIssue(
                title: "Feed Entry URL Repair Completed",
                detail: feedParserRepairDetailLines(
                    payload: payload,
                    source: source
                ).joined(separator: "\n"),
                category: category
            )
        case .skipped(let payload):
            reportDebugIssue(
                title: "Feed Entry URL Repair Skipped",
                detail: feedParserRepairDetailLines(
                    payload: payload,
                    source: source
                ).joined(separator: "\n"),
                category: category
            )
        case .failed(let payload):
            reportDebugIssue(
                title: "Feed Entry URL Repair Failed",
                detail: feedParserRepairDetailLines(
                    payload: payload,
                    source: source
                ).joined(separator: "\n"),
                category: category
            )
        }
    }

    private func feedParserRepairDetailLines(
        payload: FeedParserRepairEventPayload,
        source: String
    ) -> [String] {
        var lines: [String] = [
            "source=\(source)",
            "feedId=\(payload.feedId)",
            "title=\(payload.feedTitle ?? "(unknown)")",
            "feedURL=\(payload.feedURL)",
            "parserVersion=\(payload.parserVersion)",
            "repairCount=\(payload.repairCount)",
            "skippedCount=\(payload.skippedCount)",
            "contentRowsDeleted=\(payload.contentRowsDeleted)",
            "cacheRowsDeleted=\(payload.cacheRowsDeleted)"
        ]

        if let stage = payload.stage {
            lines.append("stage=\(stage)")
        }
        if let errorDescription = payload.errorDescription {
            lines.append("error=\(errorDescription)")
        }

        for (index, sample) in payload.samples.enumerated() {
            lines.append("sample[\(index)].entryId=\(sample.entryId)")
            lines.append("sample[\(index)].guid=\(sample.guid)")
            lines.append("sample[\(index)].oldURL=\(sample.oldURL)")
            lines.append("sample[\(index)].newURL=\(sample.newURL)")
        }

        for (index, sample) in payload.skippedSamples.enumerated() {
            lines.append("skipped[\(index)].entryId=\(sample.entryId)")
            lines.append("skipped[\(index)].guid=\(sample.guid)")
            lines.append("skipped[\(index)].oldURL=\(sample.oldURL)")
            lines.append("skipped[\(index)].newURL=\(sample.newURL)")
            lines.append("skipped[\(index)].reason=\(sample.reason)")
        }

        return lines
    }

    private func diagnosticLines(for error: Error) -> [String] {
        if let diagnosticError = error as? FeedSyncDiagnosticError {
            var lines: [String] = [
                "wrappedError=true",
                "wrappedDescription=\(diagnosticError.underlying.localizedDescription)"
            ]
            lines.append(contentsOf: diagnosticError.diagnostics)

            let underlyingError = diagnosticError.underlying as NSError
            lines.append("underlyingDomain=\(underlyingError.domain)")
            lines.append("underlyingCode=\(underlyingError.code)")

            if let failingURL = underlyingError.userInfo[NSURLErrorFailingURLErrorKey] as? URL {
                lines.append("underlyingFailingURL=\(failingURL.absoluteString)")
            }
            if let nested = underlyingError.userInfo[NSUnderlyingErrorKey] as? NSError {
                lines.append("underlyingNestedDomain=\(nested.domain)")
                lines.append("underlyingNestedCode=\(nested.code)")
                lines.append("underlyingNestedDescription=\(nested.localizedDescription)")
            }

            return lines
        }

        let nsError = error as NSError
        var lines: [String] = [
            "category=\(FailurePolicy.classifyFeedSyncError(error).rawValue)",
            "domain=\(nsError.domain)",
            "code=\(nsError.code)",
            "description=\(nsError.localizedDescription)"
        ]

        if let failingURL = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL {
            lines.append("failingURL=\(failingURL.absoluteString)")
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            lines.append("underlyingDomain=\(underlying.domain)")
            lines.append("underlyingCode=\(underlying.code)")
            lines.append("underlyingDescription=\(underlying.localizedDescription)")
        }

        return lines
    }

    private func feedContextLines(feedId: Int64, source: String) -> [String] {
        let feed = feedStore.feeds.first(where: { $0.id == feedId })
        return [
            "source=\(source)",
            "feedId=\(feedId)",
            "title=\(feed?.title ?? "(unknown)")",
            "feedURL=\(feed?.feedURL ?? "(unknown)")"
        ]
    }

    func reportFeedSyncFailure(feedId: Int64, error: Error, source: String) {
        var lines = feedContextLines(feedId: feedId, source: source)
        lines.append("error=\(error.localizedDescription)")
        lines.append(contentsOf: diagnosticLines(for: error))

        reportDebugIssue(
            title: "Feed Sync Failed",
            detail: lines.joined(separator: "\n"),
            category: .task
        )
    }

    func removeFeedAfterPermanentImportFailure(feedId: Int64, source: String, error: Error) async {
        let contextLines = feedContextLines(feedId: feedId, source: source)

        do {
            try await database.write { db in
                _ = try Feed
                    .filter(Column("id") == feedId)
                    .deleteAll(db)
            }

            await refreshAfterBackgroundMutation()

            var lines = contextLines
            lines.append("action=deleted-after-sync-failure")
            lines.append(contentsOf: diagnosticLines(for: error))

            reportDebugIssue(
                title: "Skipped Unsupported Feed",
                detail: lines.joined(separator: "\n"),
                category: .task
            )
        } catch {
            var lines = contextLines
            lines.append("action=delete-failed")
            lines.append("deleteError=\(error.localizedDescription)")

            reportDebugIssue(
                title: "Skip Unsupported Feed Failed",
                detail: lines.joined(separator: "\n"),
                category: .task
            )
        }
    }

    func reportSkippedInsecureFeed(feedURL: String, source: String) {
        reportDebugIssue(
            title: "Skipped Insecure Feed",
            detail: [
                "source=\(source)",
                "feedURL=\(feedURL)",
                "reason=Only HTTPS feeds are supported"
            ].joined(separator: "\n"),
            category: .task
        )
    }

    func bootstrapIfNeeded() async {
        guard bootstrapState == .idle else { return }
        if hasActiveTask(kind: .bootstrap) {
            return
        }

        bootstrapState = .importing
        let dependencies = BootstrapTaskDependencies(
            useCase: bootstrapUseCase,
            maxConcurrentFeeds: syncFeedConcurrency,
            projection: FeedTaskProjection(appModel: self)
        )
        _ = await enqueueTask(
            kind: .bootstrap,
            title: "Bootstrap",
            priority: .userInitiated,
            dependencies: dependencies
        ) { dependencies, executionContext in
            let report = executionContext.reportProgress

            await dependencies.projection.beginSyncState()
            do {
                try await dependencies.useCase.run(
                    report: report,
                    maxConcurrentFeeds: dependencies.maxConcurrentFeeds,
                    onMutation: {
                        await dependencies.projection.refreshAfterBackgroundMutation()
                    },
                    onSyncError: { feedId, error in
                        await dependencies.projection.reportFeedSyncFailure(
                            feedId: feedId,
                            error: error,
                            source: "bootstrap"
                        )
                        if FailurePolicy.isPermanentUnsupportedFeedError(error) {
                            await dependencies.projection.removeFeedAfterPermanentImportFailure(
                                feedId: feedId,
                                source: "bootstrap",
                                error: error
                            )
                        }
                    },
                    onRepairEvent: { event in
                        await dependencies.projection.reportFeedParserRepairEvent(event, source: "bootstrap")
                    },
                    onSkippedInsecureFeed: { feedURL in
                        await dependencies.projection.reportSkippedInsecureFeed(feedURL: feedURL, source: "bootstrap")
                    }
                )

                await report(1, "Bootstrap completed")
                await dependencies.projection.completeBootstrapSuccess()
            } catch is CancellationError {
                await dependencies.projection.completeBootstrapCancellation()
                throw CancellationError()
            } catch {
                await dependencies.projection.completeBootstrapFailure(error.localizedDescription)
                throw error
            }
        }
    }

    func syncAllFeeds() async {
        if hasActiveTask(kind: .syncAllFeeds) || syncState == .syncing {
            return
        }

        let dependencies = FeedSyncTaskDependencies(
            useCase: feedSyncUseCase,
            maxConcurrentFeeds: syncFeedConcurrency,
            projection: FeedTaskProjection(appModel: self)
        )
        _ = await enqueueTask(
            kind: .syncAllFeeds,
            title: "Sync Feeds",
            priority: .utility,
            dependencies: dependencies
        ) { dependencies, executionContext in
            let report = executionContext.reportProgress

            await dependencies.projection.beginSyncState()
            do {
                let feedIds = try await dependencies.useCase.loadAllFeedIDs()

                if feedIds.isEmpty {
                    await report(1, "No feeds to sync")
                    await dependencies.projection.finishSyncStateSuccess()
                    return
                }

                try await runVerifiedFeedSync(
                    feedIds: feedIds,
                    report: report,
                    progressStart: 0,
                    progressSpan: 1,
                    refreshStride: 5,
                    dependencies: dependencies
                )

                await report(1, "Sync completed")
                await dependencies.projection.finishSyncStateSuccess()
                await dependencies.projection.refreshAfterBackgroundMutation()
            } catch {
                await dependencies.projection.finishSyncStateFailure(error.localizedDescription)
                throw error
            }
        }
    }

    func autoSyncIfNeeded() async {
        guard shouldSyncNow() else { return }
        await syncAllFeeds()
    }

    func shouldSyncNow() -> Bool {
        if syncState == .syncing {
            return false
        }
        if hasActiveTask(kind: .syncAllFeeds) ||
            hasActiveTask(kind: .syncFeeds) ||
            hasActiveTask(kind: .bootstrap) ||
            hasActiveTask(kind: .importOPML) {
            return false
        }
        guard let lastSyncAt else { return true }
        return Date().timeIntervalSince(lastSyncAt) > syncThreshold
    }

    func hasActiveTask(kind: AppTaskKind) -> Bool {
        taskCenter.tasks.contains { task in
            task.kind == kind && task.state.isTerminal == false
        }
    }

    func beginSyncState() {
        syncState = .syncing
    }

    func completeBootstrapSuccess() async {
        finishSyncStateSuccess()
        bootstrapState = .ready
        await refreshAfterBackgroundMutation()
    }

    func completeBootstrapCancellation() {
        syncState = .idle
        bootstrapState = .idle
    }

    func completeBootstrapFailure(_ message: String) {
        finishSyncStateFailure(message)
        bootstrapState = .failed(message)
    }

    func finishSyncStateSuccess() {
        let now = Date()
        lastSyncAt = now
        saveLastSyncAt(now)
        syncState = .idle
    }

    func finishSyncStateFailure(_ message: String) {
        syncState = .failed(message)
    }

    func loadLastSyncAt() -> Date? {
        UserDefaults.standard.object(forKey: lastSyncKey) as? Date
    }

    func saveLastSyncAt(_ date: Date) {
        UserDefaults.standard.set(date, forKey: lastSyncKey)
    }

    func refreshAfterBackgroundMutation() async {
        await feedStore.loadAll()
        await refreshCounts()
        backgroundDataVersion &+= 1
    }

    func enqueueFeedSync(
        feedIds: [Int64],
        title: String,
        priority: AppTaskPriority
    ) async {
        let idsToSync = reserveFeedSyncIDs(feedIds)
        guard idsToSync.isEmpty == false else { return }

        let dependencies = FeedSyncTaskDependencies(
            useCase: feedSyncUseCase,
            maxConcurrentFeeds: syncFeedConcurrency,
            projection: FeedTaskProjection(appModel: self)
        )
        _ = await enqueueTask(
            kind: .syncFeeds,
            title: title,
            priority: priority,
            dependencies: dependencies
        ) { dependencies, executionContext in
            try await withReleasedFeedSyncReservations(idsToSync, projection: dependencies.projection) {
                try await runVerifiedFeedSync(
                    feedIds: idsToSync,
                    report: executionContext.reportProgress,
                    progressStart: 0,
                    progressSpan: 1,
                    refreshStride: 1,
                    dependencies: dependencies
                )
                await executionContext.reportProgress(1, "Sync completed")
            }
        }
    }

    func enqueueNewFeedSync(
        feedIds: [Int64],
        title: String,
        priority: AppTaskPriority
    ) async {
        let idsToSync = reserveFeedSyncIDs(feedIds)
        guard idsToSync.isEmpty == false else { return }

        let dependencies = FeedSyncTaskDependencies(
            useCase: feedSyncUseCase,
            maxConcurrentFeeds: syncFeedConcurrency,
            projection: FeedTaskProjection(appModel: self)
        )
        _ = await enqueueTask(
            kind: .syncFeeds,
            title: title,
            priority: priority,
            dependencies: dependencies
        ) { dependencies, executionContext in
            try await withReleasedFeedSyncReservations(idsToSync, projection: dependencies.projection) {
                try await runPlainFeedSync(
                    feedIds: idsToSync,
                    report: executionContext.reportProgress,
                    progressStart: 0,
                    progressSpan: 1,
                    refreshStride: 1,
                    dependencies: dependencies
                )
                await executionContext.reportProgress(1, "Sync completed")
            }
        }
    }

    func reserveFeedSyncIDs(_ feedIds: [Int64]) -> [Int64] {
        guard feedIds.isEmpty == false else { return [] }

        var accepted: [Int64] = []
        var seen: Set<Int64> = []
        accepted.reserveCapacity(feedIds.count)

        for feedId in feedIds where seen.insert(feedId).inserted {
            if reservedFeedSyncIDs.contains(feedId) {
                continue
            }
            reservedFeedSyncIDs.insert(feedId)
            accepted.append(feedId)
        }

        return accepted
    }

    func releaseReservedFeedSyncIDs(_ feedIds: [Int64]) {
        for feedId in feedIds {
            reservedFeedSyncIDs.remove(feedId)
        }
    }
}
