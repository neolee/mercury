//
//  AppModel+Sync.swift
//  Mercury
//

import Foundation
import GRDB

extension AppModel {
    func reportFeedSyncFailure(feedId: Int64, error: Error, source: String) {
        let feed = feedStore.feeds.first(where: { $0.id == feedId })
        let feedTitle = feed?.title ?? "(unknown)"
        let feedURL = feed?.feedURL ?? "(unknown)"

        reportDebugIssue(
            title: "Feed Sync Failed",
            detail: [
                "source=\(source)",
                "feedId=\(feedId)",
                "title=\(feedTitle)",
                "feedURL=\(feedURL)",
                "error=\(error.localizedDescription)"
            ].joined(separator: "\n"),
            category: .task
        )
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
        _ = await enqueueTask(
            kind: .bootstrap,
            title: "Bootstrap",
            priority: .userInitiated
        ) { [weak self] report in
            guard let self else { return }

            self.beginSyncState()
            do {
                try await self.bootstrapUseCase.run(
                    report: report,
                    onMutation: { [weak self] in
                        await self?.refreshAfterBackgroundMutation()
                    },
                    onSyncError: { [weak self] feedId, error in
                        await MainActor.run {
                            self?.reportFeedSyncFailure(feedId: feedId, error: error, source: "bootstrap")
                        }
                    },
                    onSkippedInsecureFeed: { [weak self] feedURL in
                        await MainActor.run {
                            self?.reportSkippedInsecureFeed(feedURL: feedURL, source: "bootstrap")
                        }
                    }
                )

                await report(1, "Bootstrap completed")
                self.finishSyncStateSuccess()
                self.bootstrapState = .ready
                await self.refreshAfterBackgroundMutation()
            } catch is CancellationError {
                self.syncState = .idle
                self.bootstrapState = .idle
                throw CancellationError()
            } catch {
                self.finishSyncStateFailure(error.localizedDescription)
                self.bootstrapState = .failed(error.localizedDescription)
                throw error
            }
        }
    }

    func syncAllFeeds() async {
        if hasActiveTask(kind: .syncAllFeeds) || syncState == .syncing {
            return
        }

        _ = await enqueueTask(
            kind: .syncAllFeeds,
            title: "Sync Feeds",
            priority: .utility
        ) { [weak self] report in
            guard let self else { return }

            self.beginSyncState()
            do {
                let feedIds = try await self.feedSyncUseCase.loadAllFeedIDs()

                if feedIds.isEmpty {
                    await report(1, "No feeds to sync")
                    self.finishSyncStateSuccess()
                    return
                }

                try await self.syncFeedsByIDs(
                    feedIds,
                    report: report,
                    progressStart: 0,
                    progressSpan: 1,
                    refreshStride: 5
                )

                await report(1, "Sync completed")
                self.finishSyncStateSuccess()
                await self.refreshAfterBackgroundMutation()
            } catch {
                self.finishSyncStateFailure(error.localizedDescription)
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

    func syncFeedsByIDs(
        _ feedIds: [Int64],
        report: TaskProgressReporter,
        progressStart: Double,
        progressSpan: Double,
        refreshStride: Int,
        continueOnError: Bool = true
    ) async throws {
        try await feedSyncUseCase.sync(
            feedIds: feedIds,
            report: report,
            progressStart: progressStart,
            progressSpan: progressSpan,
            refreshStride: refreshStride,
            continueOnError: continueOnError,
            onError: { [weak self] feedId, error in
                await MainActor.run {
                    self?.reportFeedSyncFailure(feedId: feedId, error: error, source: "sync")
                }
            },
            onRefresh: { [weak self] in
                await self?.refreshAfterBackgroundMutation()
            }
        )
    }

    func enqueueFeedSync(
        feedIds: [Int64],
        title: String,
        priority: AppTaskPriority
    ) async {
        let idsToSync = reserveFeedSyncIDs(feedIds)
        guard idsToSync.isEmpty == false else { return }

        _ = await enqueueTask(
            kind: .syncFeeds,
            title: title,
            priority: priority
        ) { [weak self] report in
            guard let self else { return }
            defer {
                Task { @MainActor [weak self] in
                    self?.releaseReservedFeedSyncIDs(idsToSync)
                }
            }

            try await self.syncFeedsByIDs(
                idsToSync,
                report: report,
                progressStart: 0,
                progressSpan: 1,
                refreshStride: 1
            )
            await report(1, "Sync completed")
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
