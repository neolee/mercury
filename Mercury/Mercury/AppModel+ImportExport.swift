//
//  AppModel+ImportExport.swift
//  Mercury
//

import Foundation

extension AppModel {
    func importOPML(
        from url: URL,
        replaceExisting: Bool,
        forceSiteNameAsFeedTitle: Bool
    ) async throws {
        let importURL = url
        _ = await enqueueTask(
            kind: .importOPML,
            title: "Import OPML",
            priority: .userInitiated
        ) { [weak self] report in
            guard let self else { return }
            try await self.importOPMLUseCase.run(
                from: importURL,
                replaceExisting: replaceExisting,
                forceSiteNameAsFeedTitle: forceSiteNameAsFeedTitle,
                report: report,
                maxConcurrentFeeds: self.syncFeedConcurrency,
                onMutation: { [weak self] in
                    await self?.refreshAfterBackgroundMutation()
                },
                onSyncError: { [weak self] feedId, error in
                    guard let self else { return }
                    await self.reportFeedSyncFailure(feedId: feedId, error: error, source: "import")
                    if FailurePolicy.isPermanentUnsupportedFeedError(error) {
                        await self.removeFeedAfterPermanentImportFailure(feedId: feedId, source: "import", error: error)
                    }
                },
                onSkippedInsecureFeed: { [weak self] feedURL in
                    await self?.reportSkippedInsecureFeed(feedURL: feedURL, source: "import")
                }
            )
        }
    }

    func exportOPML(to url: URL) async throws {
        if hasActiveTask(kind: .exportOPML) {
            return
        }

        let exportURL = url
        _ = await enqueueTask(
            kind: .exportOPML,
            title: "Export OPML",
            priority: .utility
        ) { [weak self] report in
            guard let self else { return }
            try await self.exportOPMLUseCase.run(to: exportURL, report: report)
        }
    }
}
