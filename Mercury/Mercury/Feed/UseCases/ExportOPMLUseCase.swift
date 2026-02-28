//
//  ExportOPMLUseCase.swift
//  Mercury
//

import Foundation
import GRDB

struct ExportOPMLUseCase {
    let database: DatabaseManager

    func run(to url: URL, report: TaskProgressReporter) async throws {
        await report(0.1, "Loading feeds")
        let feeds = try await database.read { db in
            try Feed
                .order(Column("title").collating(.localizedCaseInsensitiveCompare))
                .fetchAll(db)
        }

        await report(0.55, "Generating OPML")
        let exporter = OPMLExporter()
        let opml = exporter.export(feeds: feeds, title: "Mercury Subscriptions")

        await report(0.85, "Writing file")
        try SecurityScopedBookmarkStore.access(url) {
            try opml.write(to: url, atomically: true, encoding: .utf8)
        }
        await report(1, "Export completed")
    }
}
