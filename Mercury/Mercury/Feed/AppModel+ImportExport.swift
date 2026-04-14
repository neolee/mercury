//
//  AppModel+ImportExport.swift
//  Mercury
//

import Foundation

private struct ImportOPMLTaskDependencies: Sendable {
    let useCase: ImportOPMLUseCase
    let maxConcurrentFeeds: Int
    let projection: FeedTaskProjection
}

extension AppModel {
    func importOPML(
        from url: URL,
        replaceExisting: Bool,
        forceSiteNameAsFeedTitle: Bool
    ) async throws {
        let importURL = url
        let dependencies = ImportOPMLTaskDependencies(
            useCase: importOPMLUseCase,
            maxConcurrentFeeds: syncFeedConcurrency,
            projection: FeedTaskProjection(appModel: self)
        )
        _ = await enqueueTask(
            kind: .importOPML,
            title: "Import OPML",
            priority: .userInitiated,
            dependencies: dependencies
        ) { dependencies, executionContext in
            try await dependencies.useCase.run(
                from: importURL,
                replaceExisting: replaceExisting,
                forceSiteNameAsFeedTitle: forceSiteNameAsFeedTitle,
                report: executionContext.reportProgress,
                maxConcurrentFeeds: dependencies.maxConcurrentFeeds,
                onMutation: {
                    await dependencies.projection.refreshAfterBackgroundMutation()
                },
                onSyncError: { feedId, error in
                    await dependencies.projection.reportFeedSyncFailure(
                        feedId: feedId,
                        error: error,
                        source: "import"
                    )
                    if FailurePolicy.isPermanentUnsupportedFeedError(error) {
                        await dependencies.projection.removeFeedAfterPermanentImportFailure(
                            feedId: feedId,
                            source: "import",
                            error: error
                        )
                    }
                },
                onSkippedInsecureFeed: { feedURL in
                    await dependencies.projection.reportSkippedInsecureFeed(
                        feedURL: feedURL,
                        source: "import"
                    )
                }
            )
        }
    }

    func exportOPML(to url: URL) async throws {
        if hasActiveTask(kind: .exportOPML) {
            return
        }

        let exportURL = url
        let exportUseCase = exportOPMLUseCase
        _ = await enqueueTask(
            kind: .exportOPML,
            title: "Export OPML",
            priority: .utility,
            dependencies: exportUseCase
        ) { exportUseCase, executionContext in
            try await exportUseCase.run(to: exportURL, report: executionContext.reportProgress)
        }
    }
}
