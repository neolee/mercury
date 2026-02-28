//
//  FeedSyncUseCase.swift
//  Mercury
//

import Foundation
import GRDB

struct FeedSyncUseCase {
    let database: DatabaseManager
    let syncService: SyncService

    func loadAllFeedIDs() async throws -> [Int64] {
        try await database.read { db in
            try Feed.fetchAll(db).compactMap(\.id)
        }
    }

    func sync(
        feedIds: [Int64],
        report: TaskProgressReporter,
        maxConcurrentFeeds: Int = 6,
        progressStart: Double,
        progressSpan: Double,
        refreshStride: Int,
        continueOnError: Bool = false,
        onError: (@Sendable (_ feedId: Int64, _ error: Error) async -> Void)? = nil,
        onRefresh: @escaping () async -> Void
    ) async throws {
        guard feedIds.isEmpty == false else {
            await report(progressStart + progressSpan, "No feeds to sync")
            return
        }

        let total = feedIds.count
        let concurrency = min(max(maxConcurrentFeeds, 2), 10)
        let stride = max(refreshStride, 1)
        struct FeedSyncOutcome {
            let feedId: Int64
            let error: Error?
        }

        var failureCount = 0
        var completed = 0
        var nextIndex = 0

        try await withThrowingTaskGroup(of: FeedSyncOutcome.self) { group in
            let initialCount = min(concurrency, total)
            for _ in 0..<initialCount {
                let feedId = feedIds[nextIndex]
                nextIndex += 1
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        try await syncService.syncFeed(withId: feedId)
                        return FeedSyncOutcome(feedId: feedId, error: nil)
                    } catch {
                        return FeedSyncOutcome(feedId: feedId, error: error)
                    }
                }
            }

            while let outcome = try await group.next() {
                try Task.checkCancellation()
                completed += 1

                if let error = outcome.error {
                    if let onError {
                        await onError(outcome.feedId, error)
                    }
                    if error is CancellationError {
                        group.cancelAll()
                        throw CancellationError()
                    }

                    failureCount += 1
                    if continueOnError == false {
                        group.cancelAll()
                        throw error
                    }
                }

                let progress = progressStart + (progressSpan * Double(completed) / Double(total))
                if failureCount > 0 {
                    await report(progress, "Processed \(completed)/\(total) feeds (\(failureCount) failed)")
                } else {
                    await report(progress, "Synced \(completed)/\(total) feeds")
                }

                if completed % stride == 0 || completed == total {
                    await onRefresh()
                }

                if nextIndex < total {
                    let feedId = feedIds[nextIndex]
                    nextIndex += 1
                    group.addTask {
                        do {
                            try Task.checkCancellation()
                            try await syncService.syncFeed(withId: feedId)
                            return FeedSyncOutcome(feedId: feedId, error: nil)
                        } catch {
                            return FeedSyncOutcome(feedId: feedId, error: error)
                        }
                    }
                }
            }
        }
    }
}
